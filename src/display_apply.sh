#!/usr/bin/env bash
# display_apply.sh — sole display control plane for the native-HDMI switcher.
# Authoritative behavior: ARCHITECTURE.md ("src/display_apply.sh: sole control plane").
#
# Modes (exclusive): monitor (PHL 345E2, 3440x1440@74.98, 8-bit SDR,
# VRR off), cs2 (PHL 345E2, 1920x1080@60, 8-bit SDR, VRR off), and tv
# (Philips UHDTV on native HDMI, 3840x2160@144, 10-bit HDR, VRR).
# Discovery is identity-based (EDID fields + HDMI connector class); connector
# names are runtime data only. Every apply verifies effective compositor state.
#
# CLI:  display_apply.sh status|monitor|tv
# Exit: 0 success · 2 usage · 3 discovery/preflight (no mutation) ·
#       4 apply/verification failure · 5 lock held by another apply
# stdout: `status` token, or one success line for apply. Diagnostics: stderr + log.
# No sudo, no kernel/DRD debugfs/sysfs access, no audio, no daemon restarts.

set -uo pipefail

# ---------------------------------------------------------------- constants --

STATE_DIR="$HOME/.local/state"
LOG_FILE="$STATE_DIR/display-switcher.log"
LOCK_FILE="$STATE_DIR/display-apply.lock"
CONFIG_DIR="$HOME/.config/hypr"
GENERATED_CONFIG="$CONFIG_DIR/display-switcher-generated.conf"

# Role identity. Monitor: exact make/model/serial. TV: HDMI connector class
# plus exact make/model; the dummy serial 0x01010101 is not identity.
MON_MAKE="Philips Consumer Electronics Company"
MON_MODEL="PHL 345E2"
MON_SERIAL="UK02226037640"
TV_MAKE="Philips Consumer Electronics Company"
TV_MODEL="Philips UHDTV"

# Verbatim full EDID descriptions for persistent selectors (never assembled
# from separate JSON fields), so connector renumbering cannot invalidate rules.
MONITOR_DESC="desc:Philips Consumer Electronics Company PHL 345E2 UK02226037640"
TV_DESC="desc:Philips Consumer Electronics Company Philips UHDTV 0x01010101"

# Profiles: single source of truth for generation AND verification.
# Patched Aquamarine emits DRM scaling mode=Full aspect(3), so non-native
# modes center with side bars instead of stretching. CS2 is 1920x1080@~75
# (upscaled full-height to 2560x1440 by the GPU); CS2 2K is native 2560x1440@~75.
MONITOR_PROFILE="mode=3440x1440@74.98 position=0x0 scale=1 bitdepth=8 cm=srgb sdr_eotf=srgb sdrsaturation=1.2 vrr=0"
TV_PROFILE="mode=3840x2160@144 position=0x0 scale=1.5 bitdepth=10 cm=hdr sdrbrightness=1.0 sdrsaturation=1.0 sdr_min_luminance=0.005 sdr_max_luminance=200 min_luminance=0 max_luminance=1400 max_avg_luminance=250 supports_hdr=1 supports_wide_color=1 vrr=1"
CS2_MODELINE="modeline 220.75 1920 2056 2264 2608 1080 1083 1088 1130 -hsync +vsync"
CS2_PROFILE="position=0x0 scale=1 bitdepth=8 cm=srgb sdr_eotf=srgb sdrsaturation=1.2 vrr=0"
CS2_2K_MODELINE="modeline 397.25 2560 2760 3040 3520 1440 1443 1448 1506 -hsync +vsync"
CS2_2K_PROFILE="position=0x0 scale=1 bitdepth=8 cm=srgb sdr_eotf=srgb sdrsaturation=1.2 vrr=0"
POLL_INTERVAL=0.1   # seconds between polls
POLL_MAX=50         # bounded: 50 checks at 100 ms ≈ five seconds

# ------------------------------------------------------------- runtime state --

MONITORS_JSON=""
MON_PRESENT=0 MON_ENABLED=0 MON_CONN=""
TV_PRESENT=0 TV_ENABLED=0 TV_CONN=""
TARGET_ROLE="" SRC_ACTIVE=0 SRC_CONN="" TGT_CONN=""
VT_WHY="" VT_OBS=""
PREV_PATH="" LAST_TMP="" SNAP_HDR="" SNAP_VRR=""

# ------------------------------------------------------------------- logging --

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

die() { # die <exit-code> <message...>
  local code="$1"
  shift
  log "ERROR($code): $*"
  exit "$code"
}

usage() {
  cat >&2 <<'EOF'
usage: display-apply.sh <command>
commands:
  monitor   apply the PHL 345E2 profile: 3440x1440@74.98, 8-bit SDR, VRR
            off, scale 1
  cs2       apply the PHL 345E2 CS2 profile: custom 1920x1080@~75
            modeline, 8-bit SDR, VRR off, scale 1 (GPU Full aspect
            pillarbox, needs patched Aquamarine)
  cs2-2k    apply the PHL 345E2 CS2 2K profile: custom 2560x1440@~75
            modeline, 8-bit SDR, VRR off, scale 1 (GPU Full aspect
            pillarbox, needs patched Aquamarine)
  tv        apply the Philips UHDTV profile on native HDMI:
            3840x2160@144, 10-bit HDR, VRR, scale 1.5 (no fallback)
exit codes: 0 success · 2 usage · 3 discovery/preflight (no mutation) ·
4 apply/verify · 5 lock
EOF
  exit 2
}

cleanup() {
  [[ -n "${LAST_TMP:-}" ]] && rm -f -- "$LAST_TMP"
  [[ -n "${PREV_PATH:-}" ]] && rm -f -- "$PREV_PATH"
}

# ------------------------------------------------------------ environment -----

require_deps() {
  local c
  for c in hyprctl jq flock; do
    command -v "$c" >/dev/null 2>&1 || die 3 "required command not found: $c"
  done
}

# Restore Hyprland IPC context when launched from a non-Hyprland shell/unit.
ensure_ipc_sig() {
  if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    local sig
    sig=$(ls -t /run/user/"$(id -u)"/hypr 2>/dev/null | head -1)
    [[ -n "$sig" ]] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
  fi
}

acquire_lock() {
  exec 9>"$LOCK_FILE" || die 3 "cannot open lock file $LOCK_FILE"
  flock -n 9 || die 5 "another display apply is running"
}

# ---------------------------------------------------------------- discovery ---

fetch_monitors() { # one structured snapshot; sets MONITORS_JSON
  local out
  out=$(hyprctl -j monitors all 2>/dev/null) || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" || return 1
  MONITORS_JSON="$out"
}

role_match() { # role_match <role> <snapshot-json> → JSON array of matches
  local role="$1" json="$2"
  if [[ "$role" == monitor || "$role" == cs2 || "$role" == cs2-2k ]]; then
    jq -c --arg make "$MON_MAKE" --arg model "$MON_MODEL" --arg serial "$MON_SERIAL" \
      '[ .[] | select(.make == $make and .model == $model and .serial == $serial) ]' <<<"$json"
  else
    jq -c --arg make "$TV_MAKE" --arg model "$TV_MODEL" \
      '[ .[] | select((.name | test("^HDMI-A-")) and .make == $make and .model == $model) ]' <<<"$json"
  fi
}

# discover() fills presence/enabled/connector for both roles and rejects
# ambiguous identities or a single connector matching both roles.
discover() {
  MON_ARR=$(role_match monitor "$MONITORS_JSON")
  TV_ARR=$(role_match tv "$MONITORS_JSON")
  local mn tn
  mn=$(jq 'length' <<<"$MON_ARR")
  tn=$(jq 'length' <<<"$TV_ARR")
  (( mn <= 1 )) || die 3 "discovery error: multiple displays match the monitor identity"
  (( tn <= 1 )) || die 3 "discovery error: multiple displays match the TV identity"
  if (( mn )); then
    MON_CONN=$(jq -r '.[0].name' <<<"$MON_ARR")
    MON_ENABLED=$(jq -r 'if .[0].disabled == false then 1 else 0 end' <<<"$MON_ARR")
    MON_PRESENT=1
  else
    MON_CONN=""; MON_PRESENT=0; MON_ENABLED=0
  fi
  if (( tn )); then
    TV_CONN=$(jq -r '.[0].name' <<<"$TV_ARR")
    TV_ENABLED=$(jq -r 'if .[0].disabled == false then 1 else 0 end' <<<"$TV_ARR")
    TV_PRESENT=1
  else
    TV_CONN=""; TV_PRESENT=0; TV_ENABLED=0
  fi
  if (( MON_PRESENT && TV_PRESENT )) && [[ "$MON_CONN" == "$TV_CONN" ]]; then
    die 3 "discovery error: both roles matched connector $MON_CONN"
  fi
}

role_present() {
  [[ "$1" == monitor || "$1" == cs2 || "$1" == cs2-2k ]] && echo "$MON_PRESENT" || echo "$TV_PRESENT"
}
role_enabled() {
  [[ "$1" == monitor || "$1" == cs2 || "$1" == cs2-2k ]] && echo "$MON_ENABLED" || echo "$TV_ENABLED"
}
role_conn() {
  [[ "$1" == monitor || "$1" == cs2 || "$1" == cs2-2k ]] && echo "$MON_CONN" || echo "$TV_CONN"
}
selector() {
  [[ "$1" == tv ]] && echo "$TV_DESC" || echo "$MONITOR_DESC"
}
other() {
  [[ "$1" == tv ]] && echo monitor || echo tv
}
pref_for() {
  [[ "$1" == tv ]] && echo 1 || echo 0
}

compute_status() {
  if (( TV_PRESENT && TV_ENABLED )) && ! (( MON_PRESENT && MON_ENABLED )); then
    printf 'tv\n'
  elif (( MON_PRESENT && MON_ENABLED )) && ! (( TV_PRESENT && TV_ENABLED )); then
    local arr width height refresh
    arr=$(role_match monitor "$MONITORS_JSON")
    width=$(jq -r '.[0].width' <<<"$arr")
    height=$(jq -r '.[0].height' <<<"$arr")
    refresh=$(jq -r '.[0].refreshRate' <<<"$arr")
    if [[ "$width" == 1920 && "$height" == 1080 ]]; then
      printf 'cs2\n'
    elif [[ "$width" == 2560 && "$height" == 1440 ]]; then
      printf 'cs2-2k\n'
    else
      printf 'monitor\n'
    fi
  else
    printf 'unknown\n'
  fi
}

prof() { # prof <role> <key> → value from the single profile definition
  local profile kv
  case "$1" in
    monitor) profile="$MONITOR_PROFILE" ;;
    cs2) profile="$CS2_PROFILE" ;;
    cs2-2k) profile="$CS2_2K_PROFILE" ;;
    tv) profile="$TV_PROFILE" ;;
    *) return 1 ;;
  esac
  if [[ "$1" == cs2 && "$2" == mode ]]; then
    printf '%s' "$CS2_MODELINE"
    return 0
  fi
  if [[ "$1" == cs2-2k && "$2" == mode ]]; then
    printf '%s' "$CS2_2K_MODELINE"
    return 0
  fi
  for kv in $profile; do
    if [[ "$kv" == "$2="* ]]; then
      printf '%s' "${kv#*=}"
      return 0
    fi
  done
  return 1
}

emit_block() { # emit_block <role> <selector> <position-override> <disabled 0|1>
  local role="$1" sel="$2" pos="$3" dis="$4" kv k v
  printf 'monitorv2 {\n'
  printf '    output = %s\n' "$sel"
  printf '    position = %s\n' "${pos:-$(prof "$role" position)}"
  printf '    mode = %s\n' "$(prof "$role" mode)"
  for kv in $(prof_all "$role"); do
    k="${kv%%=*}"
    v="${kv#*=}"
    case "$k" in
      position|mode) continue ;;
      scale|bitdepth|cm|sdr_eotf|sdrbrightness|sdrsaturation|sdr_min_luminance|sdr_max_luminance|min_luminance|max_luminance|max_avg_luminance|supports_hdr|supports_wide_color|vrr)
        printf '    %s = %s\n' "$k" "$v" ;;
      *) die 4 "internal error: unknown profile key '$k'" ;;
    esac
  done
  (( dis )) && printf '    disabled = 1\n'
  printf '}\n'
}

prof_all() { # role → profile string (helper for word-split iteration)
  case "$1" in
    monitor) echo "$MONITOR_PROFILE" ;;
    cs2) echo "$CS2_PROFILE" ;;
    cs2-2k) echo "$CS2_2K_PROFILE" ;;
    tv) echo "$TV_PROFILE" ;;
    *) return 1 ;;
  esac
}

# Generated file: role-dependent globals first (misc:vrr, quirks:prefer_hdr)
# so reload-time rule creation sees them despite later-sourced base defaults,
# then exactly two monitorv2 rules (target first). Written to a sibling temp
# file, validated, then atomically renamed.
write_generated() { # write_generated <target-role> <staging|final>
  local role="$1" kind="$2" tmp blocks outs
  local other_role pref vrr
  other_role=$(other "$role")
  pref=$(pref_for "$role")
  vrr=$(prof "$role" vrr)
  tmp="${GENERATED_CONFIG}.tmp.$$"
  LAST_TMP="$tmp"
  {
    printf 'misc {\n    vrr = %s\n}\n' "$vrr"
    printf 'quirks {\n    prefer_hdr = %s\n}\n' "$pref"
    emit_block "$role" "$(selector "$role")" "" 0
    if [[ "$kind" == staging && "$SRC_ACTIVE" == 1 ]]; then
      # Keep the connected, active source at a non-overlapping position.
      emit_block "$other_role" "$(selector "$other_role")" "auto-right" 0
    else
      # Final state (or inactive/absent source): non-target disabled by description.
      emit_block "$other_role" "$(selector "$other_role")" "" 1
    fi
  } >"$tmp" || { rm -f -- "$tmp"; die 4 "failed to write generated config temp file"; }
  [[ -s "$tmp" ]] || { rm -f -- "$tmp"; die 4 "generated config is empty"; }
  blocks=$(grep -c '^monitorv2 {' "$tmp")
  outs=$(grep -c '^    output = ' "$tmp")
  [[ "$blocks" == 2 && "$outs" == 2 ]] || {
    rm -f -- "$tmp"; die 4 "generated config invalid (blocks=$blocks outputs=$outs)"
  }
  mv -f -- "$tmp" "$GENERATED_CONFIG" || { rm -f -- "$tmp"; die 4 "atomic rename of generated config failed"; }
  LAST_TMP=""
}

# ------------------------------------------------------------ verification ----

num_close() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a == b) }'; }

refresh_close() { # |got - want| <= 0.1
  awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 0.1) }'
}

get_option_val() { # live int value of a keyword through IPC
  local out
  out=$(hyprctl -j getoption "$1" 2>/dev/null) || return 1
  jq -er 'if type == "object" then ((.int // .str) // empty | tostring) else empty end' <<<"$out" 2>/dev/null
}

get_prefer_hdr() { get_option_val quirks:prefer_hdr; }
get_misc_vrr()   { get_option_val misc:vrr; }

verify_target() { # verify_target <role> <snapshot-json>; sets VT_WHY/VT_OBS
  local role="$1" json="$2" arr n conn mode w h r
  VT_WHY=""
  arr=$(role_match "$role" "$json") || { VT_WHY="identity query failed"; return 1; }
  n=$(jq 'length' <<<"$arr")
  (( n == 1 )) || { VT_WHY="$role identity matches=$n (need exactly 1)"; return 1; }
  conn=$(jq -r '.[0].name' <<<"$arr")
  if [[ "$role" == tv && ! "$conn" =~ ^HDMI-A- ]]; then
    VT_WHY="tv is on non-HDMI connector $conn"
    return 1
  fi
  mode=$(prof "$role" mode)
  if [[ "$mode" =~ ^modeline[[:space:]]+[0-9.]+[[:space:]]+2560[[:space:]] ]]; then
    w=2560; h=1440; r=74.89
  elif [[ "$mode" =~ ^modeline[[:space:]]+[0-9.]+[[:space:]]+1920[[:space:]] ]]; then
    w=1920; h=1080; r=74.65
  elif [[ "$mode" =~ ^([0-9]+)x([0-9]+)@([0-9]+(\.[0-9]+)?)$ ]]; then
    w=${BASH_REMATCH[1]} h=${BASH_REMATCH[2]} r=${BASH_REMATCH[3]}
  else
    VT_WHY="bad profile mode '$mode'"; return 1
  fi
  local disabled width height rr scale fmt cm vrr dpms
  disabled=$(jq -r '.[0].disabled' <<<"$arr")
  width=$(jq -r '.[0].width' <<<"$arr")
  height=$(jq -r '.[0].height' <<<"$arr")
  rr=$(jq -r '.[0].refreshRate' <<<"$arr")
  scale=$(jq -r '.[0].scale' <<<"$arr")
  fmt=$(jq -r '.[0].currentFormat' <<<"$arr")
  cm=$(jq -r '.[0].colorManagementPreset' <<<"$arr")
  vrr=$(jq -r '.[0].vrr' <<<"$arr")
  dpms=$(jq -r '.[0].dpmsStatus' <<<"$arr")
  VT_OBS="$conn: disabled=$disabled ${width}x${height}@${rr} scale=$scale fmt=$fmt cm=$cm vrr=$vrr dpms=$dpms"
  [[ "$disabled" == "false" ]] || { VT_WHY="$conn is disabled"; return 1; }
  [[ "$dpms" == "true" ]] || { VT_WHY="$conn dpms is off"; return 1; }
  (( width == w && height == h )) || { VT_WHY="mode ${width}x${height} != ${w}x${h}"; return 1; }
  refresh_close "$rr" "$r" || { VT_WHY="refresh $rr not within 0.1 Hz of $r"; return 1; }
  num_close "$scale" "$(prof "$role" scale)" || { VT_WHY="scale $scale != $(prof "$role" scale)"; return 1; }
  if [[ "$(prof "$role" bitdepth)" == "10" ]]; then
    case "$fmt" in
      XRGB2101010|XBGR2101010|ARGB2101010) ;;
      *) VT_WHY="currentFormat $fmt is not 10-bit"; return 1 ;;
    esac
  fi
  [[ "$cm" == "$(prof "$role" cm)" ]] || { VT_WHY="cm $cm != $(prof "$role" cm)"; return 1; }
  local want_vrr
  want_vrr=$([[ "$(prof "$role" vrr)" == "1" ]] && echo true || echo false)
  [[ "$vrr" == "$want_vrr" ]] || { VT_WHY="vrr $vrr != $want_vrr"; return 1; }
  return 0
}

verify_final() { # verify_final <role> <snapshot-json>: target profile + non-target off + global vrr/HDR prefs
  verify_target "$@" || return 1
  local oarr on odis hdr want vrr
  oarr=$(role_match "$(other "$1")" "$2") || { VT_WHY="non-target query failed"; return 1; }
  on=$(jq 'length' <<<"$oarr")
  if (( on > 0 )); then
    odis=$(jq -r '.[0].disabled' <<<"$oarr")
    [[ "$odis" == "true" ]] || { VT_WHY="$(other "$1") is still enabled"; return 1; }
  fi
  hdr=$(get_prefer_hdr) || { VT_WHY="quirks:prefer_hdr unreadable"; return 1; }
  want=$(pref_for "$1")
  (( hdr == want )) || { VT_WHY="quirks:prefer_hdr=$hdr != $want"; return 1; }
  vrr=$(get_misc_vrr) || { VT_WHY="misc:vrr unreadable"; return 1; }
  want=$(prof "$1" vrr)
  (( vrr == want )) || { VT_WHY="misc:vrr=$vrr != $want"; return 1; }
  return 0
}

staging_ok() {
  fetch_monitors || { VT_WHY="poll query failed"; return 1; }
  verify_target "$TARGET_ROLE" "$MONITORS_JSON"
}

final_ok() {
  fetch_monitors || { VT_WHY="poll query failed"; return 1; }
  verify_final "$TARGET_ROLE" "$MONITORS_JSON"
}

poll_verify() { # poll_verify <predicate-fn>: check every 100 ms, at most 5 s
  local i
  for ((i = 0; i < POLL_MAX; i++)); do
    if "$1"; then return 0; fi
    sleep "$POLL_INTERVAL"
  done
  return 1
}

apply_role_globals() { # reassert role-dependent globals through IPC after each reload
  local role="$1" want_vrr want_pref
  want_vrr=$(prof "$role" vrr) # global misc:vrr required value: tv=1, monitor=0
  want_pref=$(pref_for "$role")
  hyprctl keyword misc:vrr "$want_vrr" >/dev/null 2>&1 || return 1
  hyprctl keyword quirks:prefer_hdr "$want_pref" >/dev/null 2>&1 || return 1
}

wake_target_if_needed() { # DPMS wake of the target, only when it is off
  fetch_monitors || return 1
  local on
  on=$(jq -r --arg c "$TGT_CONN" '[.[] | select(.name == $c) | .dpmsStatus][0]' <<<"$MONITORS_JSON" 2>/dev/null)
  [[ "$on" == "false" ]] || return 0
  log "target $TGT_CONN dpms is off; waking"
  hyprctl dispatch dpms on "$TGT_CONN" >/dev/null 2>&1
}

# ------------------------------------------------------------ workspaces ------

migrate_workspaces() { # migrate_workspaces <from-connector> <to-connector>
  local from="$1" to="$2" wss ids id moved=0
  wss=$(hyprctl -j workspaces 2>/dev/null) || { log "WARNING: workspace listing failed; skipping migration"; return 0; }
  ids=$(jq -r --arg m "$from" '.[] | select(.monitor == $m) | .id' <<<"$wss" 2>/dev/null) || return 0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if hyprctl dispatch moveworkspacetomonitor "$id" "$to" >/dev/null 2>&1; then
      moved=$((moved + 1))
    else
      log "WARNING: failed to move workspace $id to $to"
    fi
  done <<<"$ids"
  (( moved )) && log "migrated $moved workspace(s) from $from to $to"
  return 0
}

# ----------------------------------------------------------- rollback path ----

snapshot_state() { # previous generated file (byte copy) + live globals (prefer_hdr, vrr)
  PREV_PATH=""
  if [[ -f "$GENERATED_CONFIG" ]]; then
    PREV_PATH="${GENERATED_CONFIG}.prev.$$"
    cp -f -- "$GENERATED_CONFIG" "$PREV_PATH" || die 3 "could not snapshot the generated config"
  fi
  SNAP_HDR=$(get_prefer_hdr || true)
  case "$SNAP_HDR" in
    0|1|2) ;;
    *)
      [[ -n "$PREV_PATH" ]] && rm -f -- "$PREV_PATH"
      die 3 "could not read quirks:prefer_hdr before mutation"
      ;;
  esac
  SNAP_VRR=$(get_misc_vrr || true)
  case "$SNAP_VRR" in
    0|1|2|3) ;;
    *)
      [[ -n "$PREV_PATH" ]] && rm -f -- "$PREV_PATH"
      die 3 "could not read misc:vrr before mutation"
      ;;
  esac
}

restore_on_failure() { # restore persistent file + reload it, then snapshotted globals via IPC
  if [[ -n "$PREV_PATH" && -f "$PREV_PATH" ]]; then
    if mv -f -- "$PREV_PATH" "$GENERATED_CONFIG"; then
      # The restored file enables exactly its previous target, so this reload
      # keeps one monitor active while returning live topology to the prior
      # exclusive state; globals are reasserted through IPC after it.
      if hyprctl reload >/dev/null 2>&1; then
        log "restored previous generated config and reloaded it"
      else
        log "ERROR: reload of restored config failed; live topology may differ from the restored file"
      fi
    fi
    PREV_PATH=""
  else
    rm -f -- "$GENERATED_CONFIG"
    log "removed generated config (none existed before this apply)"
  fi
  if hyprctl keyword misc:vrr "$SNAP_VRR" >/dev/null 2>&1; then
    log "restored misc:vrr=$SNAP_VRR through IPC"
  else
    log "ERROR: failed to restore misc:vrr through IPC"
  fi
  if hyprctl keyword quirks:prefer_hdr "$SNAP_HDR" >/dev/null 2>&1; then
    log "restored quirks:prefer_hdr=$SNAP_HDR through IPC"
  else
    log "ERROR: failed to restore quirks:prefer_hdr through IPC"
  fi
}

obs_role() { # obs_role <role> <json> → one-line observed summary
  local arr n
  arr=$(role_match "$1" "$2") || { echo "$1: identity query failed"; return 0; }
  n=$(jq 'length' <<<"$arr")
  if (( n == 0 )); then echo "$1: absent"
  elif (( n > 1 )); then echo "$1: ambiguous($n)"
  else
    jq -r '"\(.[0].name): disabled=\(.[0].disabled) \(.[0].width)x\(.[0].height)@\(.[0].refreshRate) scale=\(.[0].scale) fmt=\(.[0].currentFormat) cm=\(.[0].colorManagementPreset) vrr=\(.[0].vrr)"' <<<"$arr"
  fi
}

report_observed() { # full observed state after a failed verification
  local json=""
  fetch_monitors && json="$MONITORS_JSON"
  if [[ -z "$json" ]]; then
    log "observed state: unavailable (hyprctl query failed)"
  else
    log "observed state:"
    log "  $(obs_role monitor "$json")"
    log "  $(obs_role tv "$json")"
  fi
  local hdr vrr
  hdr=$(get_prefer_hdr || true)
  log "  quirks:prefer_hdr=${hdr:-unavailable}"
  vrr=$(get_misc_vrr || true)
  log "  misc:vrr=${vrr:-unavailable}"
}

fail_apply() { # fail_apply <reason> → restore, report, exit 4
  local reason="$1"
  log "ERROR: $reason"
  restore_on_failure
  report_observed
  log "ERROR: ${TARGET_ROLE:-apply} aborted"
  exit 4
}

# --------------------------------------------------------------- transaction --

apply_flow() { # apply_flow <role> — caller holds the lock
  local role="$1" other_role
  other_role=$(other "$role")

  fetch_monitors || die 3 "discovery failed: hyprctl -j monitors all returned no valid JSON"
  discover

  local present
  present=$(role_present "$role")
  (( present == 1 )) || die 3 "$role target not connected or not uniquely identified"

  TGT_CONN=$(role_conn "$role")
  SRC_ACTIVE=0
  SRC_CONN=""
  if [[ "$(role_present "$other_role")" == 1 && "$(role_enabled "$other_role")" == 1 ]]; then
    SRC_ACTIVE=1
    SRC_CONN=$(role_conn "$other_role")
  fi

  snapshot_state
  log "applying $role mode (target=$TGT_CONN, source=$( ((SRC_ACTIVE)) && echo "$SRC_CONN" || echo none ))"

  # 1) staging: target active with its final profile; any active source kept.
  TARGET_ROLE="$role"
  write_generated "$role" staging
  hyprctl reload >/dev/null 2>&1 || fail_apply "staging reload command failed"
  apply_role_globals "$role" || fail_apply "staging global apply failed (misc:vrr/quirks:prefer_hdr)"
  wake_target_if_needed || log "WARNING: dpms wake failed; verification will catch dpms state"
  poll_verify staging_ok || fail_apply "staging verification failed: ${VT_WHY:-target not active} (observed: ${VT_OBS:-none})"
  log "staging verified: $role active"

  # 2) move workspaces only after the target is verified active.
  if (( SRC_ACTIVE )); then
    migrate_workspaces "$SRC_CONN" "$TGT_CONN"
  fi

  # 3) final: target first, non-target disabled by description; full verify.
  write_generated "$role" final
  hyprctl reload >/dev/null 2>&1 || fail_apply "final reload command failed"
  apply_role_globals "$role" || fail_apply "final global apply failed (misc:vrr/quirks:prefer_hdr)"
  wake_target_if_needed || log "WARNING: dpms wake failed; verification will catch dpms state"
  poll_verify final_ok || fail_apply "final verification failed: ${VT_WHY:-state not converged} (observed: ${VT_OBS:-none})"

  rm -f -- "${PREV_PATH:-}" 2>/dev/null
  PREV_PATH=""
  log "$role mode applied and verified"
  echo "$role mode applied"
}

# --------------------------------------------------------------------- main ---

main() {
  mkdir -p "$STATE_DIR" "$CONFIG_DIR"
  trap cleanup EXIT

  (( $# == 1 )) || usage
  case "$1" in
    status)
      require_deps
      ensure_ipc_sig
      fetch_monitors || die 3 "discovery failed: hyprctl -j monitors all returned no valid JSON"
      discover
      compute_status
      ;;
    monitor|cs2|cs2-2k|tv)
      require_deps
      ensure_ipc_sig
      acquire_lock
      apply_flow "$1"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"

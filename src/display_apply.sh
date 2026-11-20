#!/usr/bin/env bash
# display_apply.sh — sole display control plane for the native-HDMI switcher.
# Authoritative behavior: ARCHITECTURE.md ("src/display_apply.sh: sole control plane").
# Config managers: hyprlang and Lua are both supported until the hyprlang
# config is deleted. The running manager is detected once per apply
# (`hyprctl eval`); every apply writes BOTH generated files.
#
# Per-display settings: `monitor` and `tv` take optional res=WxH, hz=N,
# vrr=0|1, hdr=0|1 and scale=S keys; omitted keys fall back to that role's
# defaults (monitor 3440x1440@74.98, 8-bit SDR, VRR off, scale 1; tv
# 3840x2160@144, 10-bit HDR, VRR on, scale 1.5). `caps` reports what the
# attached hardware advertises (modes, refresh rates, VRR/HDR capability,
# scales) for the overlay to build its controls.
# Discovery is identity-based (EDID fields + HDMI connector class); connector
# names are runtime data only. Every apply verifies effective compositor state
# against the resolved request, not against a fixed profile.
#
# CLI:  display_apply.sh status|caps|ensure|monitor|tv [key=value ...]
# ensure: recover to a connected monitor or an already-awake TV; return from
# an active TV in standby when the monitor is connected. Never wakes the TV.
# Exit: 0 success · 2 usage · 3 discovery/preflight (no mutation; includes an
#       undetectable config manager) ·
#       4 apply/verification failure · 5 lock held by another apply
# stdout: `status` role token, one `caps` JSON object, or one success line for
# apply. Diagnostics: stderr + log.
# No sudo, no writes to DRM/sysfs (EDID is only read), no audio, no daemon
# restarts.

set -uo pipefail

# ---------------------------------------------------------------- constants --

STATE_DIR="$HOME/.local/state"
LOG_FILE="$STATE_DIR/display-switcher.log"
LOCK_FILE="$STATE_DIR/display-apply.lock"
CONFIG_DIR="$HOME/.config/hypr"
GENERATED_CONFIG="$CONFIG_DIR/display-switcher-generated.conf"
GENERATED_LUA="$CONFIG_DIR/display-switcher-generated.lua"

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

# Per-role settings defaults. `caps` publishes these as "defaults"; an apply
# that omits a key uses them.
MON_DEF_RES="3440x1440" MON_DEF_HZ="74.98" MON_DEF_VRR=0 MON_DEF_HDR=0 MON_DEF_SCALE="1"
TV_DEF_RES="3840x2160" TV_DEF_HZ="144" TV_DEF_VRR=1 TV_DEF_HDR=1 TV_DEF_SCALE="1.5"
# Scale candidates; caps narrows them per resolution (Hyprland requires
# W/scale and H/scale to be integral, otherwise it rounds and errors).
SCALE_CANDIDATES="1 1.25 1.5 1.6 1.75 2"

# Color bases: role + hdr decides bit depth, preset and HDR metadata. The tv
# HDR base carries the calibrated SDR-to-HDR mapping. Monitor HDR is not a
# defined composition, so hdr=1 is refused for the monitor in preflight.
MON_SDR_COLOR="bitdepth=8 cm=srgb sdr_eotf=srgb sdrsaturation=1.2"
TV_HDR_COLOR="bitdepth=10 cm=hdr sdrbrightness=3.0 sdrsaturation=1.0 sdr_min_luminance=0 sdr_max_luminance=200 min_luminance=0 max_luminance=1400 max_avg_luminance=250 supports_hdr=1 supports_wide_color=1"
TV_SDR_COLOR="bitdepth=10 cm=srgb sdr_eotf=srgb sdrsaturation=1.0"

# Monitor-only custom modelines (GPU Full aspect pillarbox, needs patched
# Aquamarine); published by `caps` as extra rates for their resolution.
CS2_MODELINE="modeline 220.75 1920 2056 2264 2608 1080 1083 1088 1130 -hsync +vsync"
CS2_HZ="74.65"
CS2_2K_MODELINE="modeline 397.25 2560 2760 3040 3520 1440 1443 1448 1506 -hsync +vsync"
CS2_2K_HZ="74.89"
POLL_INTERVAL=0.1   # seconds between polls
POLL_MAX=50         # bounded: 50 checks at 100 ms ≈ five seconds

# ------------------------------------------------------------- runtime state --

MONITORS_JSON=""
MON_PRESENT=0 MON_ENABLED=0 MON_CONN=""
TV_PRESENT=0 TV_ENABLED=0 TV_CONN=""
TARGET_ROLE="" SRC_ACTIVE=0 SRC_CONN="" TGT_CONN="" TGT_WAS_ENABLED=0
VT_WHY="" VT_OBS=""
PREV_PATH="" LAST_TMP="" SNAP_HDR="" SNAP_VRR=""
PREV_LUA="" LAST_LUA_TMP=""
# Running config manager for this apply: hyprlang | lua (see detect_manager).
CFG_MGR=""
# Resolved request for the current apply (see parse_request/preflight_request).
REQ_ROLE="" REQ_RES="" REQ_W="" REQ_H="" REQ_HZ="" REQ_VRR="" REQ_HDR="" REQ_SCALE=""
REQ_BITDEPTH="" REQ_CM=""
# One cached `modetest -c` dump per run (read-only connector properties).
MODETEST_OUT="" MODETEST_TRIED=0
# Fresh DRM ground-truth view for the final verification (see drm_observe).
DRM_C="" DRM_E="" DRM_P=""
DRM_OBS="" DRM_WHY="" DRM_SKIP_LOGGED=0
DRM_ENC="" DRM_ST="" DRM_CS="" DRM_EOTF="" DRM_CRTC=""
DRM_MW="" DRM_MH="" DRM_MHZ="" DRM_VRR=""

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
usage: display-apply.sh <command> [key=value ...]
commands:
  status    print the active role: monitor, tv or unknown
  caps      print the attached displays' capabilities as one JSON object
            (modes, refresh rates, VRR/HDR support, scales, current state);
            no lock, no mutation
  ensure    recover to the monitor or an already-awake TV; return from an
            active TV in standby if the monitor is connected
  monitor   apply settings to the PHL 345E2:
              monitor [res=WxH] [hz=N] [vrr=0|1] [hdr=0|1] [scale=S]
            defaults: res=3440x1440 hz=74.98 vrr=0 hdr=0 scale=1
  tv        apply settings to the Philips UHDTV on native HDMI:
              tv [res=WxH] [hz=N] [vrr=0|1] [hdr=0|1] [scale=S]
            defaults: res=3840x2160 hz=144 vrr=1 hdr=1 scale=1.5
custom monitor modes (select with res= + hz=, no extra key):
  1920x1080@74.65  modeline, GPU Full aspect pillarbox
  2560x1440@74.89  modeline, GPU Full aspect pillarbox
exit codes: 0 success · 2 usage · 3 discovery/preflight or unknown config
manager (no mutation) · 4 apply/verify · 5 lock
EOF
  exit 2
}

cleanup() {
  [[ -n "${LAST_TMP:-}" ]] && rm -f -- "$LAST_TMP"
  [[ -n "${LAST_LUA_TMP:-}" ]] && rm -f -- "$LAST_LUA_TMP"
  [[ -n "${PREV_PATH:-}" ]] && rm -f -- "$PREV_PATH"
  [[ -n "${PREV_LUA:-}" ]] && rm -f -- "$PREV_LUA"
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

# Detect the running config manager once per apply. `hyprctl keyword` is
# refused under Lua (exit 0, no effect) and `hyprctl eval` is refused under
# hyprlang, so the two are told apart by the reply text of a side-effect-free
# eval. Anything else (no reply, other error) is unknown → exit 3, no mutation.
detect_manager() {
  local out
  out=$(hyprctl eval 'return 1' 2>&1) || true
  case "$out" in
    *"only supported with the lua config manager"*) CFG_MGR=hyprlang ;;
    ok) CFG_MGR=lua ;;
    *) die 3 "cannot determine the Hyprland config manager (hyprctl eval replied: ${out:-<nothing>})" ;;
  esac
  log "config manager: $CFG_MGR"
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
  if [[ "$role" == monitor ]]; then
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

role_present() { [[ "$1" == tv ]] && echo "$TV_PRESENT" || echo "$MON_PRESENT"; }
role_enabled() { [[ "$1" == tv ]] && echo "$TV_ENABLED" || echo "$MON_ENABLED"; }
role_conn()    { [[ "$1" == tv ]] && echo "$TV_CONN" || echo "$MON_CONN"; }
role_json()    { [[ "$1" == tv ]] && printf '%s' "$TV_ARR" || printf '%s' "$MON_ARR"; }
selector()     { [[ "$1" == tv ]] && echo "$TV_DESC" || echo "$MONITOR_DESC"; }
other()        { [[ "$1" == tv ]] && echo monitor || echo tv; }

compute_status() { # active role only; both or neither enabled is unknown
  if (( TV_PRESENT && TV_ENABLED )) && ! (( MON_PRESENT && MON_ENABLED )); then
    printf 'tv\n'
  elif (( MON_PRESENT && MON_ENABLED )) && ! (( TV_PRESENT && TV_ENABLED )); then
    printf 'monitor\n'
  else
    printf 'unknown\n'
  fi
}

# ------------------------------------------------------- resolved request ----

default_setting() { # default_setting <role> <res|hz|vrr|hdr|scale>
  local p v
  if [[ "$1" == tv ]]; then p=TV_DEF; else p=MON_DEF; fi
  case "$2" in
    res) v="${p}_RES" ;;
    hz) v="${p}_HZ" ;;
    vrr) v="${p}_VRR" ;;
    hdr) v="${p}_HDR" ;;
    scale) v="${p}_SCALE" ;;
    *) return 1 ;;
  esac
  printf '%s' "${!v}"
}

setting() { # setting <role> <key>: request value for the target role, else its default
  if [[ "$1" == "$REQ_ROLE" ]]; then
    case "$2" in
      res) printf '%s' "$REQ_RES"; return 0 ;;
      hz) printf '%s' "$REQ_HZ"; return 0 ;;
      vrr) printf '%s' "$REQ_VRR"; return 0 ;;
      hdr) printf '%s' "$REQ_HDR"; return 0 ;;
      scale) printf '%s' "$REQ_SCALE"; return 0 ;;
    esac
  fi
  default_setting "$1" "$2"
}

color_base() { # color_base <role> <hdr 0|1> → color profile key/value string
  if [[ "$1" == tv ]]; then
    if [[ "$2" == 1 ]]; then printf '%s' "$TV_HDR_COLOR"; else printf '%s' "$TV_SDR_COLOR"; fi
  else
    printf '%s' "$MON_SDR_COLOR"
  fi
}

color_kv() { # color_kv <role> <hdr> <key> → value from that color base
  local kv
  for kv in $(color_base "$1" "$2"); do
    if [[ "$kv" == "$3="* ]]; then printf '%s' "${kv#*=}"; return 0; fi
  done
  return 1
}

scale_valid() { # scale_valid <w> <h> <scale:0-2dp> → 0 when W/scale and H/scale are integral
  # Hyprland (Monitor.cpp) rounds a scale whose logical size is fractional;
  # compare as exact hundredths so 1.6 counts as 160/100.
  awk -v w="$1" -v h="$2" -v s="$3" 'BEGIN {
    s100 = int(s * 100 + 0.5)
    if (s100 <= 0) exit 1
    exit !(((w * 100) % s100 == 0) && ((h * 100) % s100 == 0))
  }'
}

custom_modeline() { # custom_modeline <res> <hz> → monitor-only custom modeline
  if [[ "$1" == "1920x1080" ]] && refresh_close "$2" "$CS2_HZ"; then
    printf '%s' "$CS2_MODELINE"
  elif [[ "$1" == "2560x1440" ]] && refresh_close "$2" "$CS2_2K_HZ"; then
    printf '%s' "$CS2_2K_MODELINE"
  else
    return 1
  fi
}

mode_for() { # mode_for <role> <res> <hz> → mode string for the generated config
  local ml
  if [[ "$1" == monitor ]] && ml=$(custom_modeline "$2" "$3"); then
    printf '%s' "$ml"
  else
    printf '%s@%s' "$2" "$3"
  fi
}

req_error() { # req_error <message> → usage error, exit 2
  log "ERROR(2): $*"
  usage
}

parse_request() { # parse_request <role> [key=value ...] → REQ_*; exit 2 on bad usage
  local role="$1" arg k v
  shift
  REQ_ROLE="$role"
  REQ_RES="" REQ_HZ="" REQ_VRR="" REQ_HDR="" REQ_SCALE=""
  for arg in "$@"; do
    [[ "$arg" == *=* ]] || req_error "malformed argument '$arg' (expected key=value)"
    k="${arg%%=*}"
    v="${arg#*=}"
    case "$k" in
      res)
        [[ -z "$REQ_RES" ]] || req_error "duplicate key res"
        [[ "$v" =~ ^[0-9]+x[0-9]+$ ]] || req_error "malformed res '$v' (want WxH)"
        REQ_RES="$v"
        ;;
      hz)
        [[ -z "$REQ_HZ" ]] || req_error "duplicate key hz"
        [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || req_error "malformed hz '$v' (want a number)"
        REQ_HZ="$v"
        ;;
      vrr)
        [[ -z "$REQ_VRR" ]] || req_error "duplicate key vrr"
        [[ "$v" == 0 || "$v" == 1 ]] || req_error "malformed vrr '$v' (want 0 or 1)"
        REQ_VRR="$v"
        ;;
      hdr)
        [[ -z "$REQ_HDR" ]] || req_error "duplicate key hdr"
        [[ "$v" == 0 || "$v" == 1 ]] || req_error "malformed hdr '$v' (want 0 or 1)"
        REQ_HDR="$v"
        ;;
      scale)
        [[ -z "$REQ_SCALE" ]] || req_error "duplicate key scale"
        [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || req_error "malformed scale '$v' (want a number)"
        REQ_SCALE="$v"
        ;;
      *)
        req_error "unknown key '$k'"
        ;;
    esac
  done
  REQ_RES="${REQ_RES:-$(default_setting "$role" res)}"
  REQ_HZ="${REQ_HZ:-$(default_setting "$role" hz)}"
  REQ_VRR="${REQ_VRR:-$(default_setting "$role" vrr)}"
  REQ_HDR="${REQ_HDR:-$(default_setting "$role" hdr)}"
  REQ_SCALE="${REQ_SCALE:-$(default_setting "$role" scale)}"
  REQ_W="${REQ_RES%x*}"
  REQ_H="${REQ_RES#*x}"
  REQ_BITDEPTH=$(color_kv "$role" "$REQ_HDR" bitdepth)
  REQ_CM=$(color_kv "$role" "$REQ_HDR" cm)
}

mode_advertised() { # mode_advertised <role-arr-json> <w> <h> <hz> (±0.1 Hz)
  jq -e --arg res "$2x$3" --argjson hz "$4" '
    [ .[0].availableModes[]?
      | capture("^(?<res>[0-9]+x[0-9]+)@(?<hz>[0-9.]+)Hz$")
      | {res, hz: (.hz | tonumber)}
    ]
    | any(.res == $res and ((.hz - $hz) as $d | if $d < 0 then -$d else $d end) <= 0.1)
  ' <<<"$1" >/dev/null 2>&1
}

# ------------------------------------------------------ hardware capability ---

load_modetest() { # cache one read-only connector property dump for this run
  (( MODETEST_TRIED )) && return 0
  MODETEST_TRIED=1
  MODETEST_OUT=""
  command -v modetest >/dev/null 2>&1 || return 0
  MODETEST_OUT=$(timeout 10 modetest -c 2>/dev/null) || MODETEST_OUT=""
}

vrr_capable() { # vrr_capable <connector> → true|false; false when unreadable
  local conn="$1" val
  load_modetest
  [[ -n "$MODETEST_OUT" ]] || { echo false; return 0; }
  val=$(awk -v want="$conn" '
    $3 == "connected" || $3 == "disconnected" { inconn = ($4 == want); seen = 0; next }
    inconn && $1 ~ /^[0-9]+$/ && $2 == "vrr_capable:" { seen = 1; next }
    inconn && seen && $1 == "value:" { print $2; exit }
  ' <<<"$MODETEST_OUT")
  [[ "$val" == 1 ]] && echo true || echo false
}

hdr_capable() { # hdr_capable <connector> → true|false from that connector's EDID
  local conn="$1" f out
  command -v di-edid-decode >/dev/null 2>&1 || { echo false; return 0; }
  f=$(ls /sys/class/drm/card*-"$conn"/edid 2>/dev/null | head -1)
  [[ -n "$f" ]] || { echo false; return 0; }
  # di-edid-decode exits non-zero on EDID warnings, so match the decoded text
  # instead of relying on its (pipefail-sensitive) pipeline status.
  out=$(di-edid-decode "$f" 2>/dev/null || true)
  if [[ "$out" == *"SMPTE ST2084"* ]]; then
    echo true
  else
    echo false
  fi
}

preflight_request() { # validate REQ_* before any write; exit 3 on failure
  local role="$REQ_ROLE" conn s ok
  conn=$(role_conn "$role")
  ok=0
  for s in $SCALE_CANDIDATES; do
    if num_close "$REQ_SCALE" "$s"; then ok=1; break; fi
  done
  (( ok )) || die 3 "scale $REQ_SCALE is not supported (allowed: $SCALE_CANDIDATES)"
  scale_valid "$REQ_W" "$REQ_H" "$REQ_SCALE" ||
    die 3 "scale $REQ_SCALE gives a fractional logical size at ${REQ_W}x${REQ_H}"
  if [[ "$role" == monitor ]] && custom_modeline "$REQ_RES" "$REQ_HZ" >/dev/null; then
    :
  elif mode_advertised "$(role_json "$role")" "$REQ_W" "$REQ_H" "$REQ_HZ"; then
    :
  elif [[ "$REQ_RES" == "$(default_setting "$role" res)" ]] &&
       refresh_close "$REQ_HZ" "$(default_setting "$role" hz)"; then
    # The shipped default is a live-verified request even when Hyprland does
    # not list it (the TV's 3840x2160@144 is absent while it is disabled).
    :
  else
    die 3 "$role has no advertised mode ${REQ_RES}@${REQ_HZ} (±0.1 Hz)"
  fi
  # Optional probes (modetest/di-edid-decode) must never block a role's own
  # default or a failover: only an upgrade over that default is gated.
  if [[ "$REQ_VRR" == 1 && "$REQ_VRR" != "$(default_setting "$role" vrr)" ]]; then
    [[ "$(vrr_capable "$conn")" == true ]] || die 3 "$conn does not report vrr_capable=1"
  fi
  if [[ "$REQ_HDR" == 1 && "$REQ_HDR" != "$(default_setting "$role" hdr)" ]]; then
    [[ "$role" == tv ]] || die 3 "hdr=1 is not defined for the monitor"
    [[ "$(hdr_capable "$conn")" == true ]] || die 3 "$conn EDID does not advertise HDR (SMPTE ST2084)"
  fi
}

emit_block() { # emit_block <role> <selector> <position-override> <disabled 0|1>
  local role="$1" sel="$2" pos="$3" dis="$4" kv k v
  printf 'monitorv2 {\n'
  printf '    output = %s\n' "$sel"
  printf '    position = %s\n' "${pos:-0x0}"
  printf '    mode = %s\n' "$(mode_for "$role" "$(setting "$role" res)" "$(setting "$role" hz)")"
  printf '    scale = %s\n' "$(setting "$role" scale)"
  for kv in $(color_base "$role" "$(setting "$role" hdr)"); do
    k="${kv%%=*}"
    v="${kv#*=}"
    case "$k" in
      bitdepth|cm|sdr_eotf|sdrbrightness|sdrsaturation|sdr_min_luminance|sdr_max_luminance|min_luminance|max_luminance|max_avg_luminance|supports_hdr|supports_wide_color)
        printf '    %s = %s\n' "$k" "$v" ;;
      *) die 4 "internal error: unknown color key '$k'" ;;
    esac
  done
  # No per-monitor vrr here on purpose: Hyprland 0.56.2's CMonitorRule::compare()
  # ignores vrr, so a vrr-only change is a FULL_MATCH and the monitor rule is
  # not re-applied; the stale per-monitor value would then override misc:vrr in
  # ensureVRR(). Exactly one display is active at a time, so the global
  # misc:vrr (written above, reasserted after each reload) is the per-display
  # VRR control.
  (( dis )) && printf '    disabled = 1\n'
  printf '}\n'
}

# Lua twin of emit_block: same fields and values, hl.monitor() form. Types per
# MONITOR_FIELDS in LuaBindingsConfigRules.cpp: mode/position/scale/cm/sdr_eotf
# are strings, the rest numbers; no per-monitor vrr (see emit_block).
emit_block_lua() { # emit_block_lua <role> <selector> <position-override> <disabled 0|1>
  local role="$1" sel="$2" pos="$3" dis="$4" kv k v
  printf 'hl.monitor({\n'
  printf '    output = "%s",\n' "$sel"
  printf '    position = "%s",\n' "${pos:-0x0}"
  printf '    mode = "%s",\n' "$(mode_for "$role" "$(setting "$role" res)" "$(setting "$role" hz)")"
  printf '    scale = "%s",\n' "$(setting "$role" scale)"
  for kv in $(color_base "$role" "$(setting "$role" hdr)"); do
    k="${kv%%=*}"
    v="${kv#*=}"
    case "$k" in
      cm|sdr_eotf)
        printf '    %s = "%s",\n' "$k" "$v" ;;
      bitdepth|sdrbrightness|sdrsaturation|sdr_min_luminance|sdr_max_luminance|min_luminance|max_luminance|max_avg_luminance|supports_hdr|supports_wide_color)
        printf '    %s = %s,\n' "$k" "$v" ;;
      *) die 4 "internal error: unknown color key '$k'" ;;
    esac
  done
  # hl.monitor merges identical selectors; an omitted field keeps its base value.
  if (( dis )); then
    printf '    disabled = true,\n'
  else
    printf '    disabled = false,\n'
  fi
  printf '})\n'
}

# Generated files: role-dependent globals first (misc:vrr, quirks:prefer_hdr)
# so reload-time rule creation sees them despite later-sourced base defaults,
# then exactly two monitor rules (target first). Both the hyprlang file and its
# Lua module carry the same state. Each is written to a sibling temp file,
# validated, then atomically renamed (hyprlang first, Lua last: in Lua mode the
# rename of the required module is what the config watcher reacts to).
write_generated() { # write_generated <target-role> <staging|final>
  local role="$1" kind="$2" tmp ltmp blocks outs lblocks louts
  local other_role pref vrr opos="" odis=1
  other_role=$(other "$role")
  pref=$(setting "$role" hdr)
  if [[ "$role" == tv && ! "${HYPRLAND_INSTANCE_SIGNATURE:-}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    die 4 "cannot scope the TV profile to the current Hyprland instance"
  fi
  vrr=$(setting "$role" vrr)
  if [[ "$kind" == staging && "$SRC_ACTIVE" == 1 ]]; then
    # Keep the connected, active source at a non-overlapping position.
    opos="auto-right"; odis=0
  fi
  # Final state (or inactive/absent source): non-target disabled by description.
  tmp="${GENERATED_CONFIG}.tmp.$$"
  ltmp="${GENERATED_LUA}.tmp.$$"
  LAST_TMP="$tmp"
  LAST_LUA_TMP="$ltmp"
  {
    printf 'misc {\n    vrr = %s\n}\n' "$vrr"
    printf 'quirks {\n    prefer_hdr = %s\n}\n' "$pref"
    emit_block "$role" "$(selector "$role")" "" 0
    emit_block "$other_role" "$(selector "$other_role")" "$opos" "$odis"
  } >"$tmp" || die 4 "failed to write generated config temp file"
  {
    printf -- '-- Generated by display_apply.sh; rewritten on every apply. Do not edit.\n'
    if [[ "$role" == tv ]]; then
      # A fresh compositor starts from the base monitor rules and must
      # rediscover TV power before it can enable HDMI.
      printf 'if os.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= "%s" then return {} end\n' \
        "$HYPRLAND_INSTANCE_SIGNATURE"
    fi
    printf 'hl.config({ misc = { vrr = %s }, quirks = { prefer_hdr = %s } })\n' "$vrr" "$pref"
    emit_block_lua "$role" "$(selector "$role")" "" 0
    emit_block_lua "$other_role" "$(selector "$other_role")" "$opos" "$odis"
    printf 'return {}\n'
  } >"$ltmp" || die 4 "failed to write generated Lua temp file"
  [[ -s "$tmp" ]] || die 4 "generated config is empty"
  [[ -s "$ltmp" ]] || die 4 "generated Lua module is empty"
  blocks=$(grep -c '^monitorv2 {' "$tmp")
  outs=$(grep -c '^    output = ' "$tmp")
  [[ "$blocks" == 2 && "$outs" == 2 ]] ||
    die 4 "generated config invalid (blocks=$blocks outputs=$outs)"
  lblocks=$(grep -c '^hl\.monitor({' "$ltmp")
  louts=$(grep -c '^    output = "desc:' "$ltmp")
  [[ "$lblocks" == 2 && "$louts" == 2 ]] ||
    die 4 "generated Lua module invalid (blocks=$lblocks outputs=$louts)"
  if command -v luac5.5 >/dev/null 2>&1; then
    luac5.5 -p -- "$ltmp" || die 4 "generated Lua module failed luac5.5 -p"
  fi
  mv -f -- "$tmp" "$GENERATED_CONFIG" || die 4 "atomic rename of generated config failed"
  LAST_TMP=""
  mv -f -- "$ltmp" "$GENERATED_LUA" || die 4 "atomic rename of generated Lua module failed"
  LAST_LUA_TMP=""
}

# ------------------------------------------------------------ verification ----

num_close() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a == b) }'; }

refresh_close() { # |got - want| <= 0.1
  awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 0.1) }'
}

# DRM ground truth: what the kernel is actually driving, read from modetest.
# Used by the final verification because Hyprland's view can lag or disagree
# with the DRM state. Any probe/parse failure is a skip, never a failure.

drm_connector_info() { # <connector> → "encoder|status|colorspace|eotf-hex"
  awk -v want="$1" '
    BEGIN { found = 0; prop = ""; inval = 0; enc = ""; st = ""; cs = ""; blob = "" }
    $3 == "connected" || $3 == "disconnected" {
      if ($4 == want) { found = 1; enc = $2; st = $3; prop = ""; inval = 0 }
      else if (found) exit
      next
    }
    !found { next }
    $1 ~ /^[0-9]+$/ && $2 ~ /:$/ {
      prop = $2
      sub(/:$/, "", prop)
      inval = (prop == "HDR_OUTPUT_METADATA")
      next
    }
    prop == "Colorspace" && $1 == "value:" { cs = $2; next }
    inval && $1 == "value:" && $2 != "" { blob = $2; next }
    inval && $1 ~ /^[0-9a-fA-F]+$/ { blob = blob $1; next }
    END {
      if (!found) exit 1
      eotf = ""
      # struct hdr_output_metadata: byte 0-3 metadata type, byte 4 eotf (PQ = 0x02).
      if (blob != "") eotf = tolower(substr(blob, 9, 2))
      printf "%s|%s|%s|%s\n", enc, st, cs, eotf
    }
  ' <<<"$DRM_C"
}

drm_crtc_for_encoder() { # <encoder-id> → crtc id (empty when unmapped)
  awk -v want="$1" '
    /^Encoders:/ { ins = 1; next }
    ins && $1 ~ /^[0-9]+$/ && $1 == want { print $2; exit }
  ' <<<"$DRM_E"
}

drm_crtc_state() { # <crtc-id> → "W H REFRESH VRR_ENABLED"
  awk -v want="$1" '
    BEGIN { insec = 0; incrtc = 0; mw = ""; mh = ""; mhz = ""; vrr = ""; invrr = 0 }
    /^CRTCs:/ { insec = 1; next }
    /^Planes:/ { insec = 0; next }
    !insec { next }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^\(/ { incrtc = ($1 == want); next }
    incrtc && $1 == "#0" && $2 ~ /^[0-9]+x[0-9]+(@[0-9.]+)?$/ {
      # User-defined modes carry a name like 1920x1080@74; WxH is before '@'.
      name = $2
      sub(/@.*/, "", name)
      split(name, a, "x"); mw = a[1]; mh = a[2]; mhz = $3; next
    }
    incrtc && $1 ~ /^[0-9]+$/ && $2 == "VRR_ENABLED:" { invrr = 1; next }
    incrtc && invrr && $1 == "value:" { vrr = $2; invrr = 0; next }
    END {
      if (mw == "" || vrr == "") exit 1
      printf "%s %s %s %s\n", mw, mh, mhz, vrr
    }
  ' <<<"$DRM_P"
}

drm_observe() { # drm_observe <connector>: fresh DRM view → DRM_*; 0 parsed, 2 skipped
  local conn="$1" info state
  DRM_OBS=""; DRM_WHY=""
  DRM_ENC="" DRM_ST="" DRM_CS="" DRM_EOTF="" DRM_CRTC=""
  DRM_MW="" DRM_MH="" DRM_MHZ="" DRM_VRR=""
  command -v modetest >/dev/null 2>&1 || { DRM_WHY="modetest not installed"; return 2; }
  DRM_C=$(timeout 10 modetest -c 2>/dev/null) || DRM_C=""
  DRM_E=$(timeout 10 modetest -e 2>/dev/null) || DRM_E=""
  [[ -n "$DRM_C" && -n "$DRM_E" ]] || { DRM_WHY="modetest -c/-e failed"; return 2; }
  info=$(drm_connector_info "$conn") || { DRM_WHY="connector $conn not found in modetest -c"; return 2; }
  IFS='|' read -r DRM_ENC DRM_ST DRM_CS DRM_EOTF <<<"$info"
  DRM_CRTC=$(drm_crtc_for_encoder "$DRM_ENC")
  DRM_OBS="$conn: enc=${DRM_ENC:-none} crtc=${DRM_CRTC:-none} status=${DRM_ST:-unknown}"
  [[ "$DRM_ST" == connected ]] || return 0
  [[ -n "$DRM_CRTC" && "$DRM_CRTC" != 0 ]] || { DRM_OBS+=" (no active CRTC)"; return 0; }
  DRM_P=$(timeout 10 modetest -p 2>/dev/null) || DRM_P=""
  [[ -n "$DRM_P" ]] || { DRM_WHY="modetest -p failed"; return 2; }
  state=$(drm_crtc_state "$DRM_CRTC") || { DRM_WHY="CRTC $DRM_CRTC not parseable in modetest -p"; return 2; }
  IFS=' ' read -r DRM_MW DRM_MH DRM_MHZ DRM_VRR <<<"$state"
  DRM_OBS+=" mode=${DRM_MW}x${DRM_MH}@${DRM_MHZ} VRR_ENABLED=$DRM_VRR Colorspace=${DRM_CS:-none} HDR_eotf=${DRM_EOTF:-none}"
  [[ -n "$DRM_CS" ]] || { DRM_WHY="connector $conn has no Colorspace property"; return 2; }
  return 0
}

drm_check() { # drm_check <conn> <w> <h> <hz> <vrr 0|1> <hdr 0|1>; 1 with VT_WHY on mismatch
  local conn="$1" w="$2" h="$3" hz="$4" wvrr="$5" whdr="$6"
  drm_observe "$conn"
  (( $? == 0 )) || return 0   # skipped: rely on the Hyprland-level checks
  if [[ "$DRM_ST" != connected ]]; then
    VT_WHY="DRM connector $conn is ${DRM_ST:-unknown}"
    return 1
  fi
  if [[ -z "$DRM_CRTC" || "$DRM_CRTC" == 0 ]]; then
    VT_WHY="DRM connector $conn has no CRTC"
    return 1
  fi
  (( DRM_MW == w && DRM_MH == h )) || { VT_WHY="DRM mode ${DRM_MW}x${DRM_MH} != ${w}x${h}"; return 1; }
  refresh_close "$DRM_MHZ" "$hz" || { VT_WHY="DRM refresh $DRM_MHZ not within 0.1 Hz of $hz"; return 1; }
  [[ "$DRM_VRR" == "$wvrr" ]] || { VT_WHY="DRM VRR_ENABLED=$DRM_VRR != $wvrr"; return 1; }
  if (( whdr )); then
    [[ "$DRM_CS" == 9 ]] || { VT_WHY="DRM Colorspace=$DRM_CS != 9 (BT2020_RGB)"; return 1; }
    [[ -n "$DRM_EOTF" ]] || { VT_WHY="DRM HDR_OUTPUT_METADATA missing (want eotf 0x02)"; return 1; }
    [[ "$DRM_EOTF" == 02 ]] || { VT_WHY="DRM HDR_OUTPUT_METADATA eotf=0x$DRM_EOTF != 0x02"; return 1; }
  else
    [[ "$DRM_CS" == 0 ]] || { VT_WHY="DRM Colorspace=$DRM_CS != 0 (Default)"; return 1; }
    [[ -z "$DRM_EOTF" || "$DRM_EOTF" == 00 ]] || { VT_WHY="DRM HDR_OUTPUT_METADATA eotf=0x$DRM_EOTF != 0x00"; return 1; }
  fi
  return 0
}

get_option_val() { # live int value of a keyword through IPC
  local out
  out=$(hyprctl -j getoption "$1" 2>/dev/null) || return 1
  jq -er 'if type == "object" then ((.int // .str) // empty | tostring) else empty end' <<<"$out" 2>/dev/null
}

get_prefer_hdr() { get_option_val quirks:prefer_hdr; }
get_misc_vrr()   { get_option_val misc:vrr; }

verify_target() { # verify_target <role> <snapshot-json>; sets VT_WHY/VT_OBS
  local role="$1" json="$2" arr n conn
  local disabled width height rr scale fmt cm vrr dpms want_vrr
  VT_WHY=""
  arr=$(role_match "$role" "$json") || { VT_WHY="identity query failed"; return 1; }
  n=$(jq 'length' <<<"$arr")
  (( n == 1 )) || { VT_WHY="$role identity matches=$n (need exactly 1)"; return 1; }
  conn=$(jq -r '.[0].name' <<<"$arr")
  if [[ "$role" == tv && ! "$conn" =~ ^HDMI-A- ]]; then
    VT_WHY="tv is on non-HDMI connector $conn"
    return 1
  fi
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
  (( width == REQ_W && height == REQ_H )) || { VT_WHY="mode ${width}x${height} != ${REQ_W}x${REQ_H}"; return 1; }
  refresh_close "$rr" "$REQ_HZ" || { VT_WHY="refresh $rr not within 0.1 Hz of $REQ_HZ"; return 1; }
  num_close "$scale" "$REQ_SCALE" || { VT_WHY="scale $scale != $REQ_SCALE"; return 1; }
  if [[ "$REQ_BITDEPTH" == "10" ]]; then
    case "$fmt" in
      XRGB2101010|XBGR2101010|ARGB2101010) ;;
      *) VT_WHY="currentFormat $fmt is not 10-bit"; return 1 ;;
    esac
  fi
  [[ "$cm" == "$REQ_CM" ]] || { VT_WHY="cm $cm != $REQ_CM"; return 1; }
  want_vrr=$([[ "$REQ_VRR" == "1" ]] && echo true || echo false)
  [[ "$vrr" == "$want_vrr" ]] || { VT_WHY="vrr $vrr != $want_vrr"; return 1; }
  return 0
}
verify_final() { # verify_final <role> <snapshot-json>: request + non-target off + globals + DRM
  verify_target "$@" || return 1
  local role="$1" oarr on odis hdr want vrr conn
  oarr=$(role_match "$(other "$role")" "$2") || { VT_WHY="non-target query failed"; return 1; }
  on=$(jq 'length' <<<"$oarr")
  if (( on > 0 )); then
    odis=$(jq -r '.[0].disabled' <<<"$oarr")
    [[ "$odis" == "true" ]] || { VT_WHY="$(other "$role") is still enabled"; return 1; }
  fi
  hdr=$(get_prefer_hdr) || { VT_WHY="quirks:prefer_hdr unreadable"; return 1; }
  (( hdr == REQ_HDR )) || { VT_WHY="quirks:prefer_hdr=$hdr != $REQ_HDR"; return 1; }
  vrr=$(get_misc_vrr) || { VT_WHY="misc:vrr unreadable"; return 1; }
  (( vrr == REQ_VRR )) || { VT_WHY="misc:vrr=$vrr != $REQ_VRR"; return 1; }
  # Ground truth: the kernel's DRM state must match the request as well. A
  # missing/failing modetest only logs once and never blocks the apply.
  conn=$(role_conn "$role")
  drm_check "$conn" "$REQ_W" "$REQ_H" "$REQ_HZ" "$REQ_VRR" "$REQ_HDR" || return 1
  if [[ -n "$DRM_WHY" && "$DRM_SKIP_LOGGED" == 0 ]]; then
    log "DRM check skipped: $DRM_WHY"
    DRM_SKIP_LOGGED=1
  fi
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

# Set the two globals live. Lua: one `hyprctl eval` (hl.config); `keyword` is
# refused there with exit 0, so the reply text is checked too. hyprlang: keyword.
set_globals() { # set_globals <vrr> <prefer_hdr>
  local out
  if [[ "$CFG_MGR" == lua ]]; then
    out=$(hyprctl eval "hl.config({ misc = { vrr = $1 }, quirks = { prefer_hdr = $2 } })" 2>&1) || {
      log "eval of hl.config failed: $out"; return 1; }
    [[ "$out" != error* ]] || { log "eval of hl.config failed: $out"; return 1; }
  else
    hyprctl keyword misc:vrr "$1" >/dev/null 2>&1 || return 1
    hyprctl keyword quirks:prefer_hdr "$2" >/dev/null 2>&1 || return 1
  fi
}

apply_role_globals() { # reassert the requested globals through IPC after each reload
  local role="$1"
  set_globals "$(setting "$role" vrr)" "$(setting "$role" hdr)"
}

# Reload, then (Lua) check that the generated module loaded cleanly: `reload`
# replies ok even when the Lua file raised errors, so read `configerrors`.
# Only errors that mention the generated module fail the apply. The reload is
# synchronous in both managers; in Lua mode the config watcher may add one
# more async reload after the module rename, which re-reads the same file and
# is harmless (the verification polls state, never timing).
reload_config() {
  hyprctl reload >/dev/null 2>&1 || return 1
  [[ "$CFG_MGR" == lua ]] || return 0
  local errs
  errs=$(hyprctl configerrors 2>&1) || true
  if grep -qi 'display-switcher-generated' <<<"$errs"; then
    log "ERROR: config errors in the generated module after reload: $(tr '\n' ' ' <<<"$errs" | cut -c1-400)"
    return 1
  fi
  return 0
}

wake_target_if_needed() { # DPMS wake of the target, only when it is off
  fetch_monitors || return 1
  local on out
  on=$(jq -r --arg c "$TGT_CONN" '[.[] | select(.name == $c) | .dpmsStatus][0]' <<<"$MONITORS_JSON" 2>/dev/null)
  [[ "$on" == "false" ]] || return 0
  log "target $TGT_CONN dpms is off; waking"
  if [[ "$CFG_MGR" == lua ]]; then
    # Hyprland #16471: a selector matching no monitor hits ALL of them, so only
    # a connector name taken from this run's snapshot is ever passed. Unknown
    # action strings silently mean "toggle": "enable" is exact.
    [[ "$TGT_CONN" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    out=$(hyprctl dispatch "hl.dsp.dpms({ action = \"enable\", monitor = \"$TGT_CONN\" })" 2>&1) || return 1
    [[ "$out" != error* ]]
  else
    hyprctl dispatch dpms on "$TGT_CONN" >/dev/null 2>&1
  fi
}

# ------------------------------------------------------------ workspaces ------

move_workspace() { # move_workspace <id> <connector>
  local out
  if [[ "$CFG_MGR" == lua ]]; then
    out=$(hyprctl dispatch "hl.dsp.workspace.move({ workspace = \"$1\", monitor = \"$2\" })" 2>&1) || return 1
    [[ "$out" != error* ]]
  else
    hyprctl dispatch moveworkspacetomonitor "$1" "$2" >/dev/null 2>&1
  fi
}

migrate_workspaces() { # migrate_workspaces <from-connector> <to-connector>
  local from="$1" to="$2" wss ids id moved=0
  wss=$(hyprctl -j workspaces 2>/dev/null) || { log "WARNING: workspace listing failed; skipping migration"; return 0; }
  ids=$(jq -r --arg m "$from" '.[] | select(.monitor == $m) | .id' <<<"$wss" 2>/dev/null) || return 0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if move_workspace "$id" "$to"; then
      moved=$((moved + 1))
    else
      log "WARNING: failed to move workspace $id to $to"
    fi
  done <<<"$ids"
  (( moved )) && log "migrated $moved workspace(s) from $from to $to"
  return 0
}

# ----------------------------------------------------------- rollback path ----

snapshot_state() { # previous generated files (byte copies) + live globals (prefer_hdr, vrr)
  PREV_PATH=""
  PREV_LUA=""
  if [[ -f "$GENERATED_CONFIG" ]]; then
    PREV_PATH="${GENERATED_CONFIG}.prev.$$"
    cp -f -- "$GENERATED_CONFIG" "$PREV_PATH" || die 3 "could not snapshot the generated config"
  fi
  if [[ -f "$GENERATED_LUA" ]]; then
    PREV_LUA="${GENERATED_LUA}.prev.$$"
    cp -f -- "$GENERATED_LUA" "$PREV_LUA" || die 3 "could not snapshot the generated Lua module"
  fi
  SNAP_HDR=$(get_prefer_hdr || true)
  case "$SNAP_HDR" in
    0|1|2) ;;
    *)
      [[ -n "$PREV_PATH" ]] && rm -f -- "$PREV_PATH"
      [[ -n "$PREV_LUA" ]] && rm -f -- "$PREV_LUA"
      die 3 "could not read quirks:prefer_hdr before mutation"
      ;;
  esac
  SNAP_VRR=$(get_misc_vrr || true)
  case "$SNAP_VRR" in
    0|1|2|3) ;;
    *)
      [[ -n "$PREV_PATH" ]] && rm -f -- "$PREV_PATH"
      [[ -n "$PREV_LUA" ]] && rm -f -- "$PREV_LUA"
      die 3 "could not read misc:vrr before mutation"
      ;;
  esac
}

restore_on_failure() { # restore persistent files + reload them, then snapshotted globals via IPC
  if (( ! SRC_ACTIVE && ! TGT_WAS_ENABLED )); then
    # Nothing was active before this apply, so the previous files are a
    # zero-display state. Keep the new files: they at least enable the target.
    log "no display was active before this apply; keeping the new generated config"
    [[ -n "$PREV_PATH" ]] && rm -f -- "$PREV_PATH"
    [[ -n "$PREV_LUA" ]] && rm -f -- "$PREV_LUA"
    PREV_PATH=""
    PREV_LUA=""
    return 0
  fi
  local restored=0
  if [[ -n "$PREV_PATH" && -f "$PREV_PATH" ]]; then
    mv -f -- "$PREV_PATH" "$GENERATED_CONFIG" && restored=1
    PREV_PATH=""
  else
    rm -f -- "$GENERATED_CONFIG"
    log "removed generated config (none existed before this apply)"
  fi
  if [[ -n "$PREV_LUA" && -f "$PREV_LUA" ]]; then
    mv -f -- "$PREV_LUA" "$GENERATED_LUA" && restored=1
    PREV_LUA=""
  else
    rm -f -- "$GENERATED_LUA"
    log "removed generated Lua module (none existed before this apply)"
  fi
  if (( restored )); then
    # The restored files enable exactly their previous target, so this reload
    # keeps one monitor active while returning live topology to the prior
    # exclusive state; globals are reasserted through IPC after it.
    if reload_config; then
      log "restored previous generated config and reloaded it"
    else
      log "ERROR: reload of restored config failed; live topology may differ from the restored files"
    fi
  fi
  if set_globals "$SNAP_VRR" "$SNAP_HDR"; then
    log "restored misc:vrr=$SNAP_VRR and quirks:prefer_hdr=$SNAP_HDR through IPC"
  else
    log "ERROR: failed to restore misc:vrr/quirks:prefer_hdr through IPC"
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
    if [[ -n "${TGT_CONN:-}" ]]; then
      if drm_observe "$TGT_CONN"; then
        log "  DRM ${DRM_OBS}"
      else
        log "  DRM unavailable: ${DRM_WHY}"
      fi
    fi
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

tv_control() {
  local script
  script=$(readlink -f -- "${BASH_SOURCE[0]}") || return 1
  python3 "${script%/*}/tv_control.py" "$@"
}


apply_flow() { # apply_flow <role> <explicit|automatic>; caller holds the lock
  local role="$1" origin="$2" other_role
  other_role=$(other "$role")
  detect_manager

  fetch_monitors || die 3 "discovery failed: hyprctl -j monitors all returned no valid JSON"
  discover

  local present
  present=$(role_present "$role")
  (( present == 1 )) || die 3 "$role target not connected or not uniquely identified"
  # The requested mode and capabilities must hold before anything is written.
  preflight_request
  if [[ "$role" == tv ]]; then
    if [[ "$origin" == automatic ]]; then
      [[ "$(tv_control state)" == on ]] ||
        die 3 "TV power is not confirmed On; automatic failover will not wake it"
    else
      tv_control wake ||
        die 3 "TV did not report On; turn it on with the remote and try again"
      fetch_monitors || die 3 "display discovery failed after TV wake"
      discover
      (( TV_PRESENT )) || die 3 "TV HDMI target is no longer connected"
      preflight_request
      tv_control hdmi1 ||
        die 3 "could not select TV HDMI 1; check the TV and try again"
    fi
  fi

  TGT_CONN=$(role_conn "$role")
  SRC_ACTIVE=0
  SRC_CONN=""
  if [[ "$(role_present "$other_role")" == 1 && "$(role_enabled "$other_role")" == 1 ]]; then
    SRC_ACTIVE=1
    SRC_CONN=$(role_conn "$other_role")
  fi
  TGT_WAS_ENABLED=$(role_enabled "$role")
  # A target waking from a dark session (disabled output, panel asleep) can
  # report 0x0 for several seconds; allow 15 s instead of 5 s.
  (( SRC_ACTIVE || TGT_WAS_ENABLED )) || POLL_MAX=150

  snapshot_state
  log "applying $role ${REQ_RES}@${REQ_HZ} vrr=$REQ_VRR hdr=$REQ_HDR scale=$REQ_SCALE (target=$TGT_CONN, source=$( ((SRC_ACTIVE)) && echo "$SRC_CONN" || echo none ))"

  # 1) staging: target active with its requested settings; any active source kept.
  TARGET_ROLE="$role"
  write_generated "$role" staging
  reload_config || fail_apply "staging reload failed (command error or generated-module config errors)"
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
  reload_config || fail_apply "final reload failed (command error or generated-module config errors)"
  apply_role_globals "$role" || fail_apply "final global apply failed (misc:vrr/quirks:prefer_hdr)"
  wake_target_if_needed || log "WARNING: dpms wake failed; verification will catch dpms state"
  poll_verify final_ok || fail_apply "final verification failed: ${VT_WHY:-state not converged} (observed: ${VT_OBS:-none})"

  rm -f -- "${PREV_PATH:-}" "${PREV_LUA:-}" 2>/dev/null
  PREV_PATH=""
  PREV_LUA=""
  log "$role mode applied and verified"
  echo "$role mode applied"
}

tv_needs_monitor() {
  local state attempt
  for attempt in 1 2 3; do
    state=$(tv_control state)
    case "$state" in
      on) return 1 ;;
      standby)
        log "TV in standby; returning to monitor"
        return 0
        ;;
    esac
    (( attempt == 3 )) || sleep 2
  done
  log "TV power could not be confirmed after three checks; returning to monitor"
  return 0
}


ensure_flow() { # ensure_flow — caller holds the lock
  fetch_monitors || die 3 "discovery failed: hyprctl -j monitors all returned no valid JSON"
  discover
  local role
  if (( MON_PRESENT && MON_ENABLED )); then
    echo "monitor active; nothing to do"
    return 0
  elif (( TV_PRESENT && TV_ENABLED )); then
    if (( ! MON_PRESENT )) || ! tv_needs_monitor; then
      echo "TV active; nothing to do"
      return 0
    fi
    role=monitor
  elif (( MON_PRESENT )); then
    role=monitor
  elif (( TV_PRESENT )); then
    role=tv
    log "no active display; evaluating TV failover"
  else
    die 3 "no known display connected"
  fi
  parse_request "$role"
  apply_flow "$role" automatic
}

# -------------------------------------------------------------------- caps ---

modes_json() { # modes_json <availableModes> <extra-rates> <def-res> <def-hz> <scale-candidates>
  # modes[].scales mirrors scale_valid(): candidates whose logical size is
  # integral in both dimensions (Hyprland rounds/errors otherwise).
  jq -c --argjson extra "$2" --arg dres "$3" --argjson dhz "$4" --arg scales "$5" '
    ( [ .[]?
        | capture("^(?<res>[0-9]+x[0-9]+)@(?<hz>[0-9.]+)Hz$")
        | {res, hz: (((.hz | tonumber) * 100 | round) / 100)}
      ]
      + $extra
      + [{res: $dres, hz: $dhz}]
    )
    | group_by(.res)
    | map({
        res: .[0].res,
        rates: (
          group_by(.hz)
          | map((([.[] | select(has("custom"))][0]) // .[0]) | del(.res))
          | sort_by(-.hz)
        ),
        scales: (
          (.[0].res | split("x") | map(tonumber)) as $d
          | [ $scales | split(" ") | map(tonumber) | .[]
              | select((((. * 100) | round) as $s100
                        | (($d[0] * 100) % $s100 == 0) and (($d[1] * 100) % $s100 == 0))) ]
        )
      })
    | sort_by(.res | split("x") | map(tonumber) | (.[0] * .[1]))
    | reverse
  ' <<<"$1"
}

display_caps_json() { # display_caps_json <role> → one caps display object
  local role="$1" arr present conn transport enabled vrr hdr modes current extras power=""
  arr=$(role_json "$role")
  present=$(jq 'length' <<<"$arr")
  conn=""; transport=""; enabled=0; vrr=false; hdr=false; modes='[]'; current='null'
  extras='[]'
  if (( present )); then
    conn=$(jq -r '.[0].name' <<<"$arr")
    enabled=$(jq -r 'if .[0].disabled == false then 1 else 0 end' <<<"$arr")
    vrr=$(vrr_capable "$conn")
    hdr=$(hdr_capable "$conn")
    [[ "$role" != tv ]] || power=$(tv_control state)
    if [[ "$role" == monitor ]]; then
      extras=$(printf '[{"res":"1920x1080","hz":%s,"custom":"cs2"},{"res":"2560x1440","hz":%s,"custom":"cs2-2k"}]' "$CS2_HZ" "$CS2_2K_HZ")
    fi
    modes=$(modes_json "$(jq -c '.[0].availableModes // []' <<<"$arr")" \
      "$extras" "$(default_setting "$role" res)" "$(default_setting "$role" hz)" "$SCALE_CANDIDATES")
    if (( enabled )); then
      current=$(jq -c '.[0] | {
        res: "\(.width)x\(.height)",
        hz: ((.refreshRate * 100 | round) / 100),
        vrr: .vrr,
        hdr: (.colorManagementPreset == "hdr"),
        scale: .scale
      }' <<<"$arr")
    fi
    if [[ "$conn" == HDMI-A-* ]]; then
      transport="HDMI"
    elif [[ "$conn" == DP-* ]]; then
      transport="DP"
    else
      transport="${conn%-*}"
    fi
  fi
  jq -nc \
    --arg role "$role" \
    --arg device "$([[ "$role" == tv ]] && echo "$TV_MODEL" || echo "$MON_MODEL")" \
    --arg conn "$conn" \
    --arg transport "$transport" \
    --arg power "$power" \
    --argjson enabled "$enabled" \
    --argjson vrr "$vrr" \
    --argjson hdr "$hdr" \
    --argjson modes "$modes" \
    --argjson current "$current" \
    --arg dres "$(default_setting "$role" res)" \
    --argjson dhz "$(default_setting "$role" hz)" \
    --argjson dvrr "$([[ "$(default_setting "$role" vrr)" == 1 ]] && echo true || echo false)" \
    --argjson dhdr "$([[ "$(default_setting "$role" hdr)" == 1 ]] && echo true || echo false)" \
    --argjson dscale "$(default_setting "$role" scale)" \
    '{
      role: $role,
      device: $device,
      connector: (if $conn == "" then null else $conn end),
      transport: (if $transport == "" then null else $transport end),
      power: (if $power == "" then null else $power end),
      connected: ($conn != ""),
      enabled: ($enabled == 1),
      vrr_capable: $vrr,
      hdr_capable: $hdr,
      modes: $modes,
      defaults: {res: $dres, hz: $dhz, vrr: $dvrr, hdr: $dhdr, scale: $dscale},
      current: $current
    }'
}

caps_flow() { # both displays, monitor first
  local mon tv
  mon=$(display_caps_json monitor)
  tv=$(display_caps_json tv)
  jq -nc --arg active "$(compute_status)" --argjson mon "$mon" --argjson tv "$tv" \
    '{active: $active, displays: [$mon, $tv]}'
}

# --------------------------------------------------------------------- main ---

main() {
  mkdir -p "$STATE_DIR" "$CONFIG_DIR"
  trap cleanup EXIT

  (( $# >= 1 )) || usage
  case "$1" in
    status)
      (( $# == 1 )) || usage
      require_deps
      ensure_ipc_sig
      fetch_monitors || die 3 "discovery failed: hyprctl -j monitors all returned no valid JSON"
      discover
      compute_status
      ;;
    caps)
      (( $# == 1 )) || usage
      require_deps
      ensure_ipc_sig
      fetch_monitors || die 3 "discovery failed: hyprctl -j monitors all returned no valid JSON"
      discover
      caps_flow
      ;;
    ensure)
      (( $# == 1 )) || usage
      require_deps
      ensure_ipc_sig
      acquire_lock
      ensure_flow
      ;;
    monitor|tv)
      local cmd="$1"
      shift
      parse_request "$cmd" "$@"
      require_deps
      ensure_ipc_sig
      acquire_lock
      apply_flow "$cmd" explicit
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"

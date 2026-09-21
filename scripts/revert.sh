#!/bin/bash
# revert.sh - roll back the DRM "scaling mode" (scaling-mode-3) patch
#
# Three escalating levels:
#
#   --soft  (default) Disable the early boot unit, re-apply the normal display
#           profile and print the current scaling-mode value. The patched
#           libaquamarine stays installed, so recovery takes ~10s and needs no
#           log out.
#   --full  The --soft steps plus a reinstall of the stock cached aquamarine
#           package, then a log out / log in (the patched library is still
#           mapped into the running compositor).
#   --nuke  The --full steps plus returning the checkout to main. The
#           experiment branch is never deleted automatically: the delete
#           command is printed instead.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

UNIT="drm-scaling-early.service"
BRANCH="experiment/scaling-mode-3"
PKG_CACHE="/var/cache/pacman/pkg"
# 0.15.1 (this stash) is SONAME 14: libaquamarine.so.14. The cached 0.14.0
# package is SONAME 13 (libaquamarine.so.13) and is therefore NOT a valid
# rollback target - Hyprland links libaquamarine.so.14 and would fail to load.
STOCK_PKG="$PKG_CACHE/aquamarine-0.15.1-1.1-x86_64_v3.pkg.tar.zst"
APPLY="$HOME/.local/bin/display-apply.sh"

LEVEL="soft"
ASSUME_YES=0
FAILED=0

# ---------------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------------

log() { echo "[revert] $*"; }

warn() { echo "[revert] WARNING: $*" >&2; }

die() {
    echo "[revert] ERROR: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Usage / arguments
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
usage: revert.sh [--soft|--full|--nuke] [--yes]

  --soft   (default) disable drm-scaling-early.service, re-apply the display
           profile, print the scaling-mode value. Keeps the patched library.
  --full   --soft + reinstall the stock aquamarine package, then log out/in.
  --nuke   --full + return the checkout to main (branch delete command printed,
           never executed).
  --yes    skip the confirmation prompt.

  -h, --help  show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --soft) LEVEL="soft" ;;
        --full) LEVEL="full" ;;
        --nuke) LEVEL="nuke" ;;
        --yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "revert.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

# Confirmation. Without --yes nothing destructive runs until the user agrees;
# a non-interactive stdin (EOF) counts as "no".
confirm() {
    (( ASSUME_YES )) && return 0

    local reply
    printf '%s [y/N] ' "$1"
    read -r reply || true
    case "${reply:-}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# Anti-cheat / display-owning processes: swapping the rendering library or
# changing modes underneath a running game can break it or trip VAC.
warn_if_gaming() {
    local found=()
    pgrep -x steam >/dev/null 2>&1 && found+=("steam")
    pgrep -x cs2 >/dev/null 2>&1 && found+=("cs2")
    pgrep -x cs2_linux >/dev/null 2>&1 && found+=("cs2_linux")
    if [[ ${#found[@]} -gt 0 ]]; then
        warn "these processes are running: ${found[*]}"
        warn "close them before reverting: a mode change or a library swap now may"
        warn "break the game or trigger anti-cheat."
    fi
}

# ---------------------------------------------------------------------------
# Shared steps
# ---------------------------------------------------------------------------

# Print the scaling-mode value the connectors currently report.
print_scaling() {
    log "current connector scaling mode:"
    if command -v modetest >/dev/null 2>&1; then
        modetest -c 2>/dev/null | grep -A 4 "scaling mode" ||
            warn "no connector reports a 'scaling mode' property"
    else
        warn "modetest not found (install libdrm); cannot read the scaling mode"
    fi
}

do_soft() {
    log "step 1: disable $UNIT (stops forcing scaling mode 3 at boot)"
    if ! sudo systemctl disable --now "$UNIT"; then
        warn "could not disable $UNIT; the boot script may still run"
        FAILED=1
    fi

    log "step 2: re-apply the normal display profile"
    if [[ -x "$APPLY" ]]; then
        "$APPLY" monitor || { warn "$APPLY monitor failed"; FAILED=1; }
    else
        warn "$APPLY not found - run ./install.sh first; skipping"
        FAILED=1
    fi

    log "step 3: check the scaling value"
    print_scaling

    log "done: patched library kept, boot unit disabled, no log out needed (~10s)."
}

do_full() {
    do_soft

    [[ -f "$STOCK_PKG" ]] ||
        die "stock package not in the pacman cache: $STOCK_PKG"

    log "step 4: reinstall the stock package: $STOCK_PKG"
    if ! sudo pacman -U "$STOCK_PKG"; then
        die "pacman -U failed; the patched library is still installed"
    fi

    log "done: log out and back in now - the running compositor still has the"
    log "patched libaquamarine mapped."
}

do_nuke() {
    do_full

    log "step 5: return the checkout to main (branch $BRANCH kept)"
    if ! git -C "$REPO_DIR" checkout main; then
        die "'git checkout main' failed; the branch was left untouched"
    fi

    log "the branch was NOT deleted. To delete it yourself, run:"
    echo "    git -C $REPO_DIR branch -D $BRANCH"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "$LEVEL" in
    soft) log "level: --soft (boot unit off + display profile re-applied)" ;;
    full) log "level: --full (--soft plus stock aquamarine package)" ;;
    nuke) log "level: --nuke (--full plus 'git checkout main')" ;;
esac

warn_if_gaming

# --nuke rewrites the checkout, so a dirty worktree is refused before anything
# destructive runs (--yes bypasses the check).
if [[ "$LEVEL" == "nuke" ]] && (( ! ASSUME_YES )) &&
    [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
    die "worktree is dirty; commit or stash your work first, or re-run with --yes"
fi

confirm "Proceed with the $LEVEL revert?" || {
    log "aborted: nothing was changed"
    exit 1
}

case "$LEVEL" in
    soft) do_soft ;;
    full) do_full ;;
    nuke) do_nuke ;;
esac

if (( FAILED )); then
    log "finished with warnings (see above)"
    exit 1
fi

log "revert complete."

#!/bin/bash
# lua-monitor-lib.sh — sourced by display_apply.sh when USE_LUA=1
# Generates hl.monitor() Lua blocks from the same field definitions
# used by hyprlang monitorv2 {}. Field names are identical — only
# value quoting differs (string fields need quotes in Lua).
#
# Provides: lua_monitor_active <name> <mode> <pos> <scale> <field...>
#           lua_monitor_disabled <name>

# Emit a Lua hl.monitor() block for an active output.
# Fields are passed as "key = value" pairs (bash word-split args).
# String-value fields (cm, sdr_eotf, mirror) are auto-quoted.
lua_monitor_active() {
    local name="$1" mode="$2" pos="$3" scale="$4"
    shift 4
    local fields_a=()
    while [[ $# -gt 0 ]]; do
        local f="$1"
        case "$f" in
            cm\ =*|sdr_eotf\ =*|mirror\ =*)
                local key="${f%% = *}"
                local val="${f#* = }"
                f="${key} = \"${val}\""
                ;;
        esac
        fields_a+=("${f}")
        shift
    done
    cat <<EOF
hl.monitor({
    output = "${name}",
    mode = "${mode}",
    position = "${pos}",
    scale = ${scale},
EOF
    local last=$(( ${#fields_a[@]} - 1 ))
    for i in "${!fields_a[@]}"; do
        if [[ $i -eq $last ]]; then
            printf '    %s\n' "${fields_a[$i]}"
        else
            printf '    %s,\n' "${fields_a[$i]}"
        fi
    done
    echo "})"
}

# Emit a Lua hl.monitor() block for a disabled output.
lua_monitor_disabled() {
    cat <<EOF
hl.monitor({
    output = "${1}",
    disabled = true,
})
EOF
}

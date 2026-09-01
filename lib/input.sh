#!/usr/bin/env bash
# input.sh - controller isolation between the desktop and the gaming session.
#
# What actually leaks a controller onto a Wayland desktop is not the joystick
# axes (Hyprland/libinput ignore those) but the *extra* endpoints some pads
# expose: DS4/DS5 present a touchpad as a libinput pointer, the Steam Controller
# and some 8BitDo modes present a keyboard/mouse.  Those move the desktop cursor
# or type while you play.
#
# Strategy:
#   * install.sh drops a udev rule tagging known pads (ID + uaccess).
#   * input_isolate(): disable every controller-owned pointer/keyboard endpoint on
#     the *desktop* Hyprland instance (hyprctl device[...]:enabled false), and
#     remember what we touched.
#   * input_release(): re-enable them.
#   * The joystick axes themselves are picked up inside the session by
#     Steam Input / SDL, which EVIOCGRABs them -> exclusive to the game.

# Substrings (case-insensitive) that mark a libinput device as controller-owned.
_INPUT_PAD_PAT='wireless controller|dualshock|dualsense|x-?box|xinput|steam controller|8bitdo|pro controller|joy-?con|gamepad|nintendo|horipad|stadia'

# hyprctl for the *desktop* session (auto-detected via its instance signature).
_dsk_hyprctl() {
    local sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
    if [[ -z "$sig" ]]; then
        sig=$(ls -t "$XDG_RUNTIME_DIR"/hypr/ 2>/dev/null | head -1)
    fi
    [[ -n "$sig" ]] || return 1
    HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl "$@"
}

input_isolate() {
    have hyprctl || { info "no Hyprland on the desktop side; nothing to isolate"; return 0; }
    _dsk_hyprctl version >/dev/null 2>&1 || { warn "cannot reach desktop Hyprland IPC; skipping input isolation"; return 0; }

    local names touched=()
    names=$(_dsk_hyprctl -j devices 2>/dev/null | jq -r '
        (.mice[]?, .keyboards[]?) | .name' 2>/dev/null)

    local n
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        if printf '%s' "$n" | grep -qiE "$_INPUT_PAD_PAT"; then
            if _dsk_hyprctl keyword "device[$n]:enabled" false >/dev/null 2>&1; then
                touched+=("$n")
                info "desktop input endpoint disabled: $n"
            fi
        fi
    done <<<"$names"

    if ((${#touched[@]})); then
        printf '%s\n' "${touched[@]}" >"$GL_RUN_DIR/disabled-inputs.txt"
        ok "isolated ${#touched[@]} controller endpoint(s) from the desktop"
    else
        info "no controller pointer/keyboard endpoints active on the desktop"
    fi

    # Informational: joystick nodes that the in-session game will pick up.
    local js
    js=$(grep -lE 'Handlers=.*js[0-9]' /proc/bus/input/devices 2>/dev/null || true)
    [[ -n "$(ls /dev/input/js* 2>/dev/null)" ]] && \
        info "joystick nodes present ($(ls /dev/input/js* | tr '\n' ' ')) - Steam Input will grab these in-session"
}

input_release() {
    local f="$GL_RUN_DIR/disabled-inputs.txt"
    [[ -f "$f" ]] || return 0
    have hyprctl || { rm -f "$f"; return 0; }
    local n
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        _dsk_hyprctl keyword "device[$n]:enabled" true >/dev/null 2>&1 \
            && info "desktop input endpoint re-enabled: $n"
    done <"$f"
    rm -f "$f"
    ok "controller endpoints returned to the desktop"
}

# Quick report for `status` / `troubleshoot`.
input_status() {
    echo "Controllers seen by the kernel:"
    local found
    found=$(awk -v RS='' -v pat="$_INPUT_PAD_PAT" '
        tolower($0) ~ pat {
            match($0, /Name="[^"]*"/); nm=substr($0,RSTART+6,RLENGTH-7)
            match($0, /Handlers=[^\n]*/); hd=substr($0,RSTART+9,RLENGTH-9)
            printf "  - %-32s [%s]\n", nm, hd
        }' /proc/bus/input/devices 2>/dev/null)
    [[ -n "$found" ]] && echo "$found" || echo "  (none attached)"
    if [[ -f "$GL_RUN_DIR/disabled-inputs.txt" ]]; then
        echo "Currently isolated from desktop:"
        sed 's/^/  - /' "$GL_RUN_DIR/disabled-inputs.txt"
    fi
}

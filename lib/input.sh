#!/usr/bin/env bash
# input.sh - keep the streaming client's mouse / keyboard / touch inside the
# gaming session instead of on the physical desktop.
#
# The problem
# -----------
# Sunshine (inputtino) injects the client's pointer/keyboard/touch through
# GLOBAL uinput devices ("Mouse passthrough", "Mouse passthrough (absolute)",
# "Keyboard passthrough", ...).  The nested headless Sway has no libinput
# backend, so it never sees them - the *physical* Hyprland desktop picks them
# up and the client ends up driving the wrong screen.
#
# The fix (two halves, both toggled here)
# ---------------------------------------
#   1. Desktop side: a managed `hl.device{ enabled = false }` Lua rule
#      (GL_INPUT_LUA) makes the desktop Hyprland ignore the passthrough devices.
#   2. Session side: `sunshine-input-bridge` (compiled from src/) reads those
#      same evdev nodes and replays them into the nested Sway via the
#      zwlr_virtual_pointer_v1 / zwp_virtual_keyboard_v1 protocols.
#
# The gamepad is untouched: Steam Input EVIOCGRABs the js node directly, so it
# already reaches only the in-session game.

# Substrings (case-insensitive) that mark a libinput device as controller-owned.
_INPUT_PAD_PAT='wireless controller|dualshock|dualsense|x-?box|xinput|steam controller|8bitdo|pro controller|joy-?con|gamepad|nintendo|horipad|stadia'

# evdev device names inputtino creates, and the matching Hyprland device names
# (lower-cased, spaces -> dashes; duplicate names get -1/-2 suffixes).
_PASSTHRU_NAME_RE='^(Mouse|Keyboard|Touch|Pen) passthrough'
_GL_HYPR_INPUT_NAMES=(
  mouse-passthrough mouse-passthrough-1 mouse-passthrough-2
  "mouse-passthrough-(absolute)" "mouse-passthrough-(absolute)-1" "mouse-passthrough-(absolute)-2"
  keyboard-passthrough keyboard-passthrough-1 keyboard-passthrough-2
  touch-passthrough touch-passthrough-1 touch-passthrough-2
  pen-passthrough pen-passthrough-1
)

# hyprctl for the *desktop* session (auto-detected via its instance signature).
_dsk_hyprctl() {
    local sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
    if [[ -z "$sig" ]]; then
        sig=$(ls -t "$XDG_RUNTIME_DIR"/hypr/ 2>/dev/null | head -1)
    fi
    [[ -n "$sig" ]] || return 1
    HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl "$@"
}

# ------------------------------------------------------------ desktop ignore
# _gaming_hypr_input_ignore on|off  - rewrite GL_INPUT_LUA's managed block and
# reload the desktop Hyprland.
_gaming_hypr_input_ignore() {
    local mode=$1 en n list body
    have hyprctl || return 0
    [[ -f "$GL_INPUT_LUA" ]] || printf -- '-- BEGIN gaming-launcher input\n-- END gaming-launcher input\n' >"$GL_INPUT_LUA"
    [[ "$mode" == on ]] && en=false || en=true
    list=""
    for n in "${_GL_HYPR_INPUT_NAMES[@]}"; do list+="\"$n\", "; done
    body="-- BEGIN gaming-launcher input"$'\n'
    body+="for _, n in ipairs({ ${list%, } }) do pcall(hl.device, { name = n, enabled = $en }) end"$'\n'
    body+="-- END gaming-launcher input"
    awk -v repl="$body" '
        /-- BEGIN gaming-launcher input/ {print repl; skip=1; next}
        /-- END gaming-launcher input/   {skip=0; next}
        !skip
    ' "$GL_INPUT_LUA" >"$GL_INPUT_LUA.tmp" && mv "$GL_INPUT_LUA.tmp" "$GL_INPUT_LUA"
    _dsk_hyprctl reload >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ bridge
# evdev nodes of the gaming Sunshine's passthrough devices. The second-screen
# instance is suspended before this runs, so only the gaming set is present.
_input_passthrough_nodes() {
    local d name
    for d in /sys/class/input/event*; do
        [[ -r "$d/device/name" ]] || continue
        name=$(<"$d/device/name")
        [[ "$name" =~ $_PASSTHRU_NAME_RE ]] || continue
        printf '/dev/input/%s\n' "${d##*/}"
    done
}

_bridge_pidfile() { printf '%s' "$GL_RUN_DIR/input-bridge.pid"; }

_bridge_stop() {
    local pf p; pf=$(_bridge_pidfile)
    [[ -f "$pf" ]] || return 0
    p=$(<"$pf"); rm -f "$pf"
    [[ "$p" =~ ^[0-9]+$ ]] || return 0
    kill -TERM "$p" 2>/dev/null || true
    wait_for 20 bash -c "! kill -0 $p 2>/dev/null" || kill -KILL "$p" 2>/dev/null || true
    info "input bridge stopped"
}

_bridge_start() {
    local bin; bin=$(INPUT_BRIDGE_BIN)
    if [[ ! -x "$bin" ]]; then
        warn "input bridge not built ($bin) - run: make -C \"$GL_ROOT/src\""
        warn "until then the client's mouse/keyboard will move the DESKTOP, not the game"
        return 1
    fi
    _bridge_stop

    local -a nodes=(); local n
    while IFS= read -r n; do [[ -n "$n" ]] && nodes+=("$n"); done < <(_input_passthrough_nodes)
    if ((${#nodes[@]} == 0)); then
        warn "no 'Mouse/Keyboard passthrough' devices yet - is the gaming Sunshine running?"
        return 1
    fi

    local wl layout
    wl=$(session_wl_display 2>/dev/null); [[ -n "$wl" ]] || wl="${WAYLAND_DISPLAY:-}"
    layout=$(gl_cfg general kb_layout "")
    [[ -n "$layout" ]] || layout=$(_dsk_hyprctl getoption input:kb_layout -j 2>/dev/null | jq -r '.str // empty' 2>/dev/null)
    layout=${layout%%,*}   # first layout only

    local log="$GL_STATE_DIR/input-bridge.log"; : >"$log"
    setsid "$bin" ${wl:+--display "$wl"} ${layout:+--layout "$layout"} "${nodes[@]}" >>"$log" 2>&1 &
    local bp=$!
    echo "$bp" >"$(_bridge_pidfile)"
    disown 2>/dev/null || true

    if wait_for 15 bash -c "kill -0 $bp 2>/dev/null"; then
        ok "input bridge: ${#nodes[@]} device(s) -> gaming session (pid $bp, display ${wl:-?}, layout ${layout:-us})"
        return 0
    fi
    warn "input bridge exited immediately - see $log"
    return 1
}

# ------------------------------------------------------------------ hooks
input_isolate() {
    _gaming_hypr_input_ignore on
    _bridge_start || warn "falling back: client input on the desktop for this session"
}

input_release() {
    _bridge_stop
    _gaming_hypr_input_ignore off
    rm -f "$GL_RUN_DIR/disabled-inputs.txt"
}

# Quick report for `status` / `troubleshoot`.
input_status() {
    local pf; pf=$(_bridge_pidfile)
    if [[ -f "$pf" ]] && kill -0 "$(<"$pf")" 2>/dev/null; then
        echo "Input bridge : running (pid $(<"$pf")) - client mouse/kbd -> gaming session"
        _input_passthrough_nodes | sed 's|^|  fwd |'
    else
        echo "Input bridge : idle"
    fi
    local found
    found=$(awk -v RS='' -v pat="$_INPUT_PAD_PAT" '
        tolower($0) ~ pat {
            match($0, /Name="[^"]*"/); nm=substr($0,RSTART+6,RLENGTH-7)
            match($0, /Handlers=[^\n]*/); hd=substr($0,RSTART+9,RLENGTH-9)
            printf "  - %-30s [%s]\n", nm, hd
        }' /proc/bus/input/devices 2>/dev/null)
    [[ -n "$found" ]] && { echo "Controllers seen by the kernel (grabbed in-session by Steam Input):"; echo "$found"; }
}

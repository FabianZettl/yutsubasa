#!/usr/bin/env bash
# session.sh - lifecycle of the isolated headless Sway session that Sunshine
# captures.  Sourced by gaming-launcher.

# The Sway session runs:
#   * headless wlroots backend  -> single output HEADLESS-1
#   * no physical input devices  (input isolation, see sway/config)
# Sunshine is then started by the launcher *with this session's environment*
# (WAYLAND_DISPLAY=wayland-gaming) and captures HEADLESS-1 via wlr-screencopy.
#
# Everything lives on its own $WAYLAND_DISPLAY so the desktop Hyprland session is
# never touched.

session_env() {
    # Printed as `k=v` lines; consumed via `env` below.
    cat <<ENV
XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
XDG_STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
HOME=$HOME
USER=${USER:-$(id -un)}
PATH=${PATH}:/usr/local/bin:/usr/bin:/bin
WAYLAND_DISPLAY=$GL_WAYLAND_DISPLAY
WLR_BACKENDS=headless
WLR_RENDERER=$(gl_cfg general wlr_renderer vulkan)
LIBSEAT_BACKEND=noop
SWAYSOCK=$GL_SWAY_SOCK
GL_ROOT=$GL_ROOT
GL_SWAY_SOCK=$GL_SWAY_SOCK
GL_PROFILE=$(state_get .profile)
PULSE_SINK=$(gl_cfg audio sink_name sink-sunshine)
_GL_SESSION=1
ENV
}

# The real Wayland socket sway bound (wlroots auto-picks wayland-N).
session_wl_display() {
    local f="$GL_RUN_DIR/wl-display" d=""
    [[ -r "$f" ]] && d=$(<"$f")
    if [[ -z "$d" ]]; then
        d=$(grep -oE "wayland display '[^']+'" "$GL_SESSION_LOG" 2>/dev/null | head -1 | sed "s/.*'\(.*\)'/\1/")
    fi
    printf '%s' "${d:-$GL_WAYLAND_DISPLAY}"
}

session_up() {
    if session_active; then
        info "gaming session already running (sway pid $(state_get .sway_pid))"
        return 0
    fi

    need sway; need swaymsg; need jq

    info "starting isolated Sway session on \$WAYLAND_DISPLAY=$GL_WAYLAND_DISPLAY"
    audio_ensure_sink || warn "audio sink setup reported problems (continuing)"

    : >"$GL_SESSION_LOG"
    rm -f "$GL_SWAY_SOCK"

    # Start Sway with an explicit, minimal environment. SWAYSOCK is honoured by
    # sway to pin its IPC socket path, so no discovery is needed afterwards.
    need dbus-run-session
    local -a envs=()
    local line
    while IFS= read -r line; do [[ -n "$line" ]] && envs+=("$line"); done < <(session_env)
    local dbg=""; [[ "${GL_DEBUG:-0}" == 1 ]] && dbg="-d"
    env -i "${envs[@]}" dbus-run-session -- \
        sway -c "$GL_SWAY_CONF" $dbg >>"$GL_SESSION_LOG" 2>&1 &
    local swpid=$!
    state_set_raw sway_pid "$swpid"
    state_set wayland_display "$GL_WAYLAND_DISPLAY"

    wait_for 150 test -S "$GL_SWAY_SOCK" || { session_down; die "Sway IPC socket never appeared - see $GL_SESSION_LOG"; }

    if ! wait_for 100 gsway -t get_outputs; then
        session_down; die "Sway session did not come up - see $GL_SESSION_LOG"
    fi

    # Make sure HEADLESS-1 exists (sway creates one headless output by default,
    # but be explicit).
    if ! gsway -t get_outputs | jq -e '.[] | select(.name=="HEADLESS-1")' >/dev/null; then
        gsway create_output >/dev/null || true
    fi
    local w h f
    w=$(state_get .width);  [[ -z "$w" || "$w" == null ]] && w=$(DEFAULT_WIDTH)
    h=$(state_get .height); [[ -z "$h" || "$h" == null ]] && h=$(DEFAULT_HEIGHT)
    f=$(state_get .fps);    [[ -z "$f" || "$f" == null ]] && f=$(DEFAULT_FPS)
    session_set_mode "$w" "$h" "$f"

    ok "Sway session ready (pid $swpid, output HEADLESS-1 @ ${w}x${h}@${f})"

    session_start_sunshine
}

session_start_sunshine() {
    local sbin; sbin=$(SUNSHINE_BIN)
    have "$sbin" || { warn "sunshine not installed; run install.sh"; return 1; }

    if pgrep -af "sunshine .*$GL_SUNSHINE_CONF" >/dev/null; then
        info "our Sunshine instance already running"
        return 0
    fi
    if pgrep -x sunshine >/dev/null && ! pgrep -af "$GL_SUNSHINE_CONF" >/dev/null; then
        warn "another Sunshine/Polaris instance is running - it may clash on ports 47984-48010"
    fi

    wait_for 100 test -r "$GL_RUN_DIR/wl-display" || true
    local wl; wl=$(session_wl_display)
    state_set wl_display "$wl"
    info "launching Sunshine inside the gaming session (WAYLAND_DISPLAY=$wl)"

    # Start Sunshine *as a child of sway* via its IPC, so Sunshine - and every
    # game it launches - inherits the session's full environment (its own D-Bus
    # session bus, DISPLAY for XWayland, XDG_*, the right WAYLAND_DISPLAY). A
    # bare `env -i` launch left Steam without a session bus and it aborted.
    local logf="$GL_STATE_DIR/sunshine.out"
    : >"$logf"
    gsway exec -- "exec env PULSE_SINK='$(gl_cfg audio sink_name sink-sunshine)' _GL_SESSION=1 GL_ROOT='$GL_ROOT' '$sbin' '$GL_SUNSHINE_CONF' >>'$logf' 2>&1"

    if wait_for 100 pgrep -f "sunshine .*$(basename "$GL_SUNSHINE_CONF")"; then
        state_set_raw sunshine_pid "$(pgrep -f "sunshine .*$(basename "$GL_SUNSHINE_CONF")" | head -1)"
        ok "Sunshine started (pid $(state_get .sunshine_pid)). Web UI: https://localhost:$(( $(conf_get "$GL_SUNSHINE_CONF" '' port 47989) + 1 ))"
    else
        warn "Sunshine did not appear - see $logf"
    fi
}

# session_set_mode W H FPS   - resize the headless output (adaptive resolution).
session_set_mode() {
    local w=$1 h=$2 f=$3
    is_int "$w" && is_int "$h" && is_int "$f" || { warn "bad mode ${w}x${h}@${f}; ignoring"; return 1; }
    # Clamp to the active profile's ceiling.
    local cap_w cap_h cap_f
    cap_w=$(quality_field "$(state_get .profile)" max_width  9999)
    cap_h=$(quality_field "$(state_get .profile)" max_height 9999)
    cap_f=$(quality_field "$(state_get .profile)" max_fps    999)
    (( w > cap_w )) && w=$cap_w
    (( h > cap_h )) && h=$cap_h
    (( f > cap_f )) && f=$cap_f
    local try
    for try in 1 2 3 4 5; do
        if gsway output HEADLESS-1 mode --custom "${w}x${h}@${f}Hz" >/dev/null 2>&1 \
           || gsway output HEADLESS-1 mode "${w}x${h}@${f}Hz" >/dev/null 2>&1; then
            state_set width "$w"; state_set height "$h"; state_set fps "$f"
            ok "headless output set to ${w}x${h}@${f}Hz"
            return 0
        fi
        sleep 0.5
    done
    warn "could not set mode ${w}x${h}@${f}Hz on HEADLESS-1 (session still starting?)"
}

session_down() {
    info "tearing down gaming session"
    local sp; sp=$(state_get .sunshine_pid)
    [[ -n "$sp" && "$sp" != null ]] && kill "$sp" 2>/dev/null || true

    if [[ -S "$GL_SWAY_SOCK" ]]; then
        gsway exit >/dev/null 2>&1 || true
    fi
    local swpid; swpid=$(state_get .sway_pid)
    if [[ -n "$swpid" && "$swpid" != null ]]; then
        kill "$swpid" 2>/dev/null || true
        wait_for 50 bash -c "! kill -0 $swpid 2>/dev/null" || kill -9 "$swpid" 2>/dev/null || true
    fi
    # Reap escaped children. Frontends (ES-DE, Steam) detach games/emulators so
    # they reparent to systemd, but they still carry _GL_SESSION=1 in their env.
    local gp
    for gp in $(ls -1 /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        [[ "$gp" == "$$" || "$gp" == "$swpid" ]] && continue
        [[ -O "/proc/$gp" ]] || continue   # our processes only
        grep -qzs '_GL_SESSION=1' "/proc/$gp/environ" 2>/dev/null && kill "$gp" 2>/dev/null || true
    done
    pkill -f "gaming-launcher run " 2>/dev/null || true
    rm -f "$GL_SWAY_SOCK" "$GL_RUN_DIR/disabled-inputs.txt" "$GL_RUN_DIR/wl-display"
    audio_pin_stop || true
    audio_restore_default || true
    input_release || true
    # if the whole session went down (crash or `stop`), bring the second screen
    # back unless `cmd_stop` already cleared the flag on a deliberate teardown.
    command -v _secondscreen_resume >/dev/null && _secondscreen_resume || true
    state_unset sway_pid wl_display wayland_display sunshine_pid width height fps active_app real_default_sink scr_suspended
    [[ "$(state_get .mode)" == gaming ]] && state_unset mode
    ok "session stopped; desktop untouched"
}

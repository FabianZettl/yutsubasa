#!/usr/bin/env bash
# audio.sh - PipeWire audio isolation for the gaming session.
#
# Model:
#   * A persistent null sink `sink-sunshine` is created by a PipeWire config
#     drop-in (installed by install.sh).  It always exists.
#   * The Sway session exports PULSE_SINK=sink-sunshine, so every game routes
#     there by default -> nothing reaches the speakers.
#   * Sunshine captures `sink-sunshine.monitor`.
#   * After Sunshine starts it may grab the system default sink; audio_restore_default
#     puts the real default back so the desktop keeps its sound.
#   * Optional local monitoring: a loopback from the null sink to the real output.

AUDIO_SINK()    { gl_cfg audio sink_name sink-sunshine; }
AUDIO_LOOPBACK_PIDFILE="$GL_RUN_DIR/headset-loopback.pid"
AUDIO_PIN_PIDFILE="$GL_RUN_DIR/audio-pin.pid"

_audio_have_pw() { have wpctl || have pactl; }

# The *node name* of the current default sink (what `pactl set-default-sink` wants).
audio_default_sink() {
    pactl get-default-sink 2>/dev/null
}

# Remember the user's real default sink so we can restore it later.
audio_ensure_sink() {
    _audio_have_pw || { warn "no PipeWire/PulseAudio tools found"; return 1; }
    local sink; sink=$(AUDIO_SINK)

    local cur; cur=$(audio_default_sink)
    if [[ -n "$cur" && "$cur" != "$sink"* ]]; then
        state_set real_default_sink "$cur"
    fi

    if pactl list short sinks 2>/dev/null | grep -q "$sink"; then
        info "null sink '$sink' present"
        return 0
    fi

    warn "null sink '$sink' missing - creating a transient one (install.sh makes it persistent)"
    pactl load-module module-null-sink \
        sink_name="$sink" \
        sink_properties="device.description=Sunshine-Stream" >/dev/null 2>&1 \
        || { err "failed to create null sink"; return 1; }
    ok "created transient null sink '$sink'"
}

# Put the real default sink back (call after Sunshine has started).
audio_restore_default() {
    local real; real=$(state_get .real_default_sink)
    [[ -z "$real" || "$real" == null ]] && return 0
    _audio_have_pw || return 0
    local cur; cur=$(audio_default_sink)
    [[ "$cur" == "$real" ]] && return 0
    if have wpctl; then
        # wpctl wants an id; resolve via pactl name -> pactl set-default-sink works too
        pactl set-default-sink "$real" 2>/dev/null && ok "restored desktop default sink -> $real"
    else
        pactl set-default-sink "$real" 2>/dev/null && ok "restored desktop default sink -> $real"
    fi
}

# --- keep the desktop default sink pinned during a stream -----------------
# Sunshine sets the system default sink to its capture sink on connect, so
# desktop apps that follow "default" (Brave, etc.) migrate into the stream.
# This watcher reverts every such change back to the real sink for as long as
# the stream is up, and does one initial sweep of already-migrated inputs.
# The in-session game is unaffected: it targets the null sink via PULSE_SINK.

# audio_reconcile - enforce ONE routing rule, decided purely by which session a
# stream's owning process runs in. Called on every PipeWire event by the watcher,
# and directly for tests.
#
#   In the nested Sway session  ->  sink-sunshine   (captured by Sunshine)
#   Anything else (the main Hyprland desktop: vscodium, Brave, ...)
#                               ->  the real default device (USB DAC)
#
# "In the session" = the owning PID is in the Sway window-tree PID set (+ all
# descendants) OR carries the inherited env marker (_GL_SESSION=1 / the session's
# WAYLAND_DISPLAY) - covers ES-DE detaching an emulator to systemd and
# unreadable /proc/<pid>/environ. No app-name lists, no "assume streamed"
# fallback: if it can't be shown to be in the session, it's desktop audio.

# PIDs that belong to the isolated gaming session: every window Sway shows +
# all their descendants. Survives ES-DE detaching an emulator to systemd (the
# emulator's window still shows in Sway) and unreadable /proc/<pid>/environ.
_session_pid_set() {
    local sway_root wins
    sway_root=$(state_get .sway_pid)
    [[ "$sway_root" =~ ^[0-9]+$ ]] || return 0
    wins=$(gsway -t get_tree 2>/dev/null | jq -r '[.. | .pid? // empty] | map(select(. > 0)) | unique | .[]' 2>/dev/null)
    # BFS from {sway_root} ∪ {window pids} over a full ppid map
    awk -v seeds="$sway_root $(tr '\n' ' ' <<<"$wins")" '
        { ppid[$1]=$2; kids[$2]=kids[$2] " " $1 }
        END{
            n=split(seeds,q," "); for(i=1;i<=n;i++) if(q[i]!=""){ if(!(q[i] in seen)){seen[q[i]]=1; print q[i]} }
            changed=1
            while(changed){ changed=0
                for(p in seen){ m=split(kids[p],c," "); for(j=1;j<=m;j++) if(c[j]!="" && !(c[j] in seen)){seen[c[j]]=1; print c[j]; changed=1} }
            }
        }' <(ps -eo pid=,ppid= 2>/dev/null)
}

audio_reconcile() {
    have pactl || return 0
    local sink real
    sink=$(AUDIO_SINK)
    real=$(state_get .real_default_sink)
    [[ -z "$real" || "$real" == null || "$real" == "$sink"* ]] && real=$(audio_default_sink)
    [[ -z "$real" || "$real" == "$sink"* ]] && return 0

    # every sink-sunshine* sink id (the captured one + Sunshine's -stereo /
    # -surround siblings, which it does NOT capture)
    local nullids
    nullids=" $(pactl list short sinks 2>/dev/null | awk '$2 ~ /^sink-sunshine/ {print $1}' | tr '\n' ' ') "
    [[ "$nullids" != "  " ]] || return 0
    _is_null() { [[ "$nullids" == *" $1 "* ]]; }

    # id of the ONE sink Sunshine records (sink-sunshine.monitor) - session
    # audio must land here exactly, not on a -stereo/-surround sibling.
    local sink_id
    sink_id=$(pactl list short sinks 2>/dev/null | awk -v n="$sink" '$2==n {print $1; exit}')

    [[ "$(pactl get-default-sink 2>/dev/null)" != "$real" ]] && pactl set-default-sink "$real" 2>/dev/null

    # session PID set (Sway window tree + descendants), computed once per sweep.
    local sessset; sessset=" $(_session_pid_set | tr '\n' ' ') "
    local wl; wl=$(state_get .wl_display); [[ "$wl" == null ]] && wl=""

    # client.id -> pid map, for sink-inputs without application.process.id.
    local cpid=""
    if have pw-dump && have jq; then
        cpid=$(pw-dump 2>/dev/null | jq -r '
            .[] | select(.type=="PipeWire:Interface:Client")
            | "\(.id) \(.info.props["pipewire.sec.pid"] // "")"' 2>/dev/null)
    fi

    # _in_session <pid> : the one test that decides routing.
    _in_session() {
        local p=$1
        [[ "$p" =~ ^[0-9]+$ ]] || return 1
        [[ "$sessset" == *" $p "* ]] && return 0
        grep -qzs '_GL_SESSION=1' "/proc/$p/environ" 2>/dev/null && return 0
        [[ -n "$wl" ]] && grep -qzs "WAYLAND_DISPLAY=$wl" "/proc/$p/environ" 2>/dev/null
    }

    local id si apid cid nm bin pid
    while IFS='|' read -r id si apid cid nm bin; do
        [[ -n "$id" ]] || continue
        pid="$apid"; [[ "$pid" =~ ^[0-9]+$ ]] || pid=$(awk -v c="$cid" '$1==c{print $2; exit}' <<<"$cpid")

        if _in_session "$pid"; then
            # must sit on sink-sunshine itself (the captured monitor), not a sibling
            [[ -n "$sink_id" && "$si" == "$sink_id" ]] || pactl move-sink-input "$id" "$sink" 2>/dev/null
        else
            _is_null "$si" && pactl move-sink-input "$id" "$real" 2>/dev/null   # -> real device
        fi
    done < <(pactl list sink-inputs 2>/dev/null | awk '
        function flush(){ if(id!="") print id"|"si"|"apid"|"cid"|"nm"|"bin; id="";si="";apid="";cid="";nm="";bin="" }
        /^Sink Input #/               { flush(); id=substr($3,2) }
        /^[[:space:]]*Sink:/          { si=$2 }
        /application\.name = /        { v=$0; sub(/.*= /,"",v); gsub(/"/,"",v); nm=v }
        /application\.process\.id = / { v=$NF; gsub(/"/,"",v); apid=v }
        /application\.process\.binary = / { v=$NF; gsub(/"/,"",v); bin=v }
        /client\.id = /              { v=$NF; gsub(/"/,"",v); cid=v }
        END { flush() }
    ')
    return 0
}

audio_pin_start() {
    have pactl || return 0
    local sink; sink=$(AUDIO_SINK)
    audio_pin_stop  # no duplicates
    audio_reconcile
    # Watcher: re-run the rule on every PipeWire change. setsid -> its own process
    # group/session, so `kill -<pgid>` in audio_pin_stop takes down the whole
    # thing (bash + pactl subscribe) and it survives the prep-cmd exiting.
    setsid bash -c '
        L="$0"
        # slow backstop (killed via the setsid process group by audio_pin_stop)
        ( while sleep 3; do "$L" _audio-reconcile >/dev/null 2>&1; done ) &
        # event-driven, main loop
        pactl subscribe 2>/dev/null | grep --line-buffered -E "sink-input|on server" \
            | while read -r _; do "$L" _audio-reconcile >/dev/null 2>&1; done
    ' "$GL_ROOT/bin/gaming-launcher" </dev/null >/dev/null 2>&1 &
    echo $! >"$AUDIO_PIN_PIDFILE"
    ok "audio routing active: session apps -> $sink (streamed), desktop apps + default -> real device"
}

audio_pin_stop() {
    [[ -f "$AUDIO_PIN_PIDFILE" ]] || return 0
    local p; p=$(<"$AUDIO_PIN_PIDFILE")
    if [[ "$p" =~ ^[0-9]+$ ]]; then
        kill -TERM -- "-$p" 2>/dev/null || true   # whole setsid group (bash + pactl subscribe)
        pkill -P "$p" 2>/dev/null || true
        kill "$p" 2>/dev/null || true
    fi
    rm -f "$AUDIO_PIN_PIDFILE"
}

# --- bridge desktop audio into the null sink (mirror / remote-work) ----------
# So Sunshine (which always records sink-sunshine.monitor) also carries whatever
# is playing on the real speakers. Paired with audio_pin_start, which keeps apps
# on the real sink so this loopback actually sees them.
AUDIO_BRIDGE_PIDFILE="$GL_RUN_DIR/audio-bridge.pid"

audio_bridge_start() {
    have pw-loopback || { warn "pw-loopback not found - no desktop audio in the stream"; return 0; }
    audio_bridge_stop
    local real sink; sink=$(AUDIO_SINK)
    real=$(state_get .real_default_sink); [[ -z "$real" || "$real" == null || "$real" == sink-sunshine* ]] && real=$(audio_default_sink)
    [[ -n "$real" && "$real" != sink-sunshine* ]] || { warn "no real sink to bridge from"; return 0; }
    setsid pw-loopback -P "${real}.monitor" -C "$sink" >/dev/null 2>&1 &
    echo $! >"$AUDIO_BRIDGE_PIDFILE"
    ok "desktop audio bridged into the stream (${real}.monitor -> $sink)"
}
audio_bridge_stop() {
    [[ -f "$AUDIO_BRIDGE_PIDFILE" ]] || return 0
    local p; p=$(<"$AUDIO_BRIDGE_PIDFILE")
    [[ "$p" =~ ^[0-9]+$ ]] && { pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; }
    rm -f "$AUDIO_BRIDGE_PIDFILE"
}

# Local monitoring: hear the streamed game on this machine too.
audio_headset() {
    local action=${1:-status}
    local sink; sink=$(AUDIO_SINK)
    case "$action" in
        on)
            if [[ -f "$AUDIO_LOOPBACK_PIDFILE" ]] && kill -0 "$(cat "$AUDIO_LOOPBACK_PIDFILE")" 2>/dev/null; then
                info "headset loopback already on"; return 0
            fi
            local target; target=$(state_get .real_default_sink); [[ -z "$target" || "$target" == null ]] && target=$(audio_default_sink)
            need pw-loopback
            pw-loopback -P "${sink}.monitor" -C "$target" >/dev/null 2>&1 &
            echo $! >"$AUDIO_LOOPBACK_PIDFILE"
            ok "headset loopback on: ${sink}.monitor -> ${target}"
            ;;
        off)
            [[ -f "$AUDIO_LOOPBACK_PIDFILE" ]] || { info "headset loopback not running"; return 0; }
            kill "$(cat "$AUDIO_LOOPBACK_PIDFILE")" 2>/dev/null || true
            rm -f "$AUDIO_LOOPBACK_PIDFILE"
            ok "headset loopback off"
            ;;
        status|*)
            if [[ -f "$AUDIO_LOOPBACK_PIDFILE" ]] && kill -0 "$(cat "$AUDIO_LOOPBACK_PIDFILE")" 2>/dev/null; then
                echo "headset loopback: ON"
            else
                echo "headset loopback: off"
            fi
            ;;
    esac
}

#!/usr/bin/env bash
# quality.sh - quality profiles + gamescope argument builder.
#
# A "profile" is a section in ~/.config/gaming-setup/profiles.conf, e.g.
#
#   [gaming-high-perf]
#   max_width  = 2560
#   max_height = 1440
#   max_fps    = 120
#   codec      = av1        # av1 | hevc | h264  (preferred; client may downgrade)
#   bitrate    = 50000      # kbps ceiling advertised to the client
#   gamescope  = -F fsr --hdr-enabled
#   audio_isolation = true
#   input_isolation = true
#
# Bitrate/codec are negotiated by Moonlight <-> Sunshine at runtime; the profile
# only sets ceilings and the preferred codec.  Resolution/fps are applied to the
# headless output on connect (session_set_mode) using the client's request,
# clamped to the profile ceiling.

quality_field() {  # quality_field <profile> <key> <default>
    local p=$1 k=$2 d=${3-}
    conf_get "$GL_PROFILES" "$p" "$k" "$d"
}

quality_list() { conf_sections "$GL_PROFILES"; }

quality_exists() { conf_sections "$GL_PROFILES" | grep -qx "$1"; }

# Apply a profile: record it in state and, if a session is live, re-apply mode +
# push codec/bitrate ceilings into the Sunshine config.
# quality_apply <profile> [skip_mode]
#   skip_mode=1 : update codec/state only, do NOT touch the headless output mode
#                 (used from `run`, where session-prep already set the client's
#                  requested resolution and we must not stomp it)
quality_apply() {
    local p=$1 skip_mode=${2:-0}
    quality_exists "$p" || die "unknown profile '$p' (have: $(quality_list | csv))"
    state_set profile "$p"
    info "quality profile -> $p"

    local w h f codec br
    w=$(quality_field "$p" max_width  2560)
    h=$(quality_field "$p" max_height 1440)
    f=$(quality_field "$p" max_fps    120)
    codec=$(quality_field "$p" codec av1)
    br=$(quality_field "$p" bitrate 0)

    # Reflect codec preference into sunshine.conf (takes effect on next stream).
    if [[ -w "$GL_SUNSHINE_CONF" ]]; then
        _sun_set av1_mode  "$([[ $codec == av1  ]] && echo 1 || echo 0)"
        _sun_set hevc_mode "$([[ $codec == h264 ]] && echo 0 || echo 1)"
    fi

    if (( skip_mode )); then
        info "profile '$p' codec applied; leaving resolution as the client requested"
        return 0
    fi

    state_set width "$w"; state_set height "$h"; state_set fps "$f"
    if session_active; then
        session_set_mode "$w" "$h" "$f"
        ok "re-applied on live session"
    else
        ok "will apply on next session start"
    fi
    [[ "$br" != 0 ]] && info "bitrate ceiling for '$p': ${br} kbps (client negotiates within this)"
}

# _sun_set key value  - upsert `key = value` in sunshine.conf
_sun_set() {
    local k=$1 v=$2 f=$GL_SUNSHINE_CONF
    [[ -f "$f" ]] || return 0
    if grep -qE "^[#[:space:]]*${k}[[:space:]]*=" "$f"; then
        sed -i -E "s|^[#[:space:]]*${k}[[:space:]]*=.*|${k} = ${v}|" "$f"
    else
        printf '%s = %s\n' "$k" "$v" >>"$f"
    fi
}

# Build the gamescope command prefix for the active profile.
# Echoes the argv; empty if gamescope is disabled.
quality_gamescope_args() {
    local p; p=$(state_get .profile); [[ -z "$p" || "$p" == null ]] && p=$(DEFAULT_PROFILE)
    [[ "$(gl_cfg general use_gamescope true)" == true ]] || return 0
    have gamescope || { warn "gamescope not installed; launching game without it"; return 0; }

    local w h f extra
    w=$(state_get .width);  [[ -z "$w" || "$w" == null ]] && w=$(quality_field "$p" max_width 2560)
    h=$(state_get .height); [[ -z "$h" || "$h" == null ]] && h=$(quality_field "$p" max_height 1440)
    f=$(state_get .fps);    [[ -z "$f" || "$f" == null ]] && f=$(quality_field "$p" max_fps 120)
    extra=$(quality_field "$p" gamescope "")

    printf 'gamescope -W %s -H %s -r %s -f --backend wayland --expose-wayland %s --' \
        "$w" "$h" "$f" "$extra"
}

# One-rung step for the auto-adapter.  Order: high-perf -> balanced -> remote-work.
quality_step_down() {
    local cur=$1
    case "$cur" in
        gaming-high-perf) echo balanced ;;
        balanced)         echo remote-work ;;
        *)                echo "$cur" ;;
    esac
}
quality_step_up() {
    local cur=$1
    case "$cur" in
        remote-work) echo balanced ;;
        balanced)    echo gaming-high-perf ;;
        *)           echo "$cur" ;;
    esac
}

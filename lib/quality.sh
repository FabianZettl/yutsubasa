#!/usr/bin/env bash
# quality.sh - the quality profile + gamescope argument builder.
#
# There is ONE tuned profile, `gaming` (+ a scratch `custom`), in
# ~/.config/gaming-setup/profiles.conf:
#
#   [gaming]
#   max_width  = 2560       # safety ceiling only - the client's own request is
#   max_height = 1440       #   used as-is below this (no forced downscale)
#   max_fps    = 144
#   codec      = h264       # h264 default: predictable framerate on one VCN,
#                           #   shortest client decode. hevc / av1 in `custom`.
#   bitrate    = 40000      # advisory - the real number is a client setting
#   gamescope  =
#   audio_isolation = true
#   input_isolation = true
#
# Bitrate is negotiated by Moonlight <-> Sunshine; the profile sets the codec and
# a resolution ceiling. Resolution/fps come from the client on connect
# (session_set_mode), clamped to the ceiling.

quality_field() {  # quality_field <profile> <key> <default>
    local p=$1 k=$2 d=${3-}
    conf_get "$GL_PROFILES" "$p" "$k" "$d"
}

quality_list() { conf_sections "$GL_PROFILES"; }

quality_exists() { conf_sections "$GL_PROFILES" | grep -qx "$1"; }

# Echo a profile that actually exists: the argument if valid, else the default
# (with a warning). For non-interactive callers (Sunshine app entries) that must
# not abort on a stale/renamed `--profile`.
quality_resolve() {
    local want=$1 def; def=$(DEFAULT_PROFILE)
    if [[ -n "$want" && "$want" != null ]] && quality_exists "$want"; then
        printf '%s' "$want"
    else
        [[ -n "$want" && "$want" != null && "$want" != "$def" ]] \
            && warn "profile '$want' not found; using '$def'" >&2
        printf '%s' "$def"
    fi
}

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
    # Sunshine: *_mode = 1 means "do NOT advertise this codec"; 0 = advertise.
    if [[ -w "$GL_SUNSHINE_CONF" ]]; then
        _sun_set av1_mode  "$([[ $codec == av1 ]] && echo 0 || echo 1)"
        _sun_set hevc_mode "$([[ $codec == av1 || $codec == hevc ]] && echo 0 || echo 1)"
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

# The auto-adapter is inert now: there is a single tuned profile, so there is no
# rung to step to. These are kept as no-ops so cmd__adapter_loop stays harmless.
quality_step_down() { echo "$1"; }
quality_step_up()   { echo "$1"; }

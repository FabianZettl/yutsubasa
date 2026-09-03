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

# _profile_set <profile> <key> <value>  - upsert a key under [profile] in
# profiles.conf.
_profile_set() {
    [[ -f "$GL_PROFILES" ]] || die "no profiles.conf at $GL_PROFILES"
    ini_upsert "$GL_PROFILES" "$1" "$2" "$3"
}

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

# Build the gamescope wrapper prefix, or nothing.
#
# Wrap when:  `--gamescope` was passed  OR  ([general] use_gamescope = true and
# no `--no-gamescope`). gamescope gives heavy Vulkan / DX12-via-Proton titles a
# real WSI swapchain (fixes the headless-wlroots "Failed to get backend DRM FD"
# black screen), an FPS cap at the client's rate, FSR upscaling and lower-latency
# present. It renders into the nested Sway as a normal client, so the Sunshine
# capture path is unchanged. Verified working nested on wlroots 0.20 + gles2.
#
# $1 (optional): the target command about to be exec'd. For a Steam launch
# (`steam …`) gamescope gets `-e` so it doesn't exit when the fire-and-forget
# `steam steam://rungameid/…` handler returns (without it the game is orphaned
# and comes up black), and the Steam-overlay Vulkan layer is disabled (it fights
# gamescope's WSI hook: "Creating swapchain for non gamescope swapchain …").
#
# Echoes a space-joined argv ending in `--`; empty string when not wrapping.
quality_gamescope_args() {
    local target="${1:-}"
    case "${OPT_GAMESCOPE:-}" in
        0) return 0 ;;
        1) : ;;
        *) [[ "$(gl_cfg general use_gamescope false)" == true ]] || return 0 ;;
    esac
    have gamescope || { warn "gamescope requested but not installed - launching bare"; return 0; }

    local p; p=$(state_get .profile); [[ -z "$p" || "$p" == null ]] && p=$(DEFAULT_PROFILE)
    local W H F
    W=$(state_get .width);  [[ "$W" =~ ^[0-9]+$ ]] || W=$(quality_field "$p" max_width 1920)
    H=$(state_get .height); [[ "$H" =~ ^[0-9]+$ ]] || H=$(quality_field "$p" max_height 1080)
    F=$(state_get .fps);    [[ "$F" =~ ^[0-9]+$ ]] || F=$(quality_field "$p" max_fps 60)

    local -a a=(gamescope -W "$W" -H "$H" -r "$F" -f --backend wayland --expose-wayland)
    [[ "$(gl_cfg gamescope immediate_flips true)" == true ]] && a+=(--immediate-flips)
    [[ "$(gl_cfg gamescope rt true)"             == true ]] && a+=(--rt)
    [[ "$(gl_cfg gamescope grab_cursor false)"   == true ]] && a+=(--force-grab-cursor)

    local steam_pre=""
    if [[ "$target" == steam\ * || "$target" == *steam://* || "$target" == *-gamepadui* ]]; then
        a+=(-e)   # Steam input integration
        # `steam steam://rungameid/N` is fire-and-forget - it exits and gamescope
        # would tear down with it, orphaning the game (black screen). The caller
        # wraps the target in gl-steam-hold, which outlives the game.
        #
        # ENABLE_GAMESCOPE_WSI=0: Proton games render through XWayland; the
        # gamescope WSI layer can't hook X11 surfaces and pops a modal
        # "Creating swapchain for non-Gamescope swapchain - hooking has failed"
        # dialog that blocks the game. Off -> no dialog, gamescope composites the
        # X11 window normally and still hands the game a working Vulkan device
        # (verified: FF7 Rebirth renders at 60fps).
        # These reach the game only when gl-steam-hold starts a FRESH Steam
        # client - cmd_run shuts down a stale session client first.
        steam_pre="env ENABLE_GAMESCOPE_WSI=0 DISABLE_VK_LAYER_VALVE_steam_overlay_1=1 "
    fi

    # FSR: render internally at render_scale x client res, upscale to client res
    local rs; rs=$(gl_cfg gamescope render_scale 1.0)
    if [[ -n "$rs" && "$rs" != "1.0" && "$rs" != "1" ]]; then
        local iw ih
        iw=$(awk -v v="$W" -v s="$rs" 'BEGIN{printf "%d",(v*s)+0.5}')
        ih=$(awk -v v="$H" -v s="$rs" 'BEGIN{printf "%d",(v*s)+0.5}')
        (( iw > 0 && ih > 0 && iw < W )) && a+=(-w "$iw" -h "$ih" -F fsr)
    fi

    local extra; extra=$(gl_cfg gamescope extra ""); [[ -z "$extra" ]] && extra=$(quality_field "$p" gamescope "")
    # shellcheck disable=SC2206
    [[ -n "$extra" ]] && a+=($extra)
    a+=(--)
    printf '%s' "$steam_pre"
    printf '%s ' "${a[@]}"
}


# clients.sh - per-client supersampling.
#
# Sunshine's global_prep_cmd hands us only the requested width/height/fps, never
# the paired device name, so a "client" here is identified by the resolution it
# asks for. ~/.config/gaming-setup/clients.conf, one section per device:
#
#     [Steam Deck]
#     match   = 1280x720, 1280x800      ; globs vs "WxH" and "WxH@FPS"
#     factor  = 1.5                     ; headless renders at <req>*factor,
#                                         Sunshine downscales to <req> (SSAA)
#     enabled = true
#
# factor <= 1  -> no supersampling.

# client_supersample W H F  ->  factor (>= 1); first enabled section that matches
client_supersample() {
    local w=$1 h=$2 f=$3 sect m pat fac ok
    [[ -r "$GL_CLIENTS" ]] || { echo 1; return; }
    while IFS= read -r sect; do
        [[ "$(conf_get "$GL_CLIENTS" "$sect" enabled true)" == false ]] && continue
        m=$(conf_get "$GL_CLIENTS" "$sect" match "")
        [[ -z "$m" ]] && continue
        local oldifs=$IFS IFS=,
        for pat in $m; do
            IFS=$oldifs
            pat=$(printf '%s' "$pat" | tr -d '[:space:]')
            [[ -z "$pat" ]] && { IFS=,; continue; }
            ok=0
            case "${w}x${h}"      in $pat) ok=1 ;; esac
            case "${w}x${h}@${f}" in $pat) ok=1 ;; esac
            if (( ok )); then
                fac=$(conf_get "$GL_CLIENTS" "$sect" factor 1)
                [[ "$fac" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fac=1
                echo "$fac"; return
            fi
            IFS=,
        done
        IFS=$oldifs
    done < <(conf_sections "$GL_CLIENTS")
    echo 1
}

# client_set NAME KEY VALUE  - upsert into clients.conf
client_set() { ini_upsert "$GL_CLIENTS" "$1" "$2" "$3"; }

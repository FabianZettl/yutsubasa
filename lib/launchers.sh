# launchers.sh - resolve non-Steam add-game targets to in-session run commands.
#
# Targets:
#   lutris:<slug>                 -> lutris lutris:rungame/<slug>
#   heroic:<appName>              -> heroic --no-gui heroic://launch/<appName>
#   heroic:<runner>:<appName>     -> ... ?appName=<appName>&runner=<runner>
#                                    runner = legendary (Epic) | gog | nile (Amazon)
#
# The games run inside the nested session like any other app: _GL_SESSION=1 +
# PULSE_SINK are inherited, so audio/input routing and the child reaper work
# unchanged. gamescope stays opt-in.

launcher_is_target() {   # launcher_is_target <target>  -> 0 if we handle it
    case "$1" in lutris:*|heroic:*) return 0 ;; *) return 1 ;; esac
}

# --- listing (best-effort; the status web page does the richer version) --------

lutris_list_games() {    # -> "lutris:<slug>\t<name>"  for installed games
    local db="$HOME/.local/share/lutris/pga.db"
    [[ -r "$db" ]] || return 0
    have sqlite3 || return 0
    sqlite3 -separator $'\t' "$db" \
        "SELECT 'lutris:'||slug, name FROM games WHERE installed=1 AND slug<>'' ORDER BY name;" 2>/dev/null
}

heroic_list_games() {    # -> "heroic:<appName>\t<name>"  for installed games
    have jq || return 0
    local cfg="$HOME/.config/heroic" lib
    [[ -d "$cfg" ]] || cfg="$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic"
    [[ -d "$cfg" ]] || return 0
    # Epic (legendary): installed.json is {appName: {title, ...}}
    lib="$cfg/legendaryConfig/legendary/installed.json"
    [[ -r "$lib" ]] && jq -r 'to_entries[] | "heroic:\(.key)\t\(.value.title // .key)"' "$lib" 2>/dev/null
    # GOG: installed.json is {installed:[{appName,...}]}; titles live in the library cache
    lib="$cfg/gog_store/installed.json"
    if [[ -r "$lib" ]]; then
        local cache="$cfg/store_cache/gog_library.json"
        jq -r --slurpfile c <(jq '[.games // .[] // []] | flatten' "$cache" 2>/dev/null || echo '[]') '
            ($c[0] // []) as $lib
            | .installed[]? as $g
            | ($lib[] | select((.app_name // .appName) == $g.appName) | (.title // .app_name)) as $t
            | "heroic:\($g.appName)\t\($t // $g.appName)"' "$lib" 2>/dev/null
    fi
    # Amazon (nile)
    lib="$cfg/nile_config/nile/installed.json"
    [[ -r "$lib" ]] && jq -r '.[]? | "heroic:\(.id // .appName)\t\(.name // .title // (.id // .appName))"' "$lib" 2>/dev/null
}

launcher_resolve() {     # launcher_resolve <target>  -> launch command on stdout
    local t=$1
    case "$t" in
        lutris:*)
            local slug=${t#lutris:}
            [[ -n "$slug" ]] || return 1
            printf 'lutris lutris:rungame/%s' "$slug"
            ;;
        heroic:*)
            # heroic:<appName>  (a leading heroic:<runner>: prefix is tolerated and
            # dropped - Heroic resolves the runner from its own library). The URI
            # form stays free of spaces / shell metachars so callers can word-split
            # or wrap it in sh -c without the '&' of a query string biting.
            local app=${t#heroic:}
            case "$app" in legendary:*|gog:*|nile:*) app=${app#*:} ;; esac
            [[ -n "$app" ]] || return 1
            printf 'heroic --no-gui heroic://launch/%s' "$app"
            ;;
        *) return 1 ;;
    esac
}

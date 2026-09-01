#!/usr/bin/env bash
# steam.sh - Steam library scan + launch helpers.

STEAM_ROOT() {
    for d in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
        [[ -d "$d/steamapps" ]] && { echo "$d"; return; }
    done
    return 1
}

# Echo "APPID<TAB>Name" for every installed game.
steam_list_games() {
    local root; root=$(STEAM_ROOT) || { warn "Steam library not found"; return 1; }
    local libs=("$root")
    local vdf="$root/steamapps/libraryfolders.vdf"
    if [[ -f "$vdf" ]]; then
        while read -r p; do [[ -d "$p/steamapps" ]] && libs+=("$p"); done \
            < <(grep -oE '"/[^"]+"' "$vdf" | tr -d '"')
    fi
    local acf
    for lib in "${libs[@]}"; do
        for acf in "$lib"/steamapps/appmanifest_*.acf; do
            [[ -e "$acf" ]] || continue
            local id name
            id=$(grep -oE '"appid"[[:space:]]+"[0-9]+"' "$acf" | grep -oE '[0-9]+')
            name=$(sed -nE 's/.*"name"[[:space:]]+"(.*)".*/\1/p' "$acf" | head -1)
            [[ -n "$id" ]] && printf '%s\t%s\n' "$id" "${name:-app $id}"
        done
    done | sort -t$'\t' -k2
}

# Resolve "steam:570", "570", or a fuzzy name to an AppID.
steam_resolve_appid() {
    local q=$1
    q=${q#steam:}
    if is_int "$q"; then echo "$q"; return 0; fi
    local hit
    hit=$(steam_list_games | awk -F'\t' -v q="${q,,}" 'tolower($2) ~ q {print $1; exit}')
    [[ -n "$hit" ]] && { echo "$hit"; return 0; }
    return 1
}

# Command that launches Steam Big Picture (gamepad UI).
# No -steamdeck: that flag assumes a gamescope host and misbehaves under a plain
# compositor.
steam_bigpicture_cmd() {
    echo "steam -gamepadui"
}

# Command that launches a specific AppID (Steam starts if needed).
# mode: bigpicture (default) | direct
steam_app_cmd() {
    local id=$1 mode=${2:-bigpicture}
    if [[ "$mode" == direct ]]; then
        echo "steam steam://rungameid/$id"
    else
        echo "steam -gamepadui steam://rungameid/$id"
    fi
}

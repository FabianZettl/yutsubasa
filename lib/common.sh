#!/usr/bin/env bash
# common.sh - shared helpers for gaming-launcher and its lib/ modules.
# Sourced, never executed directly. Requires bash 4+.

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"

# Root of the installed repo (bin/ and lib/ live side by side). Resolved by the
# caller which exports GL_ROOT; fall back to this file's grandparent.
if [[ -z "${GL_ROOT:-}" ]]; then
    GL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export GL_ROOT

GL_CONFIG_DIR="$XDG_CONFIG_HOME/gaming-setup"
GL_STATE_DIR="$XDG_STATE_HOME/gaming-launcher"
GL_RUN_DIR="$XDG_RUNTIME_DIR/gaming-launcher"

GL_CONF="$GL_CONFIG_DIR/gaming-setup.conf"
GL_PROFILES="$GL_CONFIG_DIR/profiles.conf"
GL_SUNSHINE_DIR="$GL_CONFIG_DIR/sunshine"
GL_SUNSHINE_CONF="$GL_SUNSHINE_DIR/sunshine.conf"
GL_SUNSHINE_APPS="$GL_SUNSHINE_DIR/apps.json"
GL_SWAY_CONF="$GL_CONFIG_DIR/sway/config"

GL_STATE_FILE="$GL_RUN_DIR/state.json"
GL_SWAY_SOCK="$GL_RUN_DIR/sway.sock"
GL_LOG="$GL_STATE_DIR/launcher.log"
GL_SESSION_LOG="$GL_STATE_DIR/session.log"

GL_WAYLAND_DISPLAY="wayland-gaming"

mkdir -p "$GL_STATE_DIR" "$GL_RUN_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_gl_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Colour only on a tty.
if [[ -t 2 ]]; then
    _C_RED=$'\e[31m'; _C_YEL=$'\e[33m'; _C_GRN=$'\e[32m'; _C_CYA=$'\e[36m'; _C_DIM=$'\e[2m'; _C_RST=$'\e[0m'
else
    _C_RED=; _C_YEL=; _C_GRN=; _C_CYA=; _C_DIM=; _C_RST=
fi

log()  { printf '%s %s\n'      "$(_gl_ts)" "$*" >>"$GL_LOG"; printf '%s%s%s\n' "$_C_DIM" "$*" "$_C_RST" >&2; }
info() { printf '%s INFO  %s\n' "$(_gl_ts)" "$*" >>"$GL_LOG"; printf '%s==>%s %s\n' "$_C_CYA" "$_C_RST" "$*" >&2; }
ok()   { printf '%s OK    %s\n' "$(_gl_ts)" "$*" >>"$GL_LOG"; printf '%s  ok%s %s\n' "$_C_GRN" "$_C_RST" "$*" >&2; }
warn() { printf '%s WARN  %s\n' "$(_gl_ts)" "$*" >>"$GL_LOG"; printf '%swarn%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
err()  { printf '%s ERROR %s\n' "$(_gl_ts)" "$*" >>"$GL_LOG"; printf '%s err%s  %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
have()      { command -v "$1" >/dev/null 2>&1; }
# newline-separated stdin -> "a, b, c"
csv()       { paste -sd, - | sed 's/,/, /g'; }

# art_png <src-image> <slug>  -> converts to $GL_SUNSHINE_DIR/artwork/<slug>.png,
# echoes the path (empty on failure). Handles svg / jpg / png / webp.
art_png() {
    local src=$1 slug=$2 dst
    [[ -f "$src" ]] || return 1
    mkdir -p "$GL_SUNSHINE_DIR/artwork" 2>/dev/null
    dst="$GL_SUNSHINE_DIR/artwork/${slug}.png"
    [[ -f "$dst" && "$dst" -nt "$src" ]] && { printf '%s' "$dst"; return 0; }
    case "${src,,}" in
        *.png) cp -f "$src" "$dst" ;;
        *.svg|*.svgz)
            if   have rsvg-convert; then rsvg-convert -w 600 -h 900 --keep-aspect-ratio "$src" -o "$dst" 2>/dev/null
            elif have resvg;        then resvg -w 600 "$src" "$dst" 2>/dev/null
            elif have magick;       then magick -background none -density 200 "$src" -resize 600x900 "$dst" 2>/dev/null
            else return 1; fi ;;
        *)
            if   have magick;  then magick "$src" -resize 600x900 "$dst" 2>/dev/null
            elif have convert; then convert "$src" -resize 600x900 "$dst" 2>/dev/null
            elif have ffmpeg;  then ffmpeg -y -loglevel error -i "$src" -vf scale=600:-1 "$dst" 2>/dev/null
            else return 1; fi ;;
    esac
    [[ -s "$dst" ]] && printf '%s' "$dst" || return 1
}
need()      { have "$1" || die "required command not found: $1"; }
is_int()    { [[ "$1" =~ ^[0-9]+$ ]]; }

# Wait until `cmd` succeeds, up to $1 tenths of a second. Usage: wait_for 100 test -S sock
wait_for() {
    local tries=$1; shift
    while (( tries-- > 0 )); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

# ---------------------------------------------------------------------------
# INI-ish config reader.  `conf_get <file> <section> <key> [default]`
# Sections are [name]; keys are `key = value`; '#' and ';' start comments.
# ---------------------------------------------------------------------------
conf_get() {
    local file=$1 section=$2 key=$3 default=${4-}
    [[ -r "$file" ]] || { printf '%s' "$default"; return; }
    awk -v sect="$section" -v key="$key" -v def="$default" '
        function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
        /^[ \t]*[#;]/ { next }
        /^[ \t]*\[.*\][ \t]*$/ {
            cur=$0; sub(/^[ \t]*\[/,"",cur); sub(/\][ \t]*$/,"",cur); cur=trim(cur); next
        }
        {
            line=$0; sub(/[#;].*$/,"",line)
            if (line !~ /=/) next
            k=line; sub(/=.*$/,"",k); k=trim(k)
            v=line; sub(/^[^=]*=/,"",v); v=trim(v)
            if (cur==sect && k==key) { print v; found=1; exit }
        }
        END { if (!found) print def }
    ' "$file"
}

# List section names in an ini file.
conf_sections() {
    local file=$1
    [[ -r "$file" ]] || return 0
    sed -nE 's/^[[:space:]]*\[(.+)\][[:space:]]*$/\1/p' "$file"
}

# ---------------------------------------------------------------------------
# State file (JSON).  Requires jq.
# ---------------------------------------------------------------------------
state_init() {
    [[ -f "$GL_STATE_FILE" ]] || printf '{}\n' >"$GL_STATE_FILE"
}
state_get() {  # state_get .key  -> value or empty
    state_init
    jq -r --arg d "" "(${1}) // \$d" "$GL_STATE_FILE" 2>/dev/null
}
state_set() {  # state_set key "value"   (string values only)
    state_init
    local tmp; tmp=$(mktemp "$GL_RUN_DIR/state.XXXXXX")
    jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$GL_STATE_FILE" >"$tmp" && mv "$tmp" "$GL_STATE_FILE"
}
state_set_raw() {  # state_set_raw key <json-literal>   e.g. state_set_raw pid 1234
    state_init
    local tmp; tmp=$(mktemp "$GL_RUN_DIR/state.XXXXXX")
    jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$GL_STATE_FILE" >"$tmp" && mv "$tmp" "$GL_STATE_FILE"
}
state_clear() { : >"$GL_STATE_FILE"; printf '{}\n' >"$GL_STATE_FILE"; }
state_unset() {  # state_unset key1 key2 ...   (remove just these; leave the rest)
    state_init
    local tmp; tmp=$(mktemp "$GL_RUN_DIR/state.XXXXXX")
    local filter=""
    local k; for k in "$@"; do filter+="del(.$k) | "; done
    filter+="."
    jq "$filter" "$GL_STATE_FILE" >"$tmp" && mv "$tmp" "$GL_STATE_FILE"
}

session_active() {
    local pid; pid=$(state_get .sway_pid)
    [[ -n "$pid" && "$pid" != "null" ]] && kill -0 "$pid" 2>/dev/null
}

# swaymsg bound to the gaming session's socket.
gsway() { SWAYSOCK="$GL_SWAY_SOCK" swaymsg "$@"; }

# ---------------------------------------------------------------------------
# Defaults (overridable in gaming-setup.conf [general])
# ---------------------------------------------------------------------------
gl_cfg() { conf_get "$GL_CONF" "$@"; }

DEFAULT_PROFILE()   { gl_cfg general default_profile "gaming-high-perf"; }
DEFAULT_WIDTH()     { gl_cfg general width  2560; }
DEFAULT_HEIGHT()    { gl_cfg general height 1440; }
DEFAULT_FPS()       { gl_cfg general fps    120; }
SUNSHINE_BIN()      {
    local b; b=$(gl_cfg general sunshine_bin "")
    [[ -n "$b" ]] || b=$(command -v sunshine || echo sunshine)
    printf '%s' "$b"
}

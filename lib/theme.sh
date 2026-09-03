#!/usr/bin/env bash
# theme.sh - reskin the Sunshine web UI in the yutsubasa style.
#
# Sunshine's web UI is a compiled Vue SPA under /usr/share/sunshine/web/
# (root-owned, pacman-managed). It ships a clean design-token stylesheet at
# assets/css/sunshine.css - we append a managed block that redefines the
# --color-* tokens, and swap the logo PNGs. A pristine copy of each touched
# file is kept as <file>.yts-orig for `theme revert`.
#
# Because it lives in a package dir, a `sunshine` upgrade resets it - the
# pacman hook (config/pacman/) re-runs `theme apply --quiet`, and
# `theme status` / `troubleshoot` flag it if the hook isn't installed.
#
# Both Sunshine instances serve the same assets, so this themes the gaming
# (:47990) *and* the second-screen (:48021) web UIs.

THEME_SRC_DIR="$GL_ROOT/config/web-theme"
SUN_WEB="$(gl_cfg general sunshine_web_dir /usr/share/sunshine/web)"
SUN_CSS="$SUN_WEB/assets/css/sunshine.css"
SUN_LOGO16="$SUN_WEB/images/logo-sunshine-16.png"
SUN_LOGO45="$SUN_WEB/images/logo-sunshine-45.png"

# run a privileged file op directly if we can, else via sudo
_th_root() { [[ "$(id -u)" == 0 || -w "$SUN_CSS" ]]; }
_th()      { if _th_root; then "$@"; else sudo "$@"; fi; }

_th_rasterise() {  # <svg> <px> <out>   (writes to a path WE own; no sudo)
    local svg=$1 px=$2 out=$3
    if   have rsvg-convert; then rsvg-convert -w "$px" -h "$px" "$svg" -o "$out" 2>/dev/null
    elif have resvg;        then resvg -w "$px" -h "$px" "$svg" "$out" 2>/dev/null
    elif have magick;       then magick -background none -density 384 "$svg" -resize "${px}x${px}" "$out" 2>/dev/null
    elif have convert;      then convert -background none -density 384 "$svg" -resize "${px}x${px}" "$out" 2>/dev/null
    fi
}

theme_apply() {
    local quiet=0; [[ "${1:-}" == -q || "${1:-}" == --quiet ]] && quiet=1
    [[ -f "$SUN_CSS" ]] || { warn "Sunshine web assets not at $SUN_WEB - is 'sunshine' installed?"; return 1; }
    [[ -f "$THEME_SRC_DIR/yutsubasa.css" ]] || { err "theme source missing: $THEME_SRC_DIR/yutsubasa.css"; return 1; }
    _th_root || { (( quiet )) || info "writing $SUN_WEB needs sudo"; }

    # 1. CSS - pristine copy once, then (re)append the managed block
    [[ -f "$SUN_CSS.yts-orig" ]] || _th cp "$SUN_CSS" "$SUN_CSS.yts-orig"
    local tmp; tmp=$(mktemp)
    sed '/\/\* BEGIN yutsubasa-theme/,/\/\* END yutsubasa-theme \*\//d' "$SUN_CSS.yts-orig" >"$tmp"
    cat "$THEME_SRC_DIR/yutsubasa.css" >>"$tmp"
    _th cp "$tmp" "$SUN_CSS"; rm -f "$tmp"

    # 2. logo (best effort)
    if [[ -f "$THEME_SRC_DIR/logo.svg" ]] && { have rsvg-convert || have resvg || have magick || have convert; }; then
        local d; d=$(mktemp -d)
        _th_rasterise "$THEME_SRC_DIR/logo.svg" 16 "$d/16.png"
        _th_rasterise "$THEME_SRC_DIR/logo.svg" 45 "$d/45.png"
        local p
        for p in "$SUN_LOGO16" "$SUN_LOGO45"; do
            [[ -f "$p" && ! -f "$p.yts-orig" ]] && _th cp "$p" "$p.yts-orig"
        done
        [[ -s "$d/16.png" ]] && _th cp "$d/16.png" "$SUN_LOGO16"
        [[ -s "$d/45.png" ]] && _th cp "$d/45.png" "$SUN_LOGO45"
        rm -rf "$d"
    else
        (( quiet )) || info "no SVG rasteriser (rsvg-convert / magick) - keeping the stock logo"
    fi

    (( quiet )) || ok "yutsubasa theme applied - hard-reload the Sunshine web UI (Ctrl+Shift+R)"
    (( quiet )) || info "revert: gaming-launcher theme revert"
}

theme_revert() {
    local f n=0
    for f in "$SUN_CSS" "$SUN_LOGO16" "$SUN_LOGO45"; do
        [[ -f "$f.yts-orig" ]] || continue
        _th mv "$f.yts-orig" "$f" && n=$((n + 1))
    done
    (( n )) && ok "reverted $n file(s) to stock Sunshine (hard-reload the web UI)" \
            || info "nothing to revert (no .yts-orig backups under $SUN_WEB)"
}

theme_status() {
    if [[ ! -f "$SUN_CSS" ]]; then
        echo "Web UI theme : Sunshine web assets not found ($SUN_WEB)"
        return
    fi
    if grep -q 'BEGIN yutsubasa-theme' "$SUN_CSS" 2>/dev/null; then
        echo "Web UI theme : yutsubasa applied"
    elif [[ -f "$SUN_CSS.yts-orig" ]]; then
        echo "Web UI theme : reverted by a 'sunshine' update - re-apply: gaming-launcher theme apply"
    else
        echo "Web UI theme : stock Sunshine"
    fi
    [[ -e /etc/pacman.d/hooks/zzz-yutsubasa-theme.hook ]] \
        || echo "               (no pacman hook - the theme is lost on the next 'sunshine' upgrade; ./install.sh adds it)"
}

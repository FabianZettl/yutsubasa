#!/usr/bin/env bash
# install.sh - set up the Hyprland virtual-display gaming & streaming stack.
#
#   ./install.sh              install everything (prompts before big changes)
#   ./install.sh --check      report only, change nothing
#   ./install.sh --yes        assume "yes" to prompts (non-interactive)
#   ./install.sh --uninstall  remove what this script installed

set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
CONF="$XDG_CONFIG_HOME/gaming-setup"
SUN="$CONF/sunshine"
STATE="$XDG_STATE_HOME/gaming-launcher"
UNIT_DIR="$XDG_CONFIG_HOME/systemd/user"
BIN_LINK="/usr/local/bin/gaming-launcher"
UDEV_RULE="/etc/udev/rules.d/71-gaming-controllers.rules"

CHECK=0 ASSUME_YES=0 UNINSTALL=0
for a in "$@"; do case "$a" in
    --check) CHECK=1;;
    --yes|-y) ASSUME_YES=1;; --uninstall) UNINSTALL=1;;
    -h|--help) sed -n '2,11p' "$0"; exit 0;;
    *) echo "unknown flag: $a"; exit 1;;
esac; done

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_d=$'\e[2m'; c_0=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$c_c" "$c_0" "$*"; }
good() { printf '  %sok%s  %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%swarn%s %s\n' "$c_y" "$c_0" "$*"; }
bad()  { printf '%s err%s %s\n' "$c_r" "$c_0" "$*"; }
ask()  { (( ASSUME_YES )) && return 0; read -rp "     $1 [y/N] " r; [[ "$r" == [yY]* ]]; }
run()  { (( CHECK )) && { printf '  %s(would)%s %s\n' "$c_d" "$c_0" "$*"; return 0; }; "$@"; }
sudo_run() { (( CHECK )) && { printf '  %s(would sudo)%s %s\n' "$c_d" "$c_0" "$*"; return 0; }; sudo "$@"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
if (( UNINSTALL )); then
    say "uninstalling"
    run systemctl --user disable --now sunshine-gaming.service sunshine-screen.service gaming-quality-adapter.service gaming-null-sink.service 2>/dev/null || true
    run rm -f "$UNIT_DIR/sunshine-gaming.service" "$UNIT_DIR/sunshine-screen.service" "$UNIT_DIR/gaming-quality-adapter.service" "$UNIT_DIR/gaming-null-sink.service"
    run systemctl --user daemon-reload 2>/dev/null || true
    [[ -L /usr/local/bin/gaming-launcher ]] && sudo_run rm -f /usr/local/bin/gaming-launcher
    [[ -L "$HOME/.local/bin/gaming-launcher" ]] && rm -f "$HOME/.local/bin/gaming-launcher"
    for p in /usr/local/bin/sunshine-input-bridge "$HOME/.local/bin/sunshine-input-bridge"; do
        [[ -e "$p" ]] && { [[ -w "$(dirname "$p")" ]] && run rm -f "$p" || sudo_run rm -f "$p"; }
    done
    run make -C "$REPO/src" clean 2>/dev/null || true
    [[ -e "$UDEV_RULE" ]] && { sudo_run rm -f "$UDEV_RULE"; sudo_run udevadm control --reload; }
    [[ -e /etc/pacman.d/hooks/sunshine-setcap.hook ]] && sudo_run rm -f /etc/pacman.d/hooks/sunshine-setcap.hook
    if [[ -f "$XDG_CONFIG_HOME/hypr/hyprland.lua" ]] && grep -qE 'gaming-setup-(display|input)' "$XDG_CONFIG_HOME/hypr/hyprland.lua"; then
        run sed -i -E '/gaming-launcher \(managed\)/d; /gaming-launcher: second-display/d; /gaming-setup-(display|input)\.lua/d' \
            "$XDG_CONFIG_HOME/hypr/hyprland.lua"
        run rm -f "$XDG_CONFIG_HOME/hypr/gaming-setup-display.lua" "$XDG_CONFIG_HOME/hypr/gaming-setup-input.lua"
        warn "removed the gaming-launcher dofile lines from hyprland.lua"
    fi
    run rm -f "$HOME/.config/fish/completions/gaming-launcher.fish" \
              "$HOME/.local/share/bash-completion/completions/gaming-launcher"
    warn "left in place: $CONF and $STATE (delete by hand if you want them gone)"
    good "uninstalled"
    exit 0
fi

# ---------------------------------------------------------------------------
say "1/8  checking the system"
have pacman || { bad "this installer targets Arch/CachyOS (pacman). Adapt the package step for your distro."; exit 1; }
lspci -nn 2>/dev/null | grep -Ei 'VGA|3D|Display' | grep -qiE 'AMD|ATI|Radeon' \
    && good "AMD GPU detected" || warn "no AMD VGA found - VAAPI settings assume AMD"
[[ -e /dev/dri/renderD128 ]] && good "render node /dev/dri/renderD128" || bad "no render node"
[[ -e /dev/uinput ]] && good "/dev/uinput present" || warn "modprobe uinput (virtual gamepad needs it)"
id -nG | grep -qw input && good "user in 'input' group" || warn "run: sudo usermod -aG input $USER  (then re-login)"

# ---------------------------------------------------------------------------
say "2/8  packages"
declare -A PKG=(
  [sway]=sway [swaymsg]=sway [gamescope]=gamescope [jq]=jq
  [sunshine]=sunshine [pipewire]=pipewire [wireplumber]=wireplumber
  [pw-loopback]=pipewire [vainfo]=libva-utils [dbus-run-session]=dbus
  [pactl]=libpulse [swaybg]=swaybg
  [cc]=gcc [wayland-scanner]=wayland [pkg-config]=pkgconf   # input bridge build
)
missing=()
for cmd in "${!PKG[@]}"; do
    have "$cmd" || missing+=("${PKG[$cmd]}")
done
# libraries with no binary to probe for
pacman -Q libva-mesa-driver >/dev/null 2>&1 || missing+=(libva-mesa-driver)
pacman -Q libevdev         >/dev/null 2>&1 || missing+=(libevdev)      # input bridge
pacman -Q libxkbcommon     >/dev/null 2>&1 || missing+=(libxkbcommon)  # input bridge
if ((${#missing[@]})); then
    mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u | sed '/^$/d')
fi

if ((${#missing[@]})); then
    warn "missing: ${missing[*]}"
    if (( CHECK )); then
        printf '  %s(would)%s sudo pacman -S --needed %s\n' "$c_d" "$c_0" "${missing[*]}"
    elif ask "install them with pacman now?"; then
        sudo pacman -S --needed "${missing[@]}" || { bad "pacman failed"; exit 1; }
        good "packages installed"
    else
        warn "skipped - the stack will not fully work until these are present"
    fi
else
    good "all required packages present"
fi

# ---------------------------------------------------------------------------
say "3/8  polaris coexistence check"
if pacman -Q polaris >/dev/null 2>&1; then
    running=0; pgrep -x polaris >/dev/null && running=1
    enabled=0; systemctl --user is-enabled --quiet polaris.service 2>/dev/null && enabled=1
    if (( running || enabled )); then
        warn "polaris is $( ((running)) && echo 'running' || echo 'enabled') and shares the default Sunshine ports (47984-48010)"
        warn "this stack runs its own Sunshine on port 47989 - the two cannot stream at the same time"
        if ask "disable the polaris user service now? (you can still start it by hand)"; then
            run systemctl --user disable --now polaris.service 2>/dev/null || true
            good "polaris.service disabled"
        else
            warn "leaving polaris as-is - remember to stop it before using this stack"
        fi
    else
        good "polaris installed but inactive - fine"
    fi
else
    good "polaris not installed"
fi

# ---------------------------------------------------------------------------
say "4/8  config tree -> $CONF"
run mkdir -p "$CONF" "$SUN/credentials" "$SUN/artwork" "$STATE" "$UNIT_DIR"

install_keep() {   # copy only if absent (don't clobber user edits)
    local src=$1 dst=$2
    if [[ -e "$dst" ]]; then good "kept existing $(basename "$dst")"
    else run cp "$src" "$dst"; good "installed $(basename "$dst")"; fi
}
install_keep "$REPO/config/gaming-setup.conf" "$CONF/gaming-setup.conf"
install_keep "$REPO/config/profiles.conf"     "$CONF/profiles.conf"
run mkdir -p "$CONF/sway"
# sway/config is machine-generated, not meant for user edits - always refresh
# (a changed copy is backed up once).
if [[ -e "$CONF/sway/config" ]] && ! diff -q "$REPO/config/sway/config" "$CONF/sway/config" >/dev/null 2>&1; then
    run cp "$CONF/sway/config" "$CONF/sway/config.bak"
fi
run cp "$REPO/config/sway/config" "$CONF/sway/config"
good "installed sway/config"

# bundled Sunshine box-art -> artwork dir
run mkdir -p "$SUN/artwork"
for p in steam desktop desktop-alt box; do
    [[ -f "/usr/share/sunshine/$p.png" ]] && run cp -n "/usr/share/sunshine/$p.png" "$SUN/artwork/$p.png"
done

render() {         # sed-substitute @tokens@ from .in -> dest (always refreshed)
    local src=$1 dst=$2
    (( CHECK )) && { printf '  %s(would render)%s %s\n' "$c_d" "$c_0" "$dst"; return; }
    sed -e "s|@CONFDIR@|$SUN|g" \
        -e "s|@ARTDIR@|$SUN/artwork|g" \
        -e "s|@STATEDIR@|$STATE|g" \
        -e "s|@LAUNCHER@|$BIN_LINK|g" \
        -e "s|@SINK@|sink-sunshine|g" \
        -e "s|@PATH@|$PATH|g" \
        "$src" >"$dst"
    good "rendered $(basename "$dst")"
}
if [[ -e "$SUN/sunshine.conf" ]]; then
    warn "sunshine.conf exists - refreshing @token@ lines only is not done; keeping yours"
else
    render "$REPO/config/sunshine/sunshine.conf.in" "$SUN/sunshine.conf"
fi
[[ -e "$SUN/apps.json" ]] && good "kept existing apps.json" || render "$REPO/config/sunshine/apps.json.in" "$SUN/apps.json"

# Repair a "Steam Big Picture" entry whose cmd lost its @LAUNCHER@ path (older
# renders produced " run steam" -> Sunshine: "Unable to find executable [run]").
if (( ! CHECK )) && have jq && [[ -e "$SUN/apps.json" ]] \
   && jq -e '.apps[]? | select(.name=="Steam Big Picture") | select((.cmd|test("gaming-launcher"))|not)' "$SUN/apps.json" >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --arg c "$BIN_LINK run steam" \
       '(.apps[] | select(.name=="Steam Big Picture") | .cmd) = $c' \
       "$SUN/apps.json" >"$tmp" && mv "$tmp" "$SUN/apps.json" \
       && warn "repaired broken 'Steam Big Picture' cmd -> $BIN_LINK run steam"
fi

# Strip stale `--profile <name>` from app cmds (the quality ladder is gone; a
# renamed/removed profile there makes `run` abort before it launches the game).
if (( ! CHECK )) && have jq && [[ -e "$SUN/apps.json" ]] \
   && jq -e '.apps[]? | select(.cmd|test(" --profile "))' "$SUN/apps.json" >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq '(.apps[].cmd) |= (gsub(" --profile +[^ ]+"; ""))' "$SUN/apps.json" >"$tmp" \
       && mv "$tmp" "$SUN/apps.json" && warn "stripped stale '--profile …' from app cmds"
fi

# ES-DE as a gaming app (with a rasterised icon), if installed and not already there
if have es-de && [[ -e "$SUN/apps.json" ]] && ! grep -q '"ES-DE"' "$SUN/apps.json"; then
    esde_img=""
    for svg in /usr/share/icons/hicolor/scalable/apps/org.es_de.frontend.svg /usr/share/pixmaps/org.es_de.frontend.svg; do
        [[ -f "$svg" ]] || continue
        if   have rsvg-convert; then rsvg-convert -w 600 -h 900 --keep-aspect-ratio "$svg" -o "$SUN/artwork/es-de.png" 2>/dev/null && esde_img="$SUN/artwork/es-de.png"
        elif have magick;       then magick -background none "$svg" -resize 600x900 "$SUN/artwork/es-de.png" 2>/dev/null && esde_img="$SUN/artwork/es-de.png"; fi
        break
    done
    [[ -z "$esde_img" && -f "$SUN/artwork/box.png" ]] && esde_img="$SUN/artwork/box.png"
    if (( ! CHECK )) && have jq; then
        tmp=$(mktemp)
        jq --arg c "$BIN_LINK run es-de" --arg i "$esde_img" \
           '.apps += [{"name":"ES-DE","cmd":$c,"auto-detach":true,"wait-all":true} + (if $i!="" then {"image-path":$i} else {} end)]' \
           "$SUN/apps.json" >"$tmp" && mv "$tmp" "$SUN/apps.json" && good "added ES-DE app$([[ -n $esde_img ]] && echo ' (with icon)')"
    fi
fi

# desktop Hyprland integration: two managed Lua rules loaded from hyprland.lua
#   gaming-setup-display.lua  - size/disable monitors for `secondscreen`
#   gaming-setup-input.lua    - ignore Sunshine's passthrough input devices
#                               while a gaming stream is connected
HYPR_LUA="$XDG_CONFIG_HOME/hypr/hyprland.lua"
DISPLAY_LUA="$XDG_CONFIG_HOME/hypr/gaming-setup-display.lua"
INPUT_LUA="$XDG_CONFIG_HOME/hypr/gaming-setup-input.lua"

_ensure_dofile() {   # $1 = lua basename ; appends a pcall(dofile,...) line once
    grep -q "$1" "$HYPR_LUA" && { good "hyprland.lua already loads $1"; return 0; }
    if (( CHECK )); then printf '  %s(would)%s add dofile(%s) to hyprland.lua\n' "$c_d" "$c_0" "$1"; return 0; fi
    [[ -f "$HYPR_LUA.pre-gaming-setup.bak" ]] || cp "$HYPR_LUA" "$HYPR_LUA.pre-gaming-setup.bak"
    printf '\n-- gaming-launcher (managed)\npcall(dofile, os.getenv("HOME") .. "/.config/hypr/%s")\n' "$1" >>"$HYPR_LUA"
    good "appended dofile($1) to hyprland.lua"
}

if [[ -f "$HYPR_LUA" ]]; then
    install_keep "$REPO/config/hypr/gaming-setup-display.lua" "$DISPLAY_LUA"
    install_keep "$REPO/config/hypr/gaming-setup-input.lua"   "$INPUT_LUA"
    if grep -q 'gaming-setup-display' "$HYPR_LUA" && grep -q 'gaming-setup-input' "$HYPR_LUA"; then
        good "hyprland.lua already loads both gaming-setup Lua rules"
    elif (( CHECK )); then
        _ensure_dofile "gaming-setup-display.lua"; _ensure_dofile "gaming-setup-input.lua"
    elif ask "add 2 lines to hyprland.lua (size the 2nd monitor + isolate client input during a stream)?"; then
        _ensure_dofile "gaming-setup-display.lua"
        _ensure_dofile "gaming-setup-input.lua"
        good "backup: $(basename "$HYPR_LUA").pre-gaming-setup.bak"
    else
        warn "skipped - add these to hyprland.lua yourself:"
        warn "  pcall(dofile, os.getenv(\"HOME\")..\"/.config/hypr/gaming-setup-display.lua\")"
        warn "  pcall(dofile, os.getenv(\"HOME\")..\"/.config/hypr/gaming-setup-input.lua\")"
        warn "without the input line the streaming client's mouse will move your DESKTOP cursor"
    fi
else
    warn "no ~/.config/hypr/hyprland.lua - skipping desktop Hyprland integration"
fi

# ---------------------------------------------------------------------------
say "5/8  launcher -> $BIN_LINK"
run chmod +x "$REPO/bin/gaming-launcher"
if [[ -L "$BIN_LINK" && "$(readlink -f "$BIN_LINK")" == "$REPO/bin/gaming-launcher" ]]; then
    good "symlink already correct"
elif (( CHECK )); then
    printf '  %s(would)%s ln -sfn launcher -> %s\n' "$c_d" "$c_0" "$BIN_LINK"
elif ln -sfn "$REPO/bin/gaming-launcher" "$BIN_LINK" 2>/dev/null; then
    good "linked $BIN_LINK"
elif sudo -n ln -sfn "$REPO/bin/gaming-launcher" "$BIN_LINK" 2>/dev/null; then
    good "linked $BIN_LINK (sudo)"
elif ask "link into $BIN_LINK needs sudo - do it?"; then
    sudo ln -sfn "$REPO/bin/gaming-launcher" "$BIN_LINK" && good "linked $BIN_LINK"
else
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$REPO/bin/gaming-launcher" "$HOME/.local/bin/gaming-launcher"
    BIN_LINK="$HOME/.local/bin/gaming-launcher"
    warn "fell back to $BIN_LINK - ensure ~/.local/bin is on PATH:"
    warn "  fish:  fish_add_path -U ~/.local/bin"
    warn "  bash:  echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.bashrc"
    # re-render sunshine.conf/apps.json so @LAUNCHER@ points at the fallback path
    render "$REPO/config/sunshine/sunshine.conf.in" "$SUN/sunshine.conf"
    render "$REPO/config/sunshine/apps.json.in" "$SUN/apps.json"
fi

# ---------------------------------------------------------------------------
say "5b/8  input bridge (evdev -> Wayland virtual input)"
BRIDGE_SRC="$REPO/src/sunshine-input-bridge"
if (( CHECK )); then
    printf '  %s(would)%s make -C %s  &&  install to %s\n' "$c_d" "$c_0" "$REPO/src" "$(dirname "$BIN_LINK")"
elif have cc && have wayland-scanner && pkg-config --exists wayland-client libevdev xkbcommon 2>/dev/null; then
    if make -C "$REPO/src" >/dev/null 2>&1 && [[ -x "$BRIDGE_SRC" ]]; then
        BR_DST="$(dirname "$BIN_LINK")/sunshine-input-bridge"
        if cp "$BRIDGE_SRC" "$BR_DST" 2>/dev/null; then good "built + installed sunshine-input-bridge -> $BR_DST"
        elif sudo -n cp "$BRIDGE_SRC" "$BR_DST" 2>/dev/null; then good "built + installed -> $BR_DST (sudo)"
        else
            mkdir -p "$HOME/.local/bin" && cp "$BRIDGE_SRC" "$HOME/.local/bin/" \
                && good "built sunshine-input-bridge -> ~/.local/bin (launcher auto-finds it)"
        fi
    else
        warn "input bridge build failed - run 'make -C $REPO/src' by hand"
        warn "(without it the streaming client's mouse/keyboard moves the DESKTOP, not the game)"
    fi
else
    warn "missing build tools (cc / wayland-scanner / libevdev / xkbcommon) - input bridge NOT built"
    warn "the launcher still runs from $REPO/src if you 'make -C $REPO/src' later"
fi

# ---------------------------------------------------------------------------
say "6/8  systemd user units"
for u in sunshine-gaming.service sunshine-screen.service gaming-quality-adapter.service gaming-null-sink.service; do
    if (( CHECK )); then printf '  %s(would)%s install unit %s\n' "$c_d" "$c_0" "$u"; continue; fi
    sed "s|/usr/local/bin/gaming-launcher|$BIN_LINK|g" "$REPO/systemd/user/$u" >"$UNIT_DIR/$u"
done
run systemctl --user daemon-reload
good "user units installed"

# Persistent null sink (created via pactl, never touches pipewire's own config).
if (( CHECK )); then
    printf '  %s(would)%s systemctl --user enable --now gaming-null-sink.service\n' "$c_d" "$c_0"
elif systemctl --user enable --now gaming-null-sink.service 2>/dev/null; then
    pactl list short sinks 2>/dev/null | grep -q sink-sunshine \
        && good "null sink 'sink-sunshine' active" || warn "null sink not visible yet"
else
    warn "could not enable gaming-null-sink.service - the launcher makes a transient sink instead"
fi

# Autostart both Sunshine instances on login.
if (( CHECK )); then
    printf '  %s(would)%s systemctl --user enable --now sunshine-gaming.service sunshine-screen.service\n' "$c_d" "$c_0"
elif ask "autostart BOTH Sunshine instances on login (gaming :47989 + second screen :48020)?"; then
    systemctl --user enable sunshine-gaming.service sunshine-screen.service 2>/dev/null
    systemctl --user start  sunshine-gaming.service 2>/dev/null && good "gaming instance started (:47989)" \
        || warn "gaming instance not started - check: journalctl --user -u sunshine-gaming"
    systemctl --user start  sunshine-screen.service 2>/dev/null && good "second-screen instance started (:48020)" \
        || warn "second-screen not started (needs the Hyprland desktop) - check: journalctl --user -u sunshine-screen"
    good "both enabled for autostart"
else
    warn "not autostarted - use: gaming-launcher gaming / gaming-launcher secondscreen on"
fi
good "quality-adapter unit installed (opt-in via: gaming-launcher quality --auto on)"

run mkdir -p "$HOME/.config/fish/completions" "$HOME/.local/share/bash-completion/completions"
run cp "$REPO/completions/gaming-launcher.fish" "$HOME/.config/fish/completions/"
run cp "$REPO/completions/gaming-launcher.bash" "$HOME/.local/share/bash-completion/completions/gaming-launcher"
good "shell completions installed (fish + bash)"

# ---------------------------------------------------------------------------
say "7/8  udev controller rules"
if diff -q "$REPO/config/udev/71-gaming-controllers.rules" "$UDEV_RULE" >/dev/null 2>&1; then
    good "udev rule up to date"
else
    if (( CHECK )); then printf '  %s(would sudo)%s cp rule -> %s\n' "$c_d" "$c_0" "$UDEV_RULE"
    elif ask "install $UDEV_RULE (needs sudo)?"; then
        sudo cp "$REPO/config/udev/71-gaming-controllers.rules" "$UDEV_RULE"
        sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=input --action=change
        good "udev rule installed + reloaded"
    else
        warn "skipped udev rule"
    fi
fi

# ---------------------------------------------------------------------------
say "8/8  summary"
(( CHECK )) && { warn "check-only run: nothing was changed"; exit 0; }
cat <<EOF

${c_g}Setup complete.${c_0}

  Start a session          ${c_c}gaming-launcher gaming${c_0}
  Pick a quality profile   ${c_c}gaming-launcher quality balanced${c_0}
  Check state              ${c_c}gaming-launcher status${c_0}
  Stop everything          ${c_c}gaming-launcher stop${c_0}
  Diagnose                 ${c_c}gaming-launcher troubleshoot${c_0}

Then on the client: pair Moonlight/Artemis with this host and launch
"Steam Big Picture". First pairing PIN is entered at  https://localhost:47990

Config:  $CONF
Logs:    $STATE
Docs:    $REPO/README.md , $REPO/docs/
EOF

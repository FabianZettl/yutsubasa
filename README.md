# Hyprland Virtual-Display Gaming & Streaming Stack

Stream a game (or Steam Big Picture) from an **isolated headless session** to
Moonlight / Artemis clients, while your physical Hyprland desktop keeps working
untouched. Controller and game audio are active **only** in the streamed
session.

Built for **CachyOS / Arch + Hyprland + AMD RX 7800 XT** (VCN 4.0: AV1 + HEVC +
H.264 hardware encode).

### What's in this repo

| Path | |
|---|---|
| `install.sh`, `bin/`, `lib/`, `config/`, `systemd/` | the stack — installs `gaming-launcher`, two Sunshine instances (gaming `:47989` + second screen `:48020`), the udev/PipeWire/Hyprland glue |
| `src/` | `sunshine-input-bridge` — tiny C daemon (libevdev + Wayland virtual-pointer/keyboard) that forwards the client's mouse/keyboard/touch into the nested session; built by `install.sh` |
| `docs/` | [architecture](docs/architecture.md), [troubleshooting](docs/troubleshooting.md), the [original brief](docs/original-brief.md) |
| [`steam-sync/`](steam-sync/) | small PyQt6 tool: scan your Steam library → add games (with cover art) to the gaming instance via `gaming-launcher add-game` |

> ⚠️ Tailored to one machine (Hyprland **Lua** config, single-VCN Navi 32, a
> specific monitor layout). Treat it as a worked example, not a turnkey product —
> read `docs/` before running `install.sh`.

---

## How it works

```
Physical monitor ── Hyprland desktop on DP-2         (never touched, 99% of use)

gaming-launcher gaming
   │
   ├─ sway  --backend headless   → output HEADLESS-1   (its own WAYLAND_DISPLAY)
   │     └─ gamescope -W … -H … -r …  --  <game>       (fps cap / FSR / HDR)
   │
   └─ sunshine  (started with the session's env)
         ├─ capture : wlr-screencopy of HEADLESS-1 → VAAPI encode (/dev/dri/renderD128)
         ├─ prep-cmd: resize HEADLESS-1 to the client's requested resolution/fps
         ├─ audio   : PipeWire null sink  sink-sunshine   → game audio never hits speakers
         └─ input   : gamepad → Steam Input (EVIOCGRAB);  mouse/kbd/touch →
                      sunshine-input-bridge → nested Sway (desktop Hyprland
                      ignores the passthrough devices via a managed hl.device rule)
                                    │  LAN
                          Moonlight / Artemis
```

Why not `vkms`? It is a DRM test module with no usable session output. Why not
bare `gamescope`? Upstream Sunshine cannot capture it (not a wlroots
compositor). A headless **Sway** output is the smallest thing Sunshine can
capture, and `swaymsg` lets us change its mode at runtime — that is the
adaptive-resolution mechanism.

---

## Install

```sh
git clone <this repo> ~/Projects/pes/sunshine-virtual
cd ~/Projects/pes/sunshine-virtual
./install.sh
```

`install.sh` will:

- install missing packages via `pacman` (`sway`, `sunshine`, `gamescope`, `jq`,
  `libva-utils`, `libva-mesa-driver`, …) — asks first;
- create an **isolated** config tree in `~/.config/gaming-setup/` (nothing that
  Polaris or a stock Sunshine uses is touched);
- link `gaming-launcher` into `/usr/local/bin` (falls back to `~/.local/bin`);
- install user units + a `gaming-null-sink.service` (created via `pactl`, so it
  can never break your audio stack);
- install the udev controller-tagging rule (asks, needs `sudo`);
- installs a `sunshine-screen` config + a managed Lua rule for `secondscreen` mode.

Flags: `--check` (dry run), `--yes`, `--uninstall`.

If Polaris is installed and running, the installer offers to disable its user
service — the two cannot stream at the same time (shared ports).

### Manual finish (if `sudo` wasn't available during install)

```sh
sudo pacman -S --needed sway sunshine gamescope jq libva-utils libva-mesa-driver dbus \
     gcc pkgconf wayland libevdev libxkbcommon        # build sunshine-input-bridge
make -C src && cp src/sunshine-input-bridge ~/.local/bin/
sudo cp config/udev/71-gaming-controllers.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=input
./install.sh            # re-run to pick up the rest
```

---

## Two always-on instances

`install.sh` offers to **autostart both** Sunshine instances on login:

| Instance | Port | Captures | Purpose |
|---|---|---|---|
| `sunshine-gaming.service` | 47989 | nested headless Sway (`HEADLESS-1`) | isolated gaming, Steam/ES-DE/games |
| `sunshine-screen.service` | 48020 | `GL-SCREEN` / primary (picked by app) | extra monitor · mirror · remote-work |

Both are separate hosts in Moonlight/Artemis and **pair separately** — PINs at
`https://<host>:47990` (gaming) and `https://<host>:48021` (second screen).
Resolution is client-driven on both. Toggle either at runtime with
`systemctl --user start|stop sunshine-{gaming,screen}.service` or the
`gaming-launcher` verbs below.

## Use

```sh
gaming-launcher gaming                 # ensure the isolated session is up (+ profile)
gaming-launcher gaming -p balanced     # …with a quality profile
gaming-launcher status                 # session / encoder / client state
gaming-launcher stop                   # tear BOTH instances down
```

Then on the client:

1. Pair Moonlight / Artemis with this host. First-pairing PIN goes to
   `https://<host>:47990` (open this on the **host**).
2. **Fully quit Steam on the desktop first** (Steam ▸ Exit) — it's
   single-instance and would swallow the in-session launch.
3. Launch **Steam Big Picture** (or a game you added with `add-game`).

The client's chosen resolution / FPS is applied to the headless output on
connect, clamped to the active profile's ceiling. Bitrate and codec are
negotiated by Moonlight ⇄ Sunshine.

### Quality profiles

| Profile            | Output      | Codec | Bitrate ceiling |
|--------------------|-------------|-------|-----------------|
| `gaming-high-perf` | 1440p / 120 | AV1   | 50 Mbps         |
| `balanced`         | 1080p / 60  | HEVC  | 25 Mbps         |
| `remote-work`      | 1080p / 30  | H.264 | 10 Mbps         |
| `custom`           | edit freely | —     | —               |

```sh
gaming-launcher quality balanced       # switch (applies live if a session is up)
gaming-launcher quality --auto on      # opt-in: step down automatically on sustained loss
```

Edit `~/.config/gaming-setup/profiles.conf` to taste.

### Adding games

```sh
gaming-launcher list-games                     # your Steam library + AppIDs
gaming-launcher add-game "Celeste" steam:504230
# cover art is pulled from your Steam library automatically;
# restart the session so Sunshine reloads its app list
```

### Client mouse / keyboard / touch

Sunshine injects client input through **global uinput devices**; a headless
nested compositor can't see them, so by default the *desktop* grabs them. On
client-connect the launcher:

- starts **`sunshine-input-bridge`** (from `src/`) — reads those evdev nodes and
  replays them into the nested Sway via `zwlr_virtual_pointer_v1` /
  `zwp_virtual_keyboard_v1`;
- writes a managed **`hl.device{ enabled = false }`** rule
  (`~/.config/hypr/gaming-setup-input.lua`, loaded from `hyprland.lua`) so the
  desktop Hyprland ignores the passthrough devices for the duration;
- **suspends the second-screen instance** (both instances make identical
  passthrough devices — only one can own the client pointer) and restarts it on
  disconnect.

All three are undone on disconnect. The gamepad path is unchanged — Steam Input
`EVIOCGRAB`s the `js` node directly. Keyboard layout follows the desktop's
`input:kb_layout`; override with `kb_layout` in `gaming-setup.conf [general]`.
Needs `input_isolation = true` in the active quality profile (the default).

### Second screen — one instance, three apps (port 48020)

`sunshine-screen.service` runs one Sunshine in your desktop Hyprland. You pick
the mode **in Moonlight/Artemis by choosing an app**:

| App | What | Resolution |
|---|---|---|
| **Zweitmonitor** | headless `GL-SCREEN` next to your desktop (`[secondscreen] position`) | client-driven |
| **Hauptmonitor spiegeln** | your primary (`DP-2`) as-is, nothing changes | primary's own |
| **Remote Work** | headless `GL-SCREEN` **and your primary turned OFF** | client-driven |

**Audio is off by default** for this whole instance (`stream_audio = disabled`) —
no default-sink hijack, no mic that you monitor to your speakers leaking into the
stream, no `sink-sunshine-stereo`/`-surround*` clutter. Set
`[secondscreen] audio = passthrough` (then restart `sunshine-screen.service`) to
get desktop sound in the mirror/remote apps. The **incoming client microphone**
is a Moonlight/Artemis client setting — turn "Microphone" off for this host in
the client if you don't want it; there is no Sunshine server-side toggle.

Each app carries a `prep-cmd` do/undo (`gaming-launcher secondscreen-app …`) that
creates/removes `GL-SCREEN`, toggles the primary, and starts/stops a
`pw-loopback` audio bridge. `output_name = GL-SCREEN` in the config — when
`GL-SCREEN` exists Sunshine captures it; when it doesn't (mirror), `output_name`
doesn't match and Sunshine falls back to your primary. **Remote Work** disables
`DP-2` — your local screen goes black until you disconnect that app (or
`gaming-launcher secondscreen off`); `gaming-launcher status` shows the warning.

```sh
gaming-launcher secondscreen on|off     # start / stop the instance (also autostarts)
# or:  systemctl --user start|stop sunshine-screen.service
```

One-time: `install.sh` adds a line to `~/.config/hypr/hyprland.lua`
(`pcall(dofile, …/gaming-setup-display.lua)`) so the launcher can size `GL-SCREEN`
/ disable the primary — Hyprland's Lua parser blocks `hyprctl keyword monitor`,
so a managed `hl.monitor{}` rule + `hyprctl reload` is the only way.

If the client's mouse ends up on the wrong monitor (Zweitmonitor mode), see
[docs/troubleshooting.md](docs/troubleshooting.md#second-screen).

### Local monitoring

```sh
gaming-launcher audio headset on       # also hear the streamed game locally
gaming-launcher audio headset off
```

---

## Files

| Path | What |
|------|------|
| `~/.config/gaming-setup/gaming-setup.conf` | top-level defaults |
| `~/.config/gaming-setup/profiles.conf`     | quality profiles |
| `~/.config/gaming-setup/sway/config`       | headless session compositor |
| `~/.config/gaming-setup/sunshine/`         | this instance's Sunshine conf, apps, creds, state |
| `~/.local/state/gaming-launcher/`          | logs (`launcher.log`, `session.log`, `sunshine.log`) |
| `/run/user/$UID/gaming-launcher/state.json`| live session state |
| `~/.config/systemd/user/sunshine-gaming.service` | session unit (started on demand) |

---

## Troubleshooting

```sh
gaming-launcher troubleshoot            # full check
gaming-launcher troubleshoot audio      # or: hardware | input | latency
gaming-launcher logs analyze
```

See [docs/troubleshooting.md](docs/troubleshooting.md) and
[docs/architecture.md](docs/architecture.md).

Common ones:

- **Sway session won't start** → set `wlr_renderer = gles2` in
  `gaming-setup.conf` (`[general]`) and retry.
- **No audio on the client** → `systemctl --user restart gaming-null-sink.service`;
  check `pactl list short sinks | grep sunshine`.
- **Controller still moves the desktop cursor** → that's a pad's touchpad/mouse
  endpoint; `gaming-launcher status` lists what it disabled. Don't run desktop
  Steam at the same time as a session — it grabs `/dev/input/js*` globally.
- **Moonlight can't find the host** → don't run Polaris and this stack together;
  `gaming-launcher status` warns when Polaris is up.

---

## Uninstall

```sh
./install.sh --uninstall     # removes units, symlink, udev rule, hook
# ~/.config/gaming-setup and ~/.local/state/gaming-launcher are left for you
```

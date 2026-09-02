# Yutsubasa

**Stream your games from an isolated headless session to Moonlight / Artemis — your Hyprland desktop keeps working untouched.**

Two always-on [Sunshine](https://github.com/LizardByte/Sunshine) instances on one Linux box:

- **Gaming** — a game or Steam Big Picture runs in a nested, headless Sway
  session. Controller, game audio and the client's mouse/keyboard live *only*
  there; your real desktop never sees them.
- **Second screen** — turn a Moonlight client into an extra monitor, a mirror of
  your main display, or a full remote-work session — chosen by which "app" you
  launch in the client.

Plus `gaming-launcher`, one CLI that runs the whole thing, and a small GUI to
sync your Steam library into it.

> **Read this first.** Yutsubasa was built for one specific machine and is shared
> as a **worked example**, not a turnkey product. It assumes **CachyOS / Arch,
> Hyprland with the Lua config, PipeWire, and an AMD GPU with a single VCN
> encoder** (RX 7700 XT / 7800 XT, Navi 32). On other setups you will need to
> adapt `config/` and the encoder settings — see [Requirements](#requirements)
> and [Known limitations](#known-limitations).

---

## What's in the repo

| Path | |
|---|---|
| `install.sh` | idempotent installer — packages, isolated config tree, systemd user units, udev rule, builds the input bridge |
| `bin/gaming-launcher` | the CLI — session lifecycle, quality, second screen, add-game, status, troubleshoot |
| `lib/` | bash modules (`session` · `audio` · `input` · `quality` · `steam` · `common`) |
| `config/` | templates for the isolated tree — Sway, both Sunshine instances, quality profiles, udev, Hyprland Lua rules |
| `systemd/user/` | `sunshine-gaming` · `sunshine-screen` · `gaming-null-sink` · opt-in quality adapter |
| `src/` | `sunshine-input-bridge` — small C daemon: libevdev → Wayland virtual pointer/keyboard |
| `steam-sync/` | PyQt6 tool: scan the Steam library → `gaming-launcher add-game` with cover art |
| `docs/` | [architecture](docs/architecture.md) · [troubleshooting](docs/troubleshooting.md) · [original design brief](docs/original-brief.md) |

---

## Requirements

**Assumed (hard):**

- Arch-based distro with `pacman` (developed on CachyOS).
- **Hyprland running the Lua config** (`~/.config/hypr/hyprland.lua`). Its parser
  disables `hyprctl keyword` / `hyprctl dispatch`, so the second-screen monitor
  rules and the input-isolation rule are applied as managed `hl.*` Lua blocks +
  `hyprctl reload`. A hyprlang (`.conf`) setup needs those paths rewritten.
- **PipeWire** + WirePlumber.
- **AMD GPU, single VCN 4.0** (Navi 32 — RX 7700 XT / 7800 XT). Encoding is
  `vaapi` on `/dev/dri/renderD128` (AV1 + HEVC + H.264). NVIDIA / Intel or
  dual-VCN Navi 31 need `encoder=` / `adapter_name=` changes in the Sunshine
  configs.
- Your user in the `input` group; `/dev/uinput` present.

**Packages** (the installer offers to fetch them):
`sway sunshine jq libva-utils libva-mesa-driver dbus libpulse swaybg` ·
`gcc pkgconf wayland libevdev libxkbcommon` (for the input bridge) ·
optional `gamescope`.

Use **upstream Sunshine** (LizardByte — `cachyos` repo or AUR), not a
Polaris/Sunshine fork; they collide on the default ports (the installer offers to
disable a running Polaris).

---

## Install

```sh
git clone https://github.com/FabianZettl/yutsubasa.git
cd yutsubasa
./install.sh            # --check dry-run · --yes non-interactive · --uninstall
```

`install.sh` prompts before anything that uses `sudo` or touches your config, and:

- installs missing packages via `pacman`;
- creates an **isolated** tree under `~/.config/gaming-setup/` — nothing a stock
  Sunshine or Polaris uses is touched;
- links `gaming-launcher` into `/usr/local/bin` (falls back to `~/.local/bin`);
- builds `sunshine-input-bridge` from `src/`;
- installs the systemd **user** units + a `gaming-null-sink.service` (the null
  sink is created with `pactl`, never a PipeWire drop-in, so it can't take your
  audio stack down);
- installs the udev controller-tagging rule (`sudo`);
- appends two `pcall(dofile, …)` lines to `hyprland.lua` (asks; backup
  `hyprland.lua.pre-gaming-setup.bak`);
- offers to **autostart both** Sunshine instances on login.

### Manual finish (if `sudo` wasn't available)

```sh
sudo pacman -S --needed sway sunshine jq libva-utils libva-mesa-driver dbus \
     gcc pkgconf wayland libevdev libxkbcommon
make -C src && cp src/sunshine-input-bridge ~/.local/bin/
sudo cp config/udev/71-gaming-controllers.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=input
./install.sh            # re-run for the rest
```

---

## How it works

```
Physical monitor ── Hyprland desktop            (never touched — 99% of the time)
                         │
         gaming-launcher gaming  /  sunshine-gaming.service
                         │
   ┌─────────────────────┴────────────────────────────────────────────┐
   │ dbus-run-session → sway --backend headless  →  output HEADLESS-1  │
   │     └─ game / Steam Big Picture / ES-DE       (own WAYLAND_DISPLAY)│
   │     └─ sunshine  (launched with the session's environment)        │
   │           ├─ capture : wlr-screencopy of HEADLESS-1 → VAAPI       │
   │           ├─ prep-cmd: swaymsg output HEADLESS-1 mode = W×H@FPS    │
   │           ├─ audio   : session streams → null sink `sink-sunshine`│
   │           │            (routed by session membership, not name)   │
   │           └─ input   : gamepad → Steam Input (EVIOCGRAB)          │
   │                        mouse/kbd/touch → sunshine-input-bridge →  │
   │                           zwlr_virtual_pointer / _virtual_keyboard │
   └─────────────────────┬────────────────────────────────────────────┘
                         │  LAN → Moonlight / Artemis
```

- **Why headless Sway** and not `vkms` or bare `gamescope`? `vkms` is a DRM test
  module with no usable session output; upstream Sunshine can't capture bare
  gamescope. A headless Sway output is the smallest thing Sunshine's `wlr`
  capture can grab, and `swaymsg output … mode` resizes it live — that is the
  client-driven resolution mechanism.
- The **second screen** is a *separate* Sunshine on `:48020` running inside your
  **real** Hyprland; its mode is chosen by which Moonlight app you pick.
- Full data-flow + design rationale: [docs/architecture.md](docs/architecture.md).

---

## The two instances

| Service | Port | Web UI / PIN | Captures | Purpose |
|---|---|---|---|---|
| `sunshine-gaming.service` | 47989 | `https://<host>:47990` | nested headless Sway | isolated gaming — Steam, ES-DE, games |
| `sunshine-screen.service` | 48020 | `https://<host>:48021` | desktop `GL-SCREEN` / primary | extra monitor · mirror · remote work |

They advertise as two hosts and **pair separately**. Moonlight sometimes
collapses them because they share a hostname — add the second by IP if only one
shows.

```sh
gaming-launcher gaming                 # bring the gaming session up (+ default profile)
gaming-launcher gaming -p balanced
gaming-launcher status                 # session · encoder · clients · bridge · second screen
gaming-launcher stop                   # tear BOTH down
gaming-launcher secondscreen on|off
# or drive the units directly:
systemctl --user start|stop sunshine-{gaming,screen}.service
```

On the client: pair (PIN at `https://<host>:47990`), **fully quit desktop Steam
first** (single-instance — it would swallow the in-session launch), then launch
**Steam Big Picture** or a game you added.

---

## Quality profiles

| Profile | Output | Codec | Bitrate ceiling |
|---|---|---|---|
| `gaming-high-perf` | 1440p / 120 | AV1 | 50 Mbps |
| `balanced` | 1080p / 60 | HEVC | 25 Mbps |
| `remote-work` | 1080p / 30 | H.264 | 10 Mbps |
| `custom` | free | — | — |

```sh
gaming-launcher quality balanced        # applies live if a session is up
gaming-launcher quality --auto on       # opt-in: step down on sustained loss
```

The client's requested resolution / FPS is applied on connect, clamped to the
profile ceiling; bitrate + codec are negotiated by Moonlight ⇄ Sunshine. Edit
`~/.config/gaming-setup/profiles.conf`.

---

## Adding games

```sh
gaming-launcher list-games
gaming-launcher add-game "Celeste" steam:504230   # cover art pulled from your Steam library
# restart the gaming session so Sunshine reloads its app list
```

Or the GUI — [`steam-sync/`](steam-sync/):

```sh
cd steam-sync && pip install -r requirements.txt && python main.py
```

It scans every installed Steam library folder and drives `add-game` for the
games you tick (with cover art, de-duped).

---

## Second screen — one instance, three apps

Pick the mode in Moonlight / Artemis by choosing an app:

| App | What | Resolution |
|---|---|---|
| **Zweitmonitor** | headless `GL-SCREEN` beside your desktop (`[secondscreen] position`) | client-driven |
| **Hauptmonitor spiegeln** | your primary as-is, nothing changes | primary's own |
| **Remote Work** | headless `GL-SCREEN` **and your primary turned OFF** | client-driven |

Each app's `prep-cmd` creates/removes `GL-SCREEN`, toggles the primary and
starts/stops a `pw-loopback` audio bridge. Audio is **off by default** for this
instance — set `[secondscreen] audio = passthrough` (then restart the service) to
send desktop sound. **Remote Work blanks your local screen** until you disconnect
the app or run `gaming-launcher secondscreen off`; `status` shows the warning.

While a gaming stream is connected the second-screen instance is
**auto-suspended** (both instances create identical virtual input devices — only
one can own the client pointer) and resumed on disconnect.

---

## Input & audio isolation

**Input.** Sunshine injects the client's mouse/keyboard/touch through global
`uinput` devices; a headless compositor can't see them, so the desktop would. On
connect the launcher (a) starts `sunshine-input-bridge`, which replays those
evdev nodes into the nested Sway over `zwlr_virtual_pointer_v1` /
`zwp_virtual_keyboard_v1`, and (b) writes a managed `hl.device{ enabled = false }`
rule so the desktop Hyprland ignores them. Both are undone on disconnect. The
gamepad path is untouched (Steam Input `EVIOCGRAB`s the `js` node). Needs
`input_isolation = true` in the active profile (the default). Keyboard layout
follows the desktop's `input:kb_layout`; override with `kb_layout` in
`gaming-setup.conf [general]`.

**Audio.** A PipeWire null sink `sink-sunshine` (its `.monitor` is what Sunshine
records) always exists. A watcher classifies every stream **by the session its
process runs in** — the Sway window-tree PID set + descendants, or the inherited
`_GL_SESSION=1` env marker — and routes it: in-session → `sink-sunshine`,
everything else → your real default device. No app-name lists. Sunshine's
default-sink hijack is reverted continuously while a client is connected.

---

## Known limitations

- **Heavy native-Vulkan / DX12-via-Proton titles may render black.** Headless
  wlroots has no DRM backend, so `zwp_linux_dmabuf_v1` can't hand GPU clients a
  device (`Failed to get backend DRM FD` in `session.log`). Emulators, Steam Big
  Picture and lighter / OpenGL games are fine; something like *FF7 Rebirth*
  (vkd3d-proton) can come up black. Wrapping such a game in **gamescope** is the
  fix — the plumbing exists (`use_gamescope`, `quality_gamescope_args`) but is
  **off by default** because gamescope nested in a headless Sway was unstable on
  older Mesa. Retest per-game.
- **Hyprland Lua config is assumed.** On a `.conf` (hyprlang) setup the
  `hl.monitor` / `hl.device` managed blocks and the `hyprctl reload` mechanism
  don't apply.
- **AMD single-VCN encoder** is baked into the Sunshine configs.
- **Moonlight host de-dup:** both instances share the hostname; the second may
  need adding by IP.
- **One input owner at a time:** a gaming stream and a second-screen stream
  can't both take client input simultaneously (the auto-suspend covers the
  common case).
- **Cold boot:** `sunshine-screen` can start before Hyprland exports
  `WAYLAND_DISPLAY`. The launcher waits for monitors and resolves it explicitly
  with a bounded restart; if it ever comes up "displayless", run
  `systemctl --user restart sunshine-screen.service`.

---

## Config & logs

| Path | |
|---|---|
| `~/.config/gaming-setup/gaming-setup.conf` | top-level defaults — `[general]` `[audio]` `[secondscreen]` `[adapter]` |
| `~/.config/gaming-setup/profiles.conf` | quality profiles |
| `~/.config/gaming-setup/sway/config` | headless session compositor |
| `~/.config/gaming-setup/sunshine/` | both instances' conf, apps, creds, state |
| `~/.local/state/gaming-launcher/` | `launcher.log` `session.log` `sunshine.log` `sunshine-display.log` `input-bridge.log` |
| `/run/user/$UID/gaming-launcher/state.json` | live state |
| `~/.config/hypr/gaming-setup-{display,input}.lua` | managed Hyprland rules |

---

## Troubleshooting

```sh
gaming-launcher troubleshoot            # hardware · audio · input · latency · polaris
gaming-launcher troubleshoot input
gaming-launcher logs analyze
```

Common ones:

- **Sway session won't start** → set `wlr_renderer = gles2` in
  `gaming-setup.conf [general]`.
- **No client audio** → `systemctl --user restart gaming-null-sink.service`;
  check `pactl list short sinks | grep sunshine`.
- **Client mouse moves the desktop, not the game** → bridge not built or the
  `hl.device` rule not loaded; `gaming-launcher troubleshoot input`, then
  `./install.sh`.
- **"Steam Big Picture" → `Unable to find executable [run]`** → stale
  `apps.json`; re-run `./install.sh` (it repairs the entry).
- **Only one Sunshine host visible** → see *Known limitations* (hostname de-dup /
  cold-boot displayless).
- **Moonlight can't find the host** → don't run Polaris alongside; `status` warns.

More: [docs/troubleshooting.md](docs/troubleshooting.md).

---

## Uninstall

```sh
./install.sh --uninstall     # units, symlinks, bridge binary, udev rule, hyprland.lua lines
# ~/.config/gaming-setup and ~/.local/state/gaming-launcher are left for you
```

---

## Credits & licence

Built on [Sunshine](https://github.com/LizardByte/Sunshine) (LizardByte),
[Sway](https://swaywm.org/) / wlroots, [gamescope](https://github.com/ValveSoftware/gamescope)
and PipeWire. MIT — see [LICENSE](LICENSE).

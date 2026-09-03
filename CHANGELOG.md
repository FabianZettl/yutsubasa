# Changelog

## 0.10.0 (2026-09-03)

- **Status page** (`bin/gl-status-serve`, `yutsubasa-status.service`,
  `http://localhost:47992`). stdlib-Python HTTP server, yutsubasa-themed:
  - live `gaming-launcher status` + `troubleshoot`, auto-refresh;
  - **Steam-library panel** — lists every installed game, an **Add** button per
    game runs `gaming-launcher add-game` (`--direct` / `--gamescope` toggles),
    plus a "reload apps.json" button. Same job as `steam-sync/`, no desktop app.
  - `[status]` config: `port`, `bind` (`loopback` default / `lan` — `lan`
    requires a `token`, embedded in the page), `token`.

## 0.9.3 (2026-09-03)

- **Docs: gamescope is opt-in, not required.** `Failed to get backend DRM FD`
  on headless wlroots looks fatal but isn't - the game falls back and renders.
  FF7 Rebirth plays fine **bare** at 60 fps once warm; the earlier black screen
  was Proton prefix setup + shader precompile on the first run. `--gamescope`
  stays available for the FPS cap / FSR / any title that genuinely stays broken.

## 0.9.2 (2026-09-03)

- **gamescope wrapper now actually renders heavy Proton titles.** Verified: FF7
  Rebirth at 60 fps through `--gamescope`.
  - `ENABLE_GAMESCOPE_WSI=0` for the wrapped launch — Proton games render via
    XWayland, which the gamescope WSI layer can't hook; without this it pops a
    modal "Creating swapchain for non-Gamescope swapchain - hooking has failed"
    dialog that blocks the game. (The earlier `VK_LOADER_LAYERS_*` isolation was
    a red herring - dropped.)
  - `cmd_run` shuts down a stale in-session Steam client before wrapping, so the
    gamescope env reaches the game (it only propagates through a client that
    `gl-steam-hold` starts itself).

## 0.9.1 (2026-09-03)

- **gamescope + Steam games:** `steam steam://rungameid/N` is fire-and-forget, so
  gamescope tore down with the launcher and the game came up black. New
  `bin/gl-steam-hold` becomes gamescope's child - it kicks off the launch and
  blocks until the game exits; gamescope also gets `-e`.
- Vulkan-layer isolation for the wrapped launch: disable all implicit layers,
  keep only `VK_LAYER_FROG_gamescope_wsi` (MESA_anti_lag / steam_overlay / MAKO /
  fossilize sit ahead of it and break its swapchain hook). **Caveat:** this only
  reaches the game when `gl-steam-hold` starts a *fresh* Steam client; if one is
  already running in the session the game inherits its env. Full fix (per-game
  Steam launch options) is next.

## 0.9.0 (2026-09-03)

- **Per-game gamescope wrapper.** `add-game … --gamescope` (or `run … --gamescope`
  / `--no-gamescope`, or `[general] use_gamescope`) wraps the game in gamescope
  inside the session. gamescope gets `-W -H -r` from the connecting client and
  gives the game its own Vulkan WSI swapchain — **fixes the black screen for
  heavy native-Vulkan / DX12-via-Proton titles** on headless wlroots — plus an
  FPS cap at the client's rate, optional FSR (`[gamescope] render_scale`),
  `--immediate-flips` / `--rt` for lower latency. Renders into the nested Sway as
  a normal client, so the capture path is unchanged. Verified nested on
  wlroots 0.20 + gles2 (the old SIGABRT was the Vulkan renderer).
  New `[gamescope]` config section: `immediate_flips` `rt` `grab_cursor`
  `render_scale` `extra`.

## 0.8.1 (2026-09-03)

- **theme: fix the navbar and wordmark.**
  - Sunshine's dark theme keeps a separate `--navbar-bg` / `--navbar-text`
    (a gold bar) - the override now sets those too, so the navbar is dark.
  - the brand element is just an `<img>`; the "yutsubasa" wordmark is now a
    static inline pseudo-element (it was absolutely positioned and overlapped
    the nav links).
  - also swaps the browser-tab `<title>` in the `*.html` pages.
  - `theme apply --quiet` (the pacman-hook path) no longer errors on the flag;
    `theme revert` restores every `*.yts-orig` under the web dir.

## 0.8.0 (2026-09-03)

- **`gaming-launcher theme apply|revert|status`** — reskins the Sunshine web UI
  in the yutsubasa style (dark teal/amber palette + logo). Appends a managed
  block to `assets/css/sunshine.css` and swaps the logo PNGs, keeping
  `.yts-orig` backups. `install.sh` installs a pacman hook that re-applies it
  after a `sunshine` upgrade; `status` / `troubleshoot` flag it if the hook is
  missing. Themes both web UIs (`:47990` + `:48021`). Needs `sudo`
  (`/usr/share/sunshine/web/` is package-owned). Source: `config/web-theme/`.

## 0.7.5 (2026-09-02)

- **Fix: session supervisor spun every 2 s.** After a `systemctl restart` race,
  `state.json`'s `sunshine_pid` could point at a dead PID while a live in-session
  Sunshine ran under a different one. The supervise loop then logged
  "died - restarting" / "already running" every 2 s forever (a periodic
  `pgrep -af` + log write during the stream).
  - `session_start_sunshine` now refreshes `sunshine_pid` on the "already
    running" path.
  - supervise loop re-checks `pgrep` before declaring Sunshine dead, and polls
    every 5 s instead of 2 s.

## 0.7.4 (2026-09-02)

- **Fix: periodic micro-stutter every ~3 s during a stream.** The audio-routing
  watcher's backstop ran `audio_reconcile` every 3 s — a ~90-140 ms sweep
  (`swaymsg get_tree` IPC + full `ps` + BFS + `pw-dump`) that contended with the
  nested compositor rendering the game.
  - backstop interval 3 s → 20 s (the event-driven `pactl subscribe` path still
    reacts instantly to real changes).
  - `_session_pid_set` cached for 10 s (dropped at each stream start).
  - `pw-dump` only runs when a sink-input actually lacks a PID.
  - `pactl subscribe` events are burst-coalesced (one reconcile per flurry).

## 0.7.3 (2026-09-02)

- `fec_percentage` 20 → 30 on both instances — more forward-error-correction
  headroom for lossy Wi-Fi links (helps against packet loss, not jitter).

## 0.7.2 (2026-09-02)

- **Fix: apps wouldn't launch after 0.7.1.** `apps.json` entries carried
  `--profile gaming-high-perf`; with the ladder gone, `run` hit `quality_apply`
  → `die "unknown profile"` and exited before `exec`ing the game (ES-DE, every
  steam-sync title). Steam Big Picture was unaffected (no `--profile`).
  - `run` / `gaming` now resolve an unknown/renamed `--profile` to the default
    with a warning instead of aborting (`quality_resolve`).
  - `add-game` no longer writes `--profile` into app cmds.
  - `install.sh` strips stale `--profile …` from a kept `apps.json`.

## 0.7.1 (2026-09-02)

- **One tuned quality profile.** Collapsed `gaming-high-perf` / `balanced` /
  `remote-work` / `custom` to just **`gaming`** (+ a scratch `custom`). Tuned for
  no frame drops, low input delay and short decode:
  - **H.264 only** on both instances — `av1_mode` / `hevc_mode` set to `1`
    ("do not advertise"). The single VCN 4.0 sustains H.264 without drops, and it
    has the shortest, most consistent hardware decode on phones / handhelds / TVs.
  - resolution/fps taken from the client as-is (ceiling only, no forced
    downscale); VAAPI rate control with no strict HRD buffer.
  - **Fixed the inverted codec mapping** in `quality.sh`: Sunshine's `*_mode = 1`
    means *disable*, not *enable* — the old `codec = av1` profile had been
    switching AV1 *off*.
  - the auto step-down adapter is now inert (`quality --auto` warns and no-ops).

## 0.7.0 — "First Flight" (2026-09-02)

First public release.

### Streaming stack
- Isolated **headless Sway** gaming session captured by upstream Sunshine
  (`wlr` capture, VAAPI AV1 / HEVC / H.264 on AMD Navi 32).
- `gaming-launcher` CLI: session lifecycle, quality profiles, `add-game`,
  `status`, `troubleshoot`, `logs analyze`, shell completions.
- Client-driven resolution/FPS via `swaymsg output HEADLESS-1 mode`, clamped to
  the active profile.
- Two always-on Sunshine instances (gaming `:47989`, second screen `:48020`),
  autostarted via systemd user units; persistent null sink created with `pactl`.
- **Second screen** — one Sunshine on the desktop Hyprland, three Moonlight apps
  (`Zweitmonitor` / `Hauptmonitor spiegeln` / `Remote Work`) driven by per-app
  do/undo prep-cmds and managed `hl.monitor` Lua rules.
- ES-DE registered as a Sunshine app; cover art pulled from the Steam library.

### Input
- **`sunshine-input-bridge`** (new, `src/`) — libevdev → `zwlr_virtual_pointer_v1`
  / `zwp_virtual_keyboard_v1`; forwards the client's mouse/keyboard/touch into
  the nested session. Keyboard layout from the desktop `input:kb_layout`.
- Managed `hl.device{ enabled = false }` rule so the desktop Hyprland ignores
  Sunshine's passthrough `uinput` devices while a stream is connected.
- Second-screen instance auto-suspended for the duration of a gaming stream
  (identical virtual devices — only one owner).
- Gamepad unchanged: Steam Input `EVIOCGRAB`s the `js` node.

### Audio
- Routing decided **strictly by session membership** (Sway window-tree PID set +
  descendants, or the `_GL_SESSION=1` env marker) — in-session → `sink-sunshine`,
  everything else → the real default device. No app-name allowlist.
- Continuous revert of Sunshine's default-sink hijack while a client is
  connected; session audio pinned to the exact captured sink.

### Fixes since the initial bundle
- second-screen suspend was killing the gaming audio watcher (ordering).
- second-screen Sunshine started displayless on cold boot (no `WAYLAND_DISPLAY`)
  — readiness gate + explicit env resolution + bounded restart.
- broken `"Steam Big Picture"` app command (`" run steam"` → missing launcher
  path); `install.sh` now repairs it.

### Tooling
- **steam-sync** — PyQt6 GUI, scans the Steam library and drives
  `gaming-launcher add-game`.

### Known limitations
See the README — the big one: heavy native-Vulkan / DX12-via-Proton titles can
render black on a headless wlroots (`Failed to get backend DRM FD`); gamescope
wrapping is the intended fix and is off by default.

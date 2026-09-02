# Changelog

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

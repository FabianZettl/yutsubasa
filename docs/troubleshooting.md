# Troubleshooting

Start with:

```sh
gaming-launcher troubleshoot            # hardware + audio + input + latency + polaris
gaming-launcher troubleshoot audio      # one area
gaming-launcher logs analyze
gaming-launcher status
```

Logs: `~/.local/state/gaming-launcher/` — `launcher.log`, `session.log`
(Sway stdout/stderr), `sunshine.log`, `sunshine.out`, `quality-adapter.log`.
Session unit: `journalctl --user -u sunshine-gaming -f`.

---

## Hardware / encoding

| Symptom | Cause | Fix |
|---|---|---|
| `troubleshoot` → *VA-API HEVC/AV1 encode FAIL* | Mesa VA-API driver missing | `sudo pacman -S libva-mesa-driver libva-utils`; verify `vainfo | grep Enc` shows `HEVC`/`AV1` |
| Sunshine log: *no encoder found* / falls back to software | wrong render node, or `encoder`/`adapter_name` unset | in `~/.config/gaming-setup/sunshine/sunshine.conf`: `encoder = vaapi`, `adapter_name = /dev/dri/renderD128` |
| AV1 not offered to client | client can't do AV1, or profile forces H.264/HEVC | expected — Sunshine negotiates down. Force with `gaming-launcher quality gaming-high-perf` |
| Encoder OK but heavy stutter at 1440p120 | one VCN unit saturated | drop to `balanced`; `gaming-launcher status` shows GPU/VCN load (install `amdgpu_top` for per-engine) |

## Sway session / capture / Steam — the three that bit us first

**These are the defaults now** (`~/.config/gaming-setup/gaming-setup.conf`), documented here in case you change them back and wonder why it breaks:

1. **`wlr_renderer = gles2`** — *not* `vulkan`. wlroots' Vulkan renderer fails
   DMA-BUF import on a headless output on current Mesa (`Format XR24 … modifier
   INVALID`, `Failed to import DMA-BUF FD … Bad file descriptor`), which makes
   Sunshine log `[wayland] Frame capture failed` and exit, and makes
   `gamescope-wl` SIGABRT. `gles2` captures fine. `pixman` (CPU) is the last
   resort if even gles2 misbehaves.
2. **`use_gamescope = false`** — gamescope's nested-Wayland WSI aborts on a
   *headless* parent compositor. Sway fullscreens Big Picture / games itself.
   Turn it on per-game only once you've confirmed it works on your setup.
3. **Quit desktop Steam before streaming.** Steam is single-instance: a running
   desktop Steam swallows the in-session `steam -gamepadui` launch (it just
   flips the *desktop* to Big Picture) and the stream stays black. The launcher
   now refuses with `err Steam is already running on the desktop …`. Fully exit
   Steam (Steam ▸ Exit), confirm `pgrep -x steam` is empty, then reconnect.

## Sway session won't start

`session.log` shows the real error.

| Log line | Fix |
|---|---|
| Vulkan `render/vulkan/texture.c … modifier INVALID` / `import DMA-BUF FD … Bad file descriptor` | `wlr_renderer = gles2` (already the default) |
| `failed to create renderer` | try `wlr_renderer = pixman` |
| `dbus-run-session: command not found` | `sudo pacman -S dbus` |
| `cannot open /dev/dri/renderD128` | add yourself to `video`/`render` groups, re-login |
| socket never appears, no obvious error | run `gaming-launcher --debug gaming`; check `journalctl --user -u sunshine-gaming` |
| `HEADLESS-1` missing in `swaymsg -t get_outputs` | wlroots didn't auto-create it; the launcher runs `swaymsg create_output` — check sway version ≥ 1.9 |

## No audio on the client

| Check | Command |
|---|---|
| null sink exists | `pactl list short sinks | grep sink-sunshine` |
| service healthy | `systemctl --user status gaming-null-sink.service` → `restart` it |
| Sunshine records it | `sunshine.conf` → `audio_sink = sink-sunshine`; `sunshine.log` → *audio ... sink-sunshine.monitor* |
| game actually routed there | with a session up: `pactl list sink-inputs` should show the game on `sink-sunshine` (Sway session exports `PULSE_SINK`) |
| desktop lost its sound after a session | `gaming-launcher audio restore` (also runs automatically on client disconnect) |

If PipeWire itself is dead (`pactl` → *Connection refused*):

```sh
systemctl --user reset-failed pipewire pipewire-pulse wireplumber
systemctl --user restart pipewire wireplumber pipewire-pulse
```

This stack never edits PipeWire's own config, so it is not the cause — check for
a stray file in `~/.config/pipewire/`.

## Controller

| Symptom | Cause / fix |
|---|---|
| pad moves the **desktop** cursor / types while streaming | a DS4/DS5 touchpad or Steam-Controller mouse endpoint. `gaming-launcher status` lists endpoints it disabled; `input_release` re-enables on stop. If one was missed, add its name substring to `_INPUT_PAD_PAT` in `lib/input.sh` |
| pad does nothing **in the game** | Steam Input off, or desktop Steam grabbed it first. Enable Steam Input for the title; **don't run desktop Steam while a session is up** (`/dev/input/js*` is global) |
| pad not detected at all | `gaming-launcher troubleshoot input`; check `/dev/uinput` exists, you're in `input` group, udev rule installed (`ls /etc/udev/rules.d/71-gaming-controllers.rules`), then `sudo udevadm trigger --subsystem-match=input` |
| virtual pad from Moonlight missing | Sunshine `gamepad = auto`; `/dev/uinput` writable; re-pair client |

## Latency

Target: < 50 ms end-to-end on LAN at 1080p60.

1. `gaming-launcher benchmark` — VA-API entrypoints + capture path.
2. Moonlight stats overlay (Ctrl+Alt+Shift+S) — decode/network/host split.
3. Host-side: `sunshine.log` capture path — `dmabuf` good, `shm` adds a memcpy
   (expected on AMD VAAPI today, still fine ≤ 1440p).
4. Reduce: `gaming-launcher quality balanced`, wired LAN, 5 GHz/6 GHz only, raise
   client FEC.
5. `gaming-launcher quality --auto on` to let it step down on sustained loss.

## Moonlight can't find / connect to the host

| Cause | Fix |
|---|---|
| Polaris running on the default ports | `gaming-launcher status` warns; `systemctl --user stop polaris` (or run Polaris instead of this) |
| firewall | allow TCP/UDP 47984–48010 (gaming) and 48020–48030 (second screen) on the LAN |
| first pairing | open `https://<host>:47990`, accept the self-signed cert, enter the PIN |
| custom port not discovered | this instance uses 47989 (default); if you changed `port`, add the host in Moonlight manually as `IP` (discovery still uses base port) |

## Second screen

<a name="second-screen"></a><a name="second-display"></a>

`gaming-launcher secondscreen on|off` — separate Sunshine on port 48020, in your
desktop Hyprland. Logs: `~/.local/state/gaming-launcher/sunshine-display.out`.

| Symptom | Cause / fix |
|---|---|
| second monitor is 1920×1080 / everything tiny (scale 2) | the `pcall(dofile, …gaming-setup-display.lua)` line isn't in `~/.config/hypr/hyprland.lua` — re-run `./install.sh` (it offers to add it), or add it by hand after `require("monitors")` |
| `output N not at WxH yet` (implicit) / wrong size | `hyprctl reload` didn't pick up the rule — check `~/.config/hypr/gaming-setup-display.lua` has the `hl.monitor{}` line between the markers, run `hyprctl reload` |
| client shows your **main** desktop, not the empty second screen | `output_name` in `~/.config/gaming-setup/sunshine/sunshine-display.conf` should be the **connector name** (`HEADLESS-N`), not a number — a numeric index shifts under a `hyprctl reload` (theme-sync etc.) and Sunshine then grabs DP-2. Correct pick logs `Selected monitor []` (headless = empty name); wrong pick logs `Selected monitor [… (DP-2)]`. `gaming-launcher secondscreen off && … on` rewrites it. |
| Moonlight cursor lands on the wrong monitor | Sunshine's virtual pointer isn't confined to the streamed output. Workarounds: enable "Optimize mouse for remote desktop" (absolute mode) in the client; use the client's touch/trackpad (maps to the streamed rect); or `gaming-launcher secondscreen on 0x0` so absolute coords line up with your real screen. |
| `secondscreen off` left `HEADLESS-N` behind | `hyprctl output remove HEADLESS-N`, then put `-- (inactive)` between the markers in `~/.config/hypr/gaming-setup-display.lua` and `hyprctl reload`. `secondscreen on` also auto-clears orphans. |
| no audio wanted but client still gets some | by design there is none — `audio_sink` points at the always-empty `sink-sunshine`. If you *want* audio on the second screen, that's `remote-work`-style desktop passthrough, not this mode. |

## Clean slate

```sh
gaming-launcher stop
systemctl --user restart gaming-null-sink.service
rm -f /run/user/$UID/gaming-launcher/state.json
./install.sh            # re-render configs
```

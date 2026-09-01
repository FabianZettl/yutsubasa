# Arbeitsaufgabe: Hyprland Virtual Display Gaming & Streaming Stack

## Executive Summary
Implementierung eines Streaming-Setups mit Hyprland auf virtuellen Displays, das Gaming und Desktop-Arbeit trennt:

**Architektur:**
- **Physischer Ultrawide-Monitor**: Desktop-Arbeit, Produktivität (99% Nutzung)
- **Virtueller Display 1**: Gaming-Session mit Input-Isolation (isolierter vDisplay)
- **Virtueller Display 2** (optional): Remote-Desktop oder Koop-Mirroring

Sunshine streamt vom virtuellen Display → Moonlight/Artemis-Client auf Remote-PC/Handheld.
Client-Capabilities (Auflösung/FPS) triggern adaptive Quality-Anpassung.

Basierend auf Polaris-Projekt, optimiert für AMD 7800XT mit Moonlight/Artemis-Clients auf Arch Linux / CachyOS.

---

## Anforderungen

### Funktional

#### Mode 1: Gaming-Session (Primär - 99%)
- [ ] Virtual Display (vkms) für Gaming-Session
- [ ] Hyprland auf vDisplay0 (konfigurierbar Auflösung/FPS)
- [ ] Sunshine-Server mit AMD VCN (H.264/H.265)
- [ ] Input-Isolation: Controller nur in Gaming-Session (nicht am Desktop)
- [ ] Audio-Routing: Game-Audio zu Stream (oder isoliert zu Headset)
- [ ] Steam Integration (AppID-Launch, BigPicture Mode)
- [ ] Streaming zu Moonlight/Artemis-Clients

#### Mode 2: Optional Mirror Physical Display (Optional - 1%)
- [ ] Live-Streaming vom physischen eDP-1 Monitor (Desktop)
- [ ] Keine Input-Isolation (normaler Desktop-Betrieb)
- [ ] Use-Cases: Remote-Arbeit, Koop auf großem Monitor
- [ ] Fallback: Switch zwischen vDisplay0 ↔ eDP-1

#### Mode 3: Adaptive Quality (Kernfeature)
- [ ] **Client-Capabilities-Negotiation**:
  - Moonlight/Artemis meldet: max Resolution / FPS / Bitrate
  - Sunshine passt Encoding-Profile an
- [ ] **Runtime-Anpassung**:
  - Dynamische Auflösungsumschaltung (1440p → 1080p → 720p)
  - FPS-Anpassung (120 → 60 → 30 fps)
  - Bitrate-Optimierung bei Netzwerk-Drosseln
- [ ] **Quality-Profile**:
  - `gaming-high-perf`: 1440p/120Hz, High Bitrate (Gaming primär)
  - `balanced`: 1080p/60Hz, Medium Bitrate (Koop/allgemein)
  - `remote-work`: 1080p/30Hz, Low Bitrate (Remote-Arbeit)
  - `custom`: User-definiert
- [ ] **Encoding-Optimization**:
  - AMD VCN Load-Balancing (VCN0/VCN1 für 7800XT)
  - H.265 (HEVC) für High-Quality
  - H.264 fallback für Compatibility

### Non-funktional
- **Performance**: <50ms Latenz (Gaming), <100ms (Mirroring)
- **Stabilität**: Crash in einer Session beeinträchtigt andere nicht
- **Sicherheit**: Input-Isolation bleibt gewährleistet
- **Skalierbarkeit**: Multi-Client Support (mehrere Moonlight-Clients gleichzeitig?)
- **Benutzerfreundlichkeit**: Mode-Wechsel ohne Neustart

---

## Architektur-Übersicht

```
┌──────────────────────────────────────────────────────────────┐
│                    Hyprland (Wayland)                        │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  PHYSISCHER OUTPUT              VIRTUELLE OUTPUTS             │
│  ┌──────────────────┐           ┌────────────────────────┐   │
│  │ eDP-1/HDMI-1     │           │ vDisplay0 (Gaming)     │   │
│  │ Ultrawide Monitor│           │ ├─ vkms/DRI Device     │   │
│  │ (Desktop Work)   │           │ ├─ Resolution: dynamic │   │
│  │                  │           │ └─ Sunshine streams    │   │
│  └──────────────────┘           └────────────────────────┘   │
│         ↑                                   ↓                │
│         │                              [Sunshine]            │
│    No change                           captures              │
│    (99% use)                           from vDisplay         │
│                                                               │
│  ┌────────────────────────────────────────────────────────┐  │
│  │              Sunshine Server                           │  │
│  │  ├─ Input Router: Controller → Gaming-Session only    │  │
│  │  ├─ Audio Router: Gaming-Audio isolated/Passthrough   │  │
│  │  ├─ Quality Adapter:                                  │  │
│  │  │  ├─ Client-Caps Negotiation (Res/FPS/Bitrate)   │  │
│  │  │  ├─ Runtime Adaptation (Network-Monitor)         │  │
│  │  │  └─ Profile Selection (High-Perf/Balanced/etc)   │  │
│  │  └─ VCN Encoder:                                     │  │
│  │     ├─ AMD 7800XT (VCN0/VCN1)                       │  │
│  │     └─ H.264/H.265 auto-select                      │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌────────────────────────────────────────────────────────┐  │
│  │          Gaming Launcher & Mode-Selector              │  │
│  │  $ gaming-launcher [mode] [game] [options]            │  │
│  │  ├─ gaming [game-name]     → vDisplay gaming session  │  │
│  │  ├─ quality [profile]       → Adapt resolution/fps    │  │
│  │  ├─ mirror [--physical]     → Optional physisch       │  │
│  │  └─ status / stop                                     │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                               │
└──────────────────────────────────────────────────────────────┘
                          │
                    [Netzwerk/LAN]
                          │
              ┌───────────┴───────────┐
              │                       │
         ┌────▼─────┐          ┌──────▼──────┐
         │ Moonlight│          │  Artemis    │
         │  Client  │          │   Client    │
         │(Remote   │          │ (Android/   │
         │ Laptop)  │          │  Handheld)  │
         └──────────┘          └─────────────┘
```

---

## Phase 1: Hyprland Virtual Display Setup

### 1.1 Virtual Display Architektur
**Concept:**
```
Hyprland
├─ eDP-1/HDMI-1 (Physisch - Ultrawide Monitor)
│  └─ Workspace 0-9: Desktop/Produktivität/Dauerbeschäftigung
│
└─ vDisplay0 (Virtuell - Gaming/Streaming)
   └─ Workspace 10-19: Gaming-Session
      └─ Sunshine streamt diesen Output
```

**Virtual Display Optionen:**
1. **vkms** (Kernel Mode Setting Virtual): Built-in, gut für Tests
2. **kvmfr** (KVM Frame Relay): Ultra-low-latency, aber komplexer
3. **XVFB/Xwayland**: Legacy, nicht ideal für Wayland
4. **Sunshine's integrated vDisplay**: Direkte Integration möglich

**Entscheidung: vkms primär, kvmfr optional**
- vkms: Stabil, einfach zu debuggen, ausreichend Latenz für Gaming
- kvmfr: Optional für <15ms Capture-Latenz wenn nötig

**Tasks:**
- [ ] vkms Kernel-Modul testen (Arch: `sudo modprobe vkms`)
- [ ] Hyprland-Config für vkms Output anpassen
- [ ] vDisplay0 Resolution definieren (z.B. 1440p @ 120Hz dynamic)
- [ ] Hyprland DISPLAY_LINK zwischen physisch + virtuell prüfen
- [ ] Optional: kvmfr Research für Ultra-Low-Latency-Option

### 1.2 Hyprland-Config für Virtual Display

**~/.config/hyprland/hyprland-gaming.conf (virtueller Output):**
```bash
# Virtual Display Config
monitor=vDisplay0,1440x2160@120,0x0,1

# Workspaces auf vDisplay0
workspace=10,monitor:vDisplay0
workspace=11,monitor:vDisplay0
workspace=12,monitor:vDisplay0

# Input nur auf vDisplay0 (im Gaming-Mode)
# [INPUT CONFIG - siehe Phase 4]

# Andere Settings (gaps, rounding, etc.) können abweichen
```

**Hyprland Main Config (physischer Monitor):**
```bash
# Physischer Monitor - bleibt unverändert
monitor=eDP-1,preferred,0x0,1

workspace=0,monitor:eDP-1
workspace=1,monitor:eDP-1
# ... etc.
```

**Tasks:**
- [ ] vkms als Monitor in Hyprland-Config registrieren
- [ ] Resolution/Refresh-Rate variabel (Sunshine sendet Anforderungen)
- [ ] Dynamic-Resolution testen (1440p ↔ 1080p ↔ 720p wechseln)
- [ ] Workspace-Mapping validieren
- [ ] Startup-Script: vkms laden + Hyprland mit Config starten

### 1.3 Virtual Display Initialization-Script

**`init-virtual-display.sh`:**
```bash
#!/bin/bash
# Loads vkms + initializes virtual display for Sunshine streaming

set -e

# 1. Load vkms kernel module
echo "Loading vkms kernel module..."
sudo modprobe vkms

# 2. Wait for /dev/dri/card* to appear
for i in {1..10}; do
  if [ -e /dev/dri/card1 ]; then
    echo "Virtual card ready: /dev/dri/card1"
    break
  fi
  sleep 0.5
done

# 3. Check DRM capabilities
echo "Checking DRM device..."
weston-info --backend=drm-backend.so | grep -A5 "Output:"

# 4. Start Hyprland with virtual display config
export HYPRLAND_INSTANCE_SIGNATURE=$(echo $RANDOM | md5sum | cut -c1-8)
export DISPLAY=:0
hyprland --config ~/.config/hyprland/hyprland-gaming.conf &

# 5. Wait for Hyprland to initialize
sleep 2

# 6. Verify vDisplay0 is active
hyprctl monitors all | grep "vDisplay"

echo "✓ Virtual display initialized. Ready for Sunshine."
```

**Tasks:**
- [ ] Script schreiben + testen
- [ ] Autostart via systemd-user-service (optional)
- [ ] Error-Handling (vkms load failed, etc.)

### 1.4 Session Management
**Gaming-Session Start:**
```bash
$ gaming-launcher gaming dota2
├─ Load vkms (if not loaded)
├─ Start Hyprland with gaming.conf (vDisplay0)
├─ Move Workspace 10-19 zu vDisplay0
├─ Configure Input → vDisplay0 only
├─ Start Sunshine (if not running)
├─ Launch Game/Steam in Workspace 10
└─ Monitor: Session lifecycle
```

**Tasks:**
- [ ] Session-Manager für vDisplay0 Lifecycle
- [ ] Hyprland-Instance-Verwaltung (HYPRLAND_INSTANCE_SIGNATURE)
- [ ] Graceful shutdown (vDisplay → unload vkms)

---

## Phase 2: Sunshine Server mit Adaptive Quality

### 2.1 Sunshine Core Setup (unverändert)
- [ ] Installation & Config: `/etc/sunshine/sunshine.conf`
- [ ] AMD VCN Encoder:
  ```ini
  hwenc=amd
  # VCN für 7800XT (2x VCN Units)
  ```
- [ ] VAAPI Device: `/dev/dri/renderD128` oder auto-detect

### 2.2 Mode-Handler in Sunshine

**Input-Modul: `sunshine-mode-handler.py`**

```python
class SunshineMode(Enum):
    GAMING = "gaming"           # vDisplay0 + Input-Isolation
    MIRROR = "mirror_physical"  # Optional: eDP-1 (Desktop)

class ModeConfig:
    display_source: str         # "vDisplay0" oder "eDP-1"
    audio_isolation: bool       # True for gaming, False for physical
    input_isolation: bool       # True for gaming, False for mirror
    encoding_preset: str        # performance/balanced/quality
    vdisplay_active: bool       # ist vkms geladen?
```

**Primary Mode: Gaming (vDisplay0)**
```python
Mode.GAMING:
  - Source: vDisplay0 (virtual)
  - Input: Isolated (Controller → Gaming-Session only)
  - Audio: Isolated (Game-Audio zu Stream)
  - Profile: high_perf (1440p/120Hz)
```

**Secondary Mode: Mirror Physical (Optional)**
```python
Mode.MIRROR:
  - Source: eDP-1 (Physical Monitor)
  - Input: Not isolated (Normal Desktop)
  - Audio: Passthrough (Desktop-Audio)
  - Profile: Dynamic (based on Client Caps)
  - Use-Case: Remote-Arbeit, Koop auf großem Monitor
```

**Tasks:**
- [ ] Mode-Handler als Daemon/Service
- [ ] Config-File für Defaults (Gaming-Mode primary)
- [ ] Mode-Switch-API (CLI/HTTP)
- [ ] State-File: `/run/sunshine/mode.json`

### 2.3 Quality-Negotiation System (Neu)

**Client → Server Handshake:**
```
[Moonlight/Artemis Connect]
  ↓
Server receives: Client Capabilities
  {
    "max_width": 2560,
    "max_height": 1440,
    "max_fps": 120,
    "preferred_codec": "H.265",
    "max_bitrate_mbps": 50,
    "features": ["hevc", "hdr", "fec"]
  }
  ↓
Server selects: Encoding Profile
  {
    "mode": "mirror",
    "resolution": "1440p",
    "fps": 120,
    "bitrate": 45,
    "codec": "H.265",
    "encoder": "VCN0",
    "profile": "gaming_high_perf"
  }
  ↓
[Stream starts]
```

**Tasks:**
- [ ] Sunshine-Patch: Client-Capabilities auslesen
  - Moonlight Protocol: ParseClientCapabilities()
  - Artemis Protocol: Caps-Negotiation
- [ ] Quality-Profile-System:
  ```ini
  [profile_gaming_high_perf]
  resolution=1440
  fps=120
  bitrate=45
  codec=hevc
  
  [profile_balanced]
  resolution=1080
  fps=60
  bitrate=25
  codec=h264
  
  [profile_remote_work]
  resolution=1080
  fps=30
  bitrate=10
  codec=h264
  ```
- [ ] Auto-Select Logic in Sunshine
- [ ] Config-Override per Client

### 2.4 Runtime Quality-Adaptation

**Netzwerk-basierte Anpassung:**
```
Sunshine Monitor Loop:
├─ Alle 5s: Network-Stats abfragen
│  └─ RTT, Packet-Loss, Bandwidth
├─ Berechne neue Quality:
│  └─ loss > 5% → reduce_bitrate
│  └─ rtt > 100ms → reduce_fps
│  └─ loss < 1% && bw ok → increase_quality
└─ Grana Transition (smooth quality switch)
   └─ Auflösung: progressive reduction (1440 → 1080 → 720)
   └─ FPS: immediate (120 → 60 OK)
   └─ Codec: nur wenn notwendig
```

**Tasks:**
- [ ] Network-Monitor in Sunshine
  - RTCP-Statistiken auswerten
  - Packet-Loss-Rate berechnen
- [ ] Quality-Decision-Engine
  - Heuristiken: wenn A dann B
  - Hysterese: Nicht zu oft schalten
- [ ] Encoder-Anpassung:
  - VCN Rate-Control konfigurieren
  - Bitrate on-the-fly ändern
  - Auflösungs-Switching (mit Framepuffer-Resize)
- [ ] Logging: `/var/log/sunshine-quality-adapt.log`

### 2.5 AMD VCN Encoder Optimization

**7800XT hat 2 VCN Units (VCN0, VCN1):**
```bash
# Aktiv nutzen für:
# - VCN0: Primary Stream (Gaming/Mirror)
# - VCN1: Optional 2nd Stream oder Quality-Monitoring

# Check VCN Load:
rocm-smi --showuse --json | grep vce
```

**Tasks:**
- [ ] VCN-Load-Balancing Script
  - Auto-Select nicht-überlastete VCN
  - Fallback wenn beide überlastet
- [ ] Rate-Control Tuning:
  - VBR vs CBR für verschiedene Modi
  - QP-Offsets für Qualität vs Bitrate
- [ ] Profile-Configs:
  ```bash
  # Gaming: Performance
  amdenc -preset=perf -rc=vbr -qp_init=30
  
  # Mirroring: Quality
  amdenc -preset=high_quality -rc=cbr -qp_init=28
  
  # Remote Work: Bitrate-optimiert
  amdenc -preset=balanced -rc=cbr -qp_init=32
  ```
- [ ] Monitoring: VCN-Auslastung in Stats

---

## Phase 3: Mode-Switching & Launcher

### 3.1 Gaming-Mode (Primär - vDisplay0)

**Workflow:**
```bash
$ gaming-launcher gaming dota2
├─ Check: vkms geladen? Nein → sudo modprobe vkms
├─ Check: Hyprland läuft? Nein → start gaming Hyprland
├─ Initialize: vDisplay0 (1440p/120Hz)
├─ Load: Hyprland auf vDisplay0
├─ Start: Sunshine (Mode=gaming)
├─ Input: Controller → vDisplay0 nur (isoliert)
├─ Audio: Pipewire Gaming-Sink (isoliert)
├─ Launch: Steam → Spiel starten in Workspace 10
├─ Monitor: Sunshine-Stats, Input, Audio
└─ Cleanup on Exit: vDisplay0 unload, vkms unload
```

**Tasks:**
- [ ] Gaming-Launcher-Script
  - vkms modprobe + error-handling
  - Hyprland gaming config startup
  - Session-Lifecycle
- [ ] Steam Integration (AppID-Lookup, Launch)
- [ ] Graceful Shutdown (Game → Session cleanup → vkms unload)
- [ ] Error Recovery (Game crashed, Session läuft aber weiter)

### 3.2 Mirror-Mode (Optional - eDP-1)

**Workflow (Nur wenn gewünscht - 1% Use-Case):**
```bash
$ gaming-launcher mirror --physical
├─ Check: Sunshine aktiv? Nein → starten
├─ Switch: Sunshine source zu eDP-1 (physischer Monitor)
├─ Capture: Wayland Screencopy von eDP-1
├─ Audio: Passthrough (Desktop-Audio)
├─ Input: Nicht isoliert (Normal-Desktop)
├─ Use-Case: Remote-Arbeit, Koop-Spiele auf großem Monitor
└─ Listen: Client-Verbindungen
```

**Varianten:**
- **Remote-Arbeit**: Desktop streamen auf Remote-Laptop
- **Koop-Gaming**: Monitor physical anschauen, Moonlight-Client auch spielen
- **Zuschauer-Stream**: Optional Twitch-Integration

**Tasks (Optional):**
- [ ] Mirror-Launcher für eDP-1
- [ ] Wayland Screencopy Integration (falls not in Sunshine)
- [ ] Audio Passthrough Setup
- [ ] Switch-Logic: vDisplay0 ↔ eDP-1
- [ ] Multi-Client-Support testen

### 3.3 Launcher-Command-Structure

```bash
# Grundstruktur
gaming-launcher [COMMAND] [OPTIONS]

# Gaming-Mode (virtueller Display)
gaming-launcher gaming [game-name] \
  --profile high_perf \
  --resolution 1440 \
  --fps 120

# Mit Steam
gaming-launcher gaming steam:570        # Dota 2 via Steam

# Quality-Anpassung (Profiles)
gaming-launcher quality [profile] \
  --resolution 1440 \
  --fps 120 \
  --bitrate 40

# Presets
gaming-launcher quality gaming-high-perf    # 1440p/120Hz
gaming-launcher quality balanced            # 1080p/60Hz
gaming-launcher quality remote-work         # 1080p/30Hz

# Optional: Physisches Display spiegeln (1%)
gaming-launcher mirror --physical        # Stream eDP-1 (Desktop)

# Status & Management
gaming-launcher status                   # Sunshine + vDisplay Status
gaming-launcher list-games               # Steam-Library
gaming-launcher stop                     # Beende Streaming/Session
gaming-launcher logs                     # Sunshine-Logs
gaming-launcher troubleshoot             # Auto-Diagnose

# Advanced
gaming-launcher config show              # Alle Configs
gaming-launcher config edit              # Interaktiv editieren
gaming-launcher benchmark                # Latency-Test
gaming-launcher unload-vdisplay          # Cleanup: vkms entfernen
```

**Tasks:**
- [ ] Main-Launcher-Script (`gaming-launcher`)
- [ ] Subcommand-Handler für jeden Mode
- [ ] Option-Parsing (getopt/argparse)
- [ ] Shell-Completion (`bash-completion.d/gaming-launcher`)

### 3.4 Systemd-Integration

**Services:**
```ini
# /etc/systemd/user/gaming-sunshine.service
[Unit]
Description=Gaming Sunshine Server
After=network.target pipewire.service
Wants=gaming-session-manager.service

[Service]
Type=notify
ExecStart=/usr/local/bin/sunshine
Environment=SUNSHINE_CONFIG=/etc/sunshine/gaming.conf
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target

---

# /etc/systemd/user/gaming-quality-adapter.service
[Unit]
Description=Sunshine Quality Adapter Daemon
After=gaming-sunshine.service

[Service]
Type=simple
ExecStart=/usr/local/bin/sunshine-quality-adapter
Restart=on-failure

[Install]
WantedBy=default.target
```

**Tasks:**
- [ ] Service-Files schreiben
- [ ] Enable/Disable Logik in Launcher
- [ ] journalctl-Integration für Logs

---

## Phase 4: Input & Audio Isolation/Routing

### 4.1 Input-Isolation (Gaming-Mode)

**Ziel:** Controller + Keyboard nur in Gaming-Session aktiv

**Implementierung:**
```bash
# Udev-Rules: Devices markieren
SUBSYSTEM=="input", ATTRS{name}=="*Controller*", TAG="gaming-device"
SUBSYSTEM=="input", ATTRS{name}=="*DS5*", TAG="gaming-device"

# Libinput-Handling in Gaming-Session
export WLR_LIBINPUT_DEVICES="/dev/input/event[X]:/dev/input/event[Y]"

# Fallback: Input-Remapper (falls udev nicht reicht)
input-remapper --device "Controller" --target "Gaming-Session"
```

**Tasks:**
- [ ] Udev-Rules schreiben + testen
- [ ] Libinput-Device-Isolation
- [ ] Gaming-Session ENV konfigurieren
- [ ] Input-Remapper Fallback (optional)
- [ ] Test: Controller in Main-Session nicht aktiv während Gaming

### 4.2 Audio-Routing

**Gaming-Mode:**
```
[Game Audio] → [Pipewire-Sink: Gaming]
                    ↓
            [Sunshine Audio Capture]
                    ↓
            [Stream zu Moonlight/Artemis] + [optional: Lokal-Headset]
```

**Mirror-Mode:**
```
[Desktop Audio] → [Pipewire: Default]
                    ↓
            [Sunshine Audio Capture (passthrough)]
                    ↓
            [Stream zu Moonlight/Artemis]
```

**Tasks:**
- [ ] Pipewire-Graphs für beide Modi
  ```bash
  # Gaming Audio-Sink
  pactl create-sink-Gaming
  
  # Sunshine Audio-Input von Gaming-Sink
  pactl set-source-output [app-id] Gaming-sink
  ```
- [ ] Audio-Source-Script: `setup-audio-routing.sh`
- [ ] Fallback zu Pulseaudio falls Pipewire Probleme
- [ ] Test: Audio nur im Stream, nicht lokal (Gaming-Mode)

---

## Phase 5: Virtual Display Capture & Streaming

### 5.1 Sunshine Capture von vDisplay0

**Primär: vkms Direct Capture**
```
vDisplay0 (vkms kernel output)
    ↓
VAAPI H.264/H.265 Encoder (AMD VCN)
    ↓
Streaming zu Moonlight/Artemis
```

**Capture-Methoden für vkms:**
1. **DRM Direct**: Low-level, fast
2. **VAAPI**: Hardware-codec integration
3. **Screencopy**: Fallback, wenn DRM problematisch
4. **GStreamer Pipeline**: Optional

**Tasks:**
- [ ] Sunshine vkms-Support testen
  - `SUNSHINE_OUTPUT=vDisplay0 sunshine` oder Config
  - oder auto-detect vkms wenn Hyprland drauf läuft
- [ ] VAAPI für vkms-Frames aktivieren
- [ ] Capture-Latency benchmarken (vkms sollte <5ms sein)
- [ ] Buffer-Management (GPU-VRAM vs System-RAM)

### 5.2 Resolution-Adaptation bei Runtime

**Problem:** Client möchte 1080p/60Hz, wir starten 1440p/120Hz

**Lösung:**
```bash
# Sunshine sends to vDisplay0:
hyprctl dispatch resizeactivewindow 1920x1080   # Optional downscale
# oder Encoding macht es:
encoding_resolution = min(physical_resolution, client_max_resolution)
```

**Virtual Display Dynamic Resize:**
```bash
# Hyprland kann vDisplay0 runtime resize:
hyprctl keyword monitor vDisplay0,1080x1920@60,0x0,1

# Oder Sunshine passt Encoding an (einfacher)
```

**Tasks:**
- [ ] Test: vDisplay0 Res wechseln ohne Neustarts
- [ ] Hyprland-Monitor-Reload prüfen
- [ ] Oder: Nur Encoding-Res ändern (einfacher)
- [ ] Smooth Transition (keine Artefakte)

### 5.3 Optional: Physisches Display-Mirroring (1% Use-Case)

**Nur wenn gewünscht: Streaming vom physischen eDP-1 Monitor**

```bash
# Mode: Mirror physical display
$ gaming-launcher mirror --physical
├─ Sunshine switches source from vDisplay0 → eDP-1
├─ Stream Desktop-Session statt Gaming
├─ Input nicht isoliert
└─ Für: Remote-Arbeit, Koop-Spiele auf großem Monitor
```

**Implementation (optional):**
- [ ] Sunshine Config: `output=eDP-1` (anstatt `vDisplay0`)
- [ ] Wayland Screencopy von eDP-1
- [ ] No Input-Isolation (Desktop-Mode)
- [ ] Fallback zu vDisplay0 wenn eDP-1 nicht verfügbar

**Tasks (Optional):**
- [ ] Wayland Screencopy Protocol für eDP-1
- [ ] Screencopy-Backend in Sunshine (falls nicht existent)
- [ ] Test: Streaming vom physischen Monitor
- [ ] Switch-Logic zwischen vDisplay0 + eDP-1

---

## Phase 6: Quality-Profiles & Config-System

### 6.1 Profile-Definition

```ini
# ~/.config/gaming-setup/profiles.conf

[profile_gaming_high_perf]
description = High Performance Gaming (1440p/120Hz)
resolution = 1440
fps = 120
bitrate = 45
codec = H.265
preset = performance
vce_load_balance = true
audio_isolation = true
input_isolation = true

[profile_balanced]
description = Balanced (Koop/Mid-Tier)
resolution = 1080
fps = 60
bitrate = 25
codec = H.264
preset = balanced
audio_isolation = false
input_isolation = false

[profile_remote_work]
description = Remote Work (Low Bitrate)
resolution = 1080
fps = 30
bitrate = 10
codec = H.264
preset = quality
audio_isolation = false
input_isolation = false

[profile_custom]
description = User-Defined
# User editierbar
```

### 6.2 Dynamic Profile Selection

**Auto-Detect basierend auf:**
```
if mode == gaming:
  profile = gaming_high_perf
  
if mode == mirror && num_displays == 2:
  profile = balanced
  
if network_bandwidth < 20Mbps:
  profile = remote_work
  
if client_caps.max_fps == 30:
  profile = remote_work
```

**Tasks:**
- [ ] Profile-Engine
- [ ] Auto-Selection-Logik
- [ ] Runtime-Override per Client
- [ ] Config-Validation (Plausibilität-Checks)

### 6.3 Config-Management

**Hierarchie:**
1. `/etc/sunshine/sunshine.conf` (System-Default)
2. `~/.config/gaming-setup/sunshine-local.conf` (User-Override)
3. Mode-spezifische: `~/.config/gaming-setup/profiles.conf`
4. CLI-Override: `gaming-launcher --override fps=60`

**Tasks:**
- [ ] Config-Merge-Engine
- [ ] Interactive Config-Editor (`gaming-launcher config edit`)
- [ ] Validation & Error-Messages
- [ ] Config-Backup/Restore

---

## Phase 7: Monitoring, Logging & Troubleshooting

### 7.1 Real-Time Monitoring

```bash
$ gaming-launcher status
────────────────────────────────────
🟢 Sunshine Server: Running (PID 1234)
📊 Mode: mirror (HDMI-1 @ 1440p/120Hz)
👥 Clients: 1 (Moonlight - 192.168.1.50)
───────────────────
Encoding Stats:
  ├─ FPS: 120 (target) → 118 (actual)
  ├─ Bitrate: 45 Mbps (target) → 42 Mbps (actual)
  ├─ Latency: 28ms (capture+encode+network)
  ├─ VCN Load: VCN0=85%, VCN1=0%
  └─ Drops: 0 frames (0%)
───────────────────
Network (Client):
  ├─ RTT: 12ms
  ├─ Loss: 0.1%
  └─ Bandwidth: 45 Mbps
───────────────────
Quality Profile: balanced
Next Auto-Adapt: +3.5s (if needed)
────────────────────────────────────
```

**Tasks:**
- [ ] Status-Command mit Live-Refresh
- [ ] Sunshine-Stats-Parsing
  - Frame-Drop-Tracking
  - Latency-Messung
- [ ] VCN-Load-Monitor (rocm-smi Integration)
- [ ] Network-Stats (tcpdump/ss Parsing)

### 7.2 Detailed Logging

```bash
# Sunshine Main Log
/var/log/sunshine/sunshine.log

# Gaming Setup Logs
/var/log/sunshine/gaming-launcher.log     # Mode-Switches
/var/log/sunshine/quality-adapter.log     # Adaptations
/var/log/sunshine/input-router.log        # Input-Isolation
/var/log/sunshine/audio-router.log        # Audio-Routing

# Systemd Logs
journalctl -u gaming-sunshine.service -f
journalctl -u gaming-quality-adapter.service -f

# Debug-Mode
SUNSHINE_LOG_LEVEL=debug gaming-launcher mirror --debug
```

**Tasks:**
- [ ] Structured Logging (JSON-Output)
- [ ] Log-Rotation & Cleanup
- [ ] Debug-Mode mit Verbose Output
- [ ] Log-Analysis-Tool (`gaming-launcher logs analyze`)

### 7.3 Troubleshooting Guide

**Häufige Probleme:**

```bash
# Problem: AMD VCN nicht erkannt
$ gaming-launcher troubleshoot --fix hardware
├─ Check: GPU erkannt? (lspci)
├─ Check: VAAPI-Libs installiert? (libva)
├─ Check: Mesa-Libs für AMD? (amdvlk oder radv)
└─ Fix: Install missing packages

# Problem: Hohe Latenz in Mirror-Mode
$ gaming-launcher troubleshoot --fix latency
├─ Messung: Capture-Latenz
├─ Messung: Encoding-Latenz
├─ Messung: Network-Latenz
├─ Empfehlung: Quality-Profil reduzieren
└─ Empfehlung: Netzwerk-Optimierung

# Problem: Audio nur einseitig
$ gaming-launcher troubleshoot --fix audio
├─ Check: Pipewire läuft?
├─ Check: Audio-Geräte? (pactl list)
├─ Check: Gaming-Sink erstellt?
└─ Fix: Audio-Routing neu-setzen

# Problem: Controller reagiert nicht
$ gaming-launcher troubleshoot --fix input
├─ Check: Input-Geräte erkannt? (lsusb)
├─ Check: Udev-Rules loaded? (udevadm)
├─ Check: Input-Isolation aktiv?
└─ Fix: Input-Remapper neu-kalibrieren
```

**Tasks:**
- [ ] Automatische Diagnostik-Scripts
- [ ] Fix-Recommendations per Problem
- [ ] Fehler-Datenbank/Wiki
- [ ] Interactive Troubleshooter CLI

### 7.4 Performance-Benchmarking

```bash
$ gaming-launcher benchmark
┌─────────────────────────────────────┐
│   Gaming Setup Performance Bench    │
├─────────────────────────────────────┤
│                                     │
│ Test 1: Capture Latency             │
│ Resolution: 1440p                   │
│ Method: Screencopy API              │
│ Result: 2.3ms ✓ (target: <5ms)      │
│                                     │
│ Test 2: Encoding Speed (VCN)        │
│ 1440p → H.265 @ 120fps              │
│ Result: 3.7ms ✓ (target: <10ms)     │
│                                     │
│ Test 3: Network Streaming           │
│ Client: Moonlight (local)           │
│ Round-Trip Latency: 8ms ✓           │
│ Bitrate Stability: 99.8% ✓          │
│                                     │
│ Test 4: Quality Adaptation          │
│ Simulate packet loss (5%)           │
│ Adaptation Time: 1.2s               │
│ Final Quality: 1080p/60Hz ✓         │
│                                     │
│ Overall Score: 9.2/10 (Excellent)  │
└─────────────────────────────────────┘
```

**Tasks:**
- [ ] Benchmark-Suite (Capture, Encode, Network)
- [ ] Baseline-Speicherung für Regression-Detect
- [ ] Grafische Output (ASCII-Charts)

---

## Phase 8: Client Support (Moonlight & Artemis)

### 8.1 Moonlight Optimization

**Moonlight Client Capabilities Protocol:**
- Resolution Support: Abfragen welche Auflösungen unterstützt
- FPS Support: 30/60/120 fps Preference
- Codec Preference: H.264 vs H.265
- Bitrate Limits

**Tasks:**
- [ ] Moonlight-Client-Connector in Sunshine schreiben
- [ ] Capability-Parsing
- [ ] Auto-Config basierend auf Client

### 8.2 Artemis/Moonlight Vergleich

**Research:**
- [ ] Artemis vs Moonlight Features vergleichen
  - Welcher hat bessere Latency?
  - Welcher unterstützt H.265 besser?
  - Welcher hat bessere Input-Lag?
- [ ] Support für beide schreiben oder einen wählen?

**Tasks:**
- [ ] Research-Doc verfassen
- [ ] Entscheidung treffen (oder beide supported)
- [ ] Client-Connector für beide

### 8.3 Steam BigPicture Integration

**Ziel:** Games über Steam in Gaming-Mode starten

```bash
$ gaming-launcher gaming steam:570  # Dota 2 AppID
└─ Steam starten
   └─ Steam BigPicture starten
      └─ AppID 570 starten
         └─ Moonlight Client kann dann streamen
```

**Tasks:**
- [ ] Steam AppID-Lookup (Datenbank oder SteamDB-API)
- [ ] Launch-Command-Builder für Steam
- [ ] Steam-Integration mit Gaming-Session

---

## Phase 9: Dokumentation

### 9.1 Setup-Guide

```markdown
# Gaming Setup Installation Guide

## Voraussetzungen
- Hyprland (Wayland)
- AMD GPU mit VCN (7800XT ✓)
- Sunshine Streaming Server
- Moonlight oder Artemis Client
- Arch Linux / CachyOS

## Installation
1. Package-Installation
2. Sunshine Setup
3. Gaming-Launcher Installation
4. Configuration
5. Testing

## Quick-Start
### Gaming-Mode
### Mirror-Mode
### Quality-Profiles
```

### 9.2 Troubleshooting-Wiki

- [ ] Häufige Probleme & Lösungen
- [ ] Debug-Techniken
- [ ] Performance-Tuning-Guide

### 9.3 Architecture Docs

- [ ] Diagramme der Datenflow
- [ ] Mode-State-Machines
- [ ] API-Dokumentation

### 9.4 API-Referenz

- [ ] Launcher-Commands (--help Output)
- [ ] Config-Schema (JSON-Schema oder ähnlich)
- [ ] Sunshine-Integration-Points

---

## Phase 10: Testing & Optimization

### 10.1 Test-Szenarien

**Gaming-Mode (vDisplay0):**
- [ ] vkms lädt + vDisplay0 initialisiert
- [ ] Hyprland startet auf vDisplay0 ohne Fehler
- [ ] Game startet in Workspace 10-19, streamt via Sunshine
- [ ] Latency <50ms (Capture + Encoding + Network)
- [ ] Controller funktioniert nur im Game (nicht am Desktop)
- [ ] Audio: Game-Audio nur im Stream, nicht lokal
- [ ] Physischer eDP-1 Monitor bleibt unbeeinträchtigt
- [ ] Desktop bleibt responsive während Gaming
- [ ] Shutdown: vDisplay0 cleanup, vkms unload erfolgreich

**Quality-Adaptation:**
- [ ] Client meldet Caps: 1080p/60Hz, 25 Mbps
- [ ] Server adaptiert: 1080p/60Hz statt 1440p/120Hz
- [ ] Dynamischer Wechsel: 1440p → 1080p bei Paketloss >5%
- [ ] Bitrate-Reduktion bei Bandbreitenproblemen
- [ ] Smooth Transition (keine Artifacts/Freezes)

**Mirror-Mode (Optional - eDP-1):**
- [ ] Desktop-Capture von physischem Monitor funktioniert
- [ ] Streaming ohne Input-Isolation (normal Desktop)
- [ ] Audio-Passthrough funktioniert
- [ ] Responsive Mouse/Keyboard (<100ms Latency)
- [ ] Multi-Client-Support (mehrere Moonlight sessions)

### 10.2 Performance-Tuning

- [ ] VCN-Load-Balancing optimieren
- [ ] Buffering-Strategie (Latency vs Quality)
- [ ] Capture-Methode Benchmarking (Screencopy vs VAAPI)
- [ ] Quality-Profiles feinabstimmen

### 10.3 Stability-Testing

- [ ] Long-Run-Test: 4h Gaming-Session
- [ ] Multiple Mode-Switches
- [ ] Crash-Recovery (Game crash → Sunshine läuft weiter)
- [ ] Ressourcen-Leaks (Memory, GPU-Memory, Handles)

---

## Phase 11: Advanced Features (Optional)

### 11.1 Multi-Client Streaming

**Requirement:** Mehrere Clients gleichzeitig streamen

```bash
$ gaming-launcher mirror --multi-client 2
└─ Client 1 (Artemis): 1440p/120Hz
└─ Client 2 (Moonlight): 1080p/60Hz
```

**Herausforderung:** VCN0+VCN1 beide nutzen, oder Software-Fallback

**Tasks:**
- [ ] Multi-Stream-Encoding
- [ ] Per-Stream Quality-Profiles
- [ ] VCN Load-Balancing

### 11.2 Custom Virtual Display (Optional)

**Use-Case:** Gaming-Session auf "virtueller" Display rendern

```bash
# Optionale Alternative zu separater Session
# Wenn Wayland kein Virtual-Display gut unterstützt:
$ gaming-launcher gaming dota2 --virtual-display 1440x2160
```

**Tasks:**
- [ ] vkms (Virtual Kernel Mode Setting) oder kvmfr
- [ ] DRI-Device-Routing
- [ ] Framebuffer-Setup

### 11.3 Network Optimization

- [ ] FEC (Forward Error Correction) für Paketloss
- [ ] QUIC vs TCP für Streaming
- [ ] Adaptive Jitter-Buffer

**Tasks:**
- [ ] Research beste Netzwerk-Protokolle
- [ ] Optional implementieren

---

## Tech Stack (Zusammenfassung)

| Komponente | Lösung | Version |
|---|---|---|
| **OS** | Arch Linux / CachyOS | Latest |
| **Display-Server** | Hyprland | Latest |
| **Streaming** | Sunshine | Latest |
| **Clients** | Moonlight + Artemis | Latest |
| **Capture** | Wayland Screencopy + VAAPI | native |
| **Encoding** | AMD VCN (H.264/H.265) | VCN0/1 |
| **Audio** | Pipewire | native |
| **Input** | Udev + Libinput | native |
| **Scripts** | Bash + Python | 3.11+ |
| **Packaging** | AUR PKGBUILDs | native |

---

## Success Criteria

✅ **Gaming-Mode** funktioniert (wie aktuell geplant)
✅ **Mirror-Mode** <50ms Latenz @ 1440p/120Hz
✅ **Quality-Profiles** automatisch anpassen
✅ **Koop-Spiele** ohne Probleme spielbar
✅ **Remote-Arbeit** funktioniert bei niedrigem Bitrate
✅ **Keine Crashes** in Haupt-Session durch Gaming
✅ **Dokumentiert** für Wartung & Erweiterung
✅ **Benutzbar** ohne technisches Tiefenwissen

---

## Geschätzter Scope (Virtual Display Setup)

| Phase | Scope | Hours |
|---|---|---|
| 1. vkms Virtual Display | Init + Hyprland Config | 4-6h |
| 2. Sunshine + AMD VCN | Setup + Config | 6-8h |
| 3. Quality Adapter | Client-Caps + Runtime-Adapt | 8-10h |
| 4. Launcher + Mode-Switching | CLI + Automation | 4-6h |
| 5. Input/Audio Isolation | Gaming-Mode only | 4-6h |
| 6. vDisplay Capture | Sunshine Integration | 4-6h |
| 7. Quality-Profiles | Config-System | 3-4h |
| 8. Monitoring + Logs | Stats + Diagnostics | 3-4h |
| 9. Client Support | Moonlight/Artemis Compat | 2-4h |
| 10. Dokumentation | Setup-Guide + Troubleshooting | 4-6h |
| 11. Testing + Tuning | Benchmarks + Optimization | 6-8h |
| 12. Optional: Physical Mirror | 1% Use-Case (optional) | 3-4h |
| **TOTAL (Core)** | **Phasen 1-11** | **49-68h** |
| **TOTAL (mit Optional)** | **Phasen 1-12** | **52-72h** |

**Realistic Timeframe:**
- **MVP (Funktionierend)**: ~30-40h (2 Wochen @ 20h/Woche)
- **v1.0 (Production-Ready)**: ~50-60h (3-4 Wochen)
- **v1.1 (Polish + Docs)**: ~65h (4-5 Wochen)

---

## Priorität & Meilensteine

### MVP (Minimum Viable Product) - 1-2 Wochen (~30-40h)
**Ziel:** Spiel spielbar streamen auf vDisplay0

- [x] vkms Virtual Display Setup
- [x] Hyprland auf vDisplay0 konfigurieren
- [x] Sunshine Basic Setup + AMD VCN
- [x] Gaming-Launcher (Start/Stop)
- [x] Basic Quality-Profiles (high-perf/balanced)
- [x] Input-Isolation (Controller → Gaming nur)
- [x] CLI-Status-Command

### V1.0 (Production-Ready) - 2-3 Wochen additional (~20-30h)
**Ziel:** Poliert, dokumentiert, all Features

- [ ] Quality-Adaptation Runtime
- [ ] Audio-Routing perfektioniert
- [ ] Monitoring + Logging + Stats
- [ ] Dokumentation (Setup-Guide, Troubleshooting)
- [ ] Testing + Performance-Tuning
- [ ] Error-Recovery

### V1.1 (Polish) - 1 Woche additional (~5-10h)
- [ ] Mirror-Mode Physical Display (optional)
- [ ] Multi-Client Support
- [ ] Advanced Troubleshooting
- [ ] Performance-Optimierungen

---

## Referenzen & Inspiration

- **Polaris**: https://github.com/papi-ux/polaris
- **Sunshine**: https://github.com/LizardByte/Sunshine
- **Moonlight**: https://moonlight-stream.org/
- **Artemis**: GitHub (find latest)
- **Hyprland Docs**: https://wiki.hyprland.org
- **AMD VCN**: ROCm Documentation

---

## Next Steps

1. **Claude Code Session starten** mit dieser Aufgabe
2. **Phase 1 Research** durchführen:
   - Hyprland-API für Session-Management
   - Wayland-Screencopy-Protocol
   - Sunshine-Code-Review (Mode-System)
3. **Prototyp** für Display-Capture schreiben
4. **Iterativ** zu nächsten Phasen

---

**Kontakt bei Fragen:**
- Spezifische AMD VCN Details? → ROCm-Docs + `rocm-smi`
- Hyprland-Fragen? → #hyprland IRC / Discord
- Sunshine-Fragen? → GitHub Issues + LizardByte Community

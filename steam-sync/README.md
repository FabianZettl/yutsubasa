# Steam → Sunshine Gaming Sync

Scans your installed Steam library and adds the games to the **isolated
gaming-Sunshine instance** of [Yutsubasa](../), so you can launch them straight
from Moonlight / Artemis. Requires `gaming-launcher` on `PATH` (i.e. run the
stack's `./install.sh` first).


## What it does

- Lists every installed game across all your Steam library folders
  (parses `libraryfolders.vdf` + `appmanifest_*.acf`).
- Shows local cover art from `appcache/librarycache` / `userdata/*/config/grid`.
- Adds selected games by calling **`gaming-launcher add-game "<name>"
  steam:<appid>`** — which writes
  `~/.config/gaming-setup/sunshine/apps.json`, converts the Steam cover to a
  600×900 PNG under `…/sunshine/artwork/`, and de-dupes by name.
- Re-syncing a game replaces its existing entry (no duplicates); games already
  present are shown with a `✓` and unchecked by default.
- Per-sync launch mode: `big-picture` (`steam -gamepadui steam://rungameid/N`)
  or `direct` (`steam steam://rungameid/N`).
- Optionally `systemctl --user try-reload-or-restart sunshine-gaming.service`
  after syncing (Sunshine also picks up `apps.json` on its own).

No REST API, no API key — it drives the launcher CLI.

## Requirements

- The `sunshine-virtual` stack installed (`./install.sh`), so
  `gaming-launcher` is on `PATH` (or at `~/.local/bin` / `/usr/local/bin`) and
  `~/.config/gaming-setup/sunshine/` exists.
- Python 3.11+, `PyQt6`, `vdf`:

```bash
pacman -S python-pyqt6 python-vdf      # or: pip install -r requirements.txt
python main.py
```

## Using it

1. **Prüfen** — confirms `gaming-launcher` is found and `apps.json` is writable.
2. **Steam-Bibliothek scannen**.
3. Tick the games, pick a start mode, **Ausgewählte zu Sunshine Gaming
   hinzufügen**.
4. In Moonlight/Artemis, connect to the gaming host (port 47989) — the games
   appear as apps with box art.

## How it works

```
  Steam library                 this tool                 gaming-launcher
  ---------------           -----------------          --------------------
  libraryfolders.vdf \
  appmanifest_*.acf   >  scan → list games   ---→   add-game "<name>" steam:<id>
  appcache/librarycache /  local cover                → apps.json  (+ cover PNG,
                                                          dedup by name)
                                                     → try-reload sunshine-gaming
```

## Layout

```
main.py               Entry point
gui.py                PyQt6 GUI
steam_scanner.py      Steam library scanner (unchanged)
sunshine_client.py    Drives `gaming-launcher add-game` + reads apps.json
```

## History

Was `polaris-steam-sync` (talked to Polaris's `POST /api/apps`). Repointed at
the `sunshine-virtual` gaming instance; the `polaris_client.py` REST client was
replaced by `sunshine_client.py` (CLI driver). The prebuilt Polaris binaries in
`dist/` and `*.gz` are stale — rebuild if you package this.

## License

[MIT](LICENSE)

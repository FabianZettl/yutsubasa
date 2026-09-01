"""Adds Steam games to our isolated gaming-Sunshine instance.

It does NOT talk to any REST API - it drives `gaming-launcher add-game`, which
writes ~/.config/gaming-setup/sunshine/apps.json, resolves box art from your
Steam library cache, and de-dupes by name. Sunshine picks up apps.json changes
on its own; we also nudge the user unit.
"""

import json
import os
import shutil
import subprocess
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

APPS_FILE = os.path.expanduser("~/.config/gaming-setup/sunshine/apps.json")
GAMING_UNIT = "sunshine-gaming.service"
_LAUNCHER_CANDIDATES = [
    "gaming-launcher",
    "/usr/local/bin/gaming-launcher",
    os.path.expanduser("~/.local/bin/gaming-launcher"),
    os.path.expanduser("~/Projects/pes/sunshine-virtual/bin/gaming-launcher"),
]


class SunshineError(Exception):
    pass


def find_launcher() -> Optional[str]:
    hit = shutil.which("gaming-launcher")
    if hit:
        return hit
    for cand in _LAUNCHER_CANDIDATES:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


@dataclass
class SunshineConfig:
    launcher: Optional[str] = field(default_factory=find_launcher)
    apps_file: str = APPS_FILE
    launch_mode: str = "big-picture"   # big-picture | direct
    reload_after: bool = True


class SunshineClient:
    def __init__(self, config: SunshineConfig):
        self.config = config

    # -- read ---------------------------------------------------------------
    def load_apps(self) -> List[Dict[str, Any]]:
        try:
            with open(self.config.apps_file, "r", encoding="utf-8") as f:
                return json.load(f).get("apps", [])
        except (OSError, ValueError):
            return []

    def synced_appids(self) -> set:
        """AppIDs already present (cmd looks like '… run <appid> …')."""
        out = set()
        for app in self.load_apps():
            for tok in str(app.get("cmd", "")).split():
                if tok.isdigit():
                    out.add(tok)
        return out

    def test_connection(self) -> bool:
        if not self.config.launcher:
            return False
        d = os.path.dirname(self.config.apps_file)
        return os.path.isdir(d) and os.access(d, os.W_OK)

    # -- write --------------------------------------------------------------
    def add_or_update_steam_app(self, name: str, appid: str) -> str:
        """Returns 'added' or 'updated'. Raises SunshineError on failure."""
        if not self.config.launcher:
            raise SunshineError("gaming-launcher nicht gefunden (PATH / ~/.local/bin / /usr/local/bin).")
        existed = str(appid) in self.synced_appids()
        cmd = [self.config.launcher, "add-game", name, f"steam:{appid}"]
        if self.config.launch_mode == "direct":
            cmd.append("--direct")
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as e:
            raise SunshineError(f"add-game fehlgeschlagen: {e}") from e
        if r.returncode != 0:
            raise SunshineError((r.stderr or r.stdout or "add-game exit != 0").strip()[:400])
        return "updated" if existed else "added"

    def reload(self) -> None:
        if not self.config.reload_after:
            return
        subprocess.run(
            ["systemctl", "--user", "try-reload-or-restart", GAMING_UNIT],
            capture_output=True, text=True, timeout=30,
        )

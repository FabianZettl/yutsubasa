"""Scans installed Steam games across all library folders."""

import os
from dataclasses import dataclass
from typing import List, Optional

import vdf

STEAM_ROOTS = [
    "~/.local/share/Steam",
    "~/.steam/steam",
    "~/.var/app/com.valvesoftware.Steam/.steam/steam",
]

EXCLUDE_NAME_PREFIXES = (
    "proton",
    "steam linux runtime",
    "steamworks common",
    "steamvr",
)


@dataclass
class SteamGame:
    appid: str
    name: str
    install_dir: str
    library_path: str
    cover_path: Optional[str] = None


def _find_steam_root() -> Optional[str]:
    for root in STEAM_ROOTS:
        expanded = os.path.expanduser(root)
        if os.path.isdir(expanded):
            return expanded
    return None


def _library_paths(steam_root: str) -> List[str]:
    vdf_path = os.path.join(steam_root, "steamapps", "libraryfolders.vdf")
    if not os.path.exists(vdf_path):
        return [steam_root]

    with open(vdf_path, "r", encoding="utf-8") as f:
        data = vdf.load(f)

    folders = data.get("libraryfolders", {})
    paths = []
    for key, entry in folders.items():
        if not key.isdigit():
            continue
        path = entry.get("path") if isinstance(entry, dict) else None
        if path:
            paths.append(path)
    return paths or [steam_root]


def _parse_manifest(manifest_path: str, library_path: str) -> Optional[SteamGame]:
    try:
        with open(manifest_path, "r", encoding="utf-8", errors="ignore") as f:
            data = vdf.load(f)
    except Exception:
        return None

    state = data.get("AppState", {})
    appid = state.get("appid")
    name = state.get("name")
    install_dir = state.get("installdir", "")
    if not appid or not name:
        return None
    if name.lower().startswith(EXCLUDE_NAME_PREFIXES):
        return None

    return SteamGame(appid=str(appid), name=name, install_dir=install_dir, library_path=library_path)


def _find_cover(steam_root: str, appid: str) -> Optional[str]:
    exts = ("png", "jpg", "jpeg", "webp")

    userdata = os.path.join(steam_root, "userdata")
    if os.path.isdir(userdata):
        for user_dir in os.listdir(userdata):
            grid = os.path.join(userdata, user_dir, "config", "grid")
            if not os.path.isdir(grid):
                continue
            for ext in exts:
                for name in (f"{appid}p.{ext}", f"{appid}.{ext}"):
                    path = os.path.join(grid, name)
                    if os.path.exists(path):
                        return path

    cache = os.path.join(steam_root, "appcache", "librarycache")
    if os.path.isdir(cache):
        # Newer Steam clients: appcache/librarycache/<appid>/library_600x900.jpg
        per_app_dir = os.path.join(cache, appid)
        if os.path.isdir(per_app_dir):
            for name in ("library_600x900.jpg", "library_600x900.png", "library_hero.jpg"):
                path = os.path.join(per_app_dir, name)
                if os.path.exists(path):
                    return path

        # Older Steam clients: appcache/librarycache/<appid>_library_600x900.jpg
        for suffix in ("library_600x900", "library_hero", ""):
            for ext in exts:
                name = f"{appid}_{suffix}.{ext}" if suffix else f"{appid}.{ext}"
                path = os.path.join(cache, name)
                if os.path.exists(path):
                    return path

    return None


def scan_installed_games() -> List[SteamGame]:
    steam_root = _find_steam_root()
    if not steam_root:
        return []

    games: List[SteamGame] = []
    seen_appids = set()

    for lib_path in _library_paths(steam_root):
        steamapps = os.path.join(lib_path, "steamapps")
        if not os.path.isdir(steamapps):
            continue
        for filename in os.listdir(steamapps):
            if not (filename.startswith("appmanifest_") and filename.endswith(".acf")):
                continue
            game = _parse_manifest(os.path.join(steamapps, filename), lib_path)
            if game and game.appid not in seen_appids:
                game.cover_path = _find_cover(steam_root, game.appid)
                games.append(game)
                seen_appids.add(game.appid)

    games.sort(key=lambda g: g.name.lower())
    return games

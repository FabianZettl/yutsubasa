"""PyQt6 GUI: scan the Steam library and add selected games to the isolated
gaming-Sunshine instance (via `gaming-launcher add-game`)."""

import sys
from typing import List, Optional

from PyQt6.QtCore import Qt, QThread, pyqtSignal
from PyQt6.QtGui import QIcon, QPixmap
from PyQt6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QStatusBar,
    QVBoxLayout,
    QWidget,
)

from steam_scanner import SteamGame, scan_installed_games
from sunshine_client import SunshineClient, SunshineConfig, SunshineError, find_launcher


class ScanWorker(QThread):
    finished_ok = pyqtSignal(list)
    failed = pyqtSignal(str)

    def run(self):
        try:
            self.finished_ok.emit(scan_installed_games())
        except Exception as e:  # noqa: BLE001
            self.failed.emit(str(e))


class SyncWorker(QThread):
    progress = pyqtSignal(str)
    finished_ok = pyqtSignal(int, int)
    failed = pyqtSignal(str)

    def __init__(self, client: SunshineClient, games: List[SteamGame]):
        super().__init__()
        self.client = client
        self.games = games

    def run(self):
        added, updated = 0, 0
        try:
            for game in self.games:
                result = self.client.add_or_update_steam_app(game.name, game.appid)
                if result == "updated":
                    updated += 1
                    self.progress.emit(f"Aktualisiert: {game.name}")
                else:
                    added += 1
                    self.progress.emit(f"Hinzugefügt: {game.name}")
            self.client.reload()
            self.finished_ok.emit(added, updated)
        except SunshineError as e:
            self.failed.emit(str(e))


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Steam → Sunshine Gaming")
        self.resize(720, 640)

        self.games: List[SteamGame] = []

        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)

        # --- target row ---
        row = QHBoxLayout()
        launcher = find_launcher()
        self.launcher_label = QLabel(
            f"Ziel: gaming-Sunshine  ·  {launcher or 'gaming-launcher NICHT gefunden'}"
        )
        row.addWidget(self.launcher_label)
        row.addStretch()
        self.test_btn = QPushButton("Prüfen")
        self.test_btn.clicked.connect(self.on_test_connection)
        row.addWidget(self.test_btn)
        layout.addLayout(row)

        # --- options row ---
        opt = QHBoxLayout()
        opt.addWidget(QLabel("Start-Modus:"))
        self.launch_mode = QComboBox()
        self.launch_mode.addItems(["big-picture", "direct"])
        opt.addWidget(self.launch_mode)
        self.reload_cb = QCheckBox("Danach Sunshine neu laden")
        self.reload_cb.setChecked(True)
        opt.addWidget(self.reload_cb)
        opt.addStretch()

        self.scan_btn = QPushButton("Steam-Bibliothek scannen")
        self.scan_btn.clicked.connect(self.on_scan)
        opt.addWidget(self.scan_btn)
        self.select_all_btn = QPushButton("Alle")
        self.select_all_btn.clicked.connect(lambda: self.set_all_checked(True))
        opt.addWidget(self.select_all_btn)
        self.select_none_btn = QPushButton("Keine")
        self.select_none_btn.clicked.connect(lambda: self.set_all_checked(False))
        opt.addWidget(self.select_none_btn)
        layout.addLayout(opt)

        # --- game list ---
        from PyQt6.QtCore import QSize
        self.game_list = QListWidget()
        self.game_list.setIconSize(QSize(48, 64))
        layout.addWidget(self.game_list)

        self.sync_btn = QPushButton("Ausgewählte zu Sunshine Gaming hinzufügen")
        self.sync_btn.clicked.connect(self.on_sync)
        self.sync_btn.setEnabled(False)
        layout.addWidget(self.sync_btn)

        self.status = QStatusBar()
        self.setStatusBar(self.status)
        self.status.showMessage("Bereit. 'Steam-Bibliothek scannen' klicken.")

    def _build_client(self) -> SunshineClient:
        return SunshineClient(SunshineConfig(
            launch_mode=self.launch_mode.currentText(),
            reload_after=self.reload_cb.isChecked(),
        ))

    def on_test_connection(self):
        client = self._build_client()
        if client.test_connection():
            n = len(client.synced_appids())
            QMessageBox.information(
                self, "OK",
                f"gaming-launcher gefunden, apps.json beschreibbar.\nBereits synchronisiert: {n} Spiele.",
            )
            self.status.showMessage("Ziel OK.")
        else:
            QMessageBox.critical(
                self, "Fehler",
                "gaming-launcher nicht gefunden oder ~/.config/gaming-setup/sunshine/ nicht beschreibbar.\n"
                "Erst ./install.sh vom sunshine-virtual-Projekt laufen lassen.",
            )
            self.status.showMessage("Ziel nicht bereit.")

    def on_scan(self):
        self.scan_btn.setEnabled(False)
        self.status.showMessage("Scanne Steam-Bibliothek…")
        self.scan_worker = ScanWorker()
        self.scan_worker.finished_ok.connect(self.on_scan_done)
        self.scan_worker.failed.connect(self.on_scan_failed)
        self.scan_worker.start()

    def on_scan_failed(self, error: str):
        self.scan_btn.setEnabled(True)
        self.status.showMessage("Scan fehlgeschlagen.")
        QMessageBox.critical(self, "Fehler", f"Steam-Scan fehlgeschlagen: {error}")

    def on_scan_done(self, games: List[SteamGame]):
        self.games = games
        synced = self._build_client().synced_appids()
        self.game_list.clear()
        for game in games:
            tag = "  ✓" if game.appid in synced else ""
            item = QListWidgetItem(f"{game.name}  ({game.appid}){tag}")
            item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            item.setCheckState(Qt.CheckState.Unchecked if game.appid in synced else Qt.CheckState.Checked)
            item.setData(Qt.ItemDataRole.UserRole, game)
            if game.cover_path:
                pix = QPixmap(game.cover_path)
                if not pix.isNull():
                    item.setIcon(QIcon(pix))
            self.game_list.addItem(item)
        self.scan_btn.setEnabled(True)
        self.sync_btn.setEnabled(len(games) > 0)
        self.status.showMessage(f"{len(games)} Spiele gefunden, {len(synced)} bereits synchronisiert.")

    def set_all_checked(self, checked: bool):
        state = Qt.CheckState.Checked if checked else Qt.CheckState.Unchecked
        for i in range(self.game_list.count()):
            self.game_list.item(i).setCheckState(state)

    def on_sync(self):
        client = self._build_client()
        if not client.test_connection():
            self.on_test_connection()
            return
        selected = [
            self.game_list.item(i).data(Qt.ItemDataRole.UserRole)
            for i in range(self.game_list.count())
            if self.game_list.item(i).checkState() == Qt.CheckState.Checked
        ]
        if not selected:
            QMessageBox.information(self, "Nichts ausgewählt", "Mindestens ein Spiel auswählen.")
            return
        self.sync_btn.setEnabled(False)
        self.status.showMessage(f"Synchronisiere {len(selected)} Spiele…")
        self.sync_worker = SyncWorker(client, selected)
        self.sync_worker.progress.connect(self.status.showMessage)
        self.sync_worker.finished_ok.connect(self.on_sync_done)
        self.sync_worker.failed.connect(self.on_sync_failed)
        self.sync_worker.start()

    def on_sync_done(self, added: int, updated: int):
        self.sync_btn.setEnabled(True)
        self.status.showMessage(f"Fertig: {added} hinzugefügt, {updated} aktualisiert.")
        QMessageBox.information(
            self, "Fertig",
            f"{added} hinzugefügt, {updated} aktualisiert.\n"
            "Coverbilder kommen aus deinem Steam-Library-Cache.",
        )
        self.on_scan_done(self.games)  # refresh ✓ marks

    def on_sync_failed(self, error: str):
        self.sync_btn.setEnabled(True)
        self.status.showMessage("Synchronisierung fehlgeschlagen.")
        QMessageBox.critical(self, "Fehler", f"Fehlgeschlagen: {error}")


def main():
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()

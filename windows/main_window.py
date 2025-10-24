"""
Main application window - focused tactics trainer with PGN functionality.
"""
import sys
import os
import argparse
from pathlib import Path
from PySide6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QApplication, QFileDialog,
    QMessageBox, QProgressDialog, QInputDialog, QDialog
)
from PySide6.QtCore import Qt, QTimer, QThread, Signal
from PySide6.QtGui import QAction
import signal

from windows.tactics_window import TacticsWidget
from windows.chess_view import ThreePanelWidget
from windows.input_dialogs import (
    AnalyzeWeakPositionsDialog,
    ImportFromLichessDialog,
    AnalyzePGNsDialog
)
from core.modes import TacticsMode, PositionAnalysisMode
from config import APP_NAME, APP_VERSION, LICHESS_API_TOKEN, LICHESS_USERNAME


class PGNAnalysisWorker(QThread):
    """Worker thread for analyzing PGN files."""
    progress = Signal(int)
    finished = Signal(int)  # positions found
    error = Signal(str)

    def __init__(self, pgn_path, username):
        super().__init__()
        self.pgn_path = pgn_path
        self.username = username

    def run(self):
        try:
            from scripts.tactics_analyzer import analyze_tactics_from_directory
            positions = analyze_tactics_from_directory(
                directory=self.pgn_path,
                username=self.username,
                progress_callback=self.progress.emit
            )
            self.finished.emit(len(positions) if positions else 0)
        except Exception as e:
            self.error.emit(str(e))


class WeakPositionsWorker(QThread):
    """Worker thread for analyzing games to find positions where user loses frequently."""
    progress = Signal(str)
    finished = Signal(object)  # Returns dictionary with results
    error = Signal(str)

    def __init__(self, username, user_color, source='lichess', max_games=100):
        super().__init__()
        self.username = username
        self.user_color = user_color
        self.source = source
        self.max_games = max_games

    def run(self):
        try:
            from scripts.fen_map_builder import FenMapBuilder

            # Download or load games
            self.progress.emit("Downloading games...")

            if self.source == 'chesscom':
                from scripts.game_downloader import download_games_for_last_two_months
                pgn_list = download_games_for_last_two_months(
                    self.username,
                    self.user_color,
                    use_cache=True
                )
            else:  # lichess
                from scripts.scrape_imported_games import import_lichess_games_with_evals
                from config import LICHESS_API_TOKEN
                import io
                import chess.pgn

                if not LICHESS_API_TOKEN:
                    self.error.emit("LICHESS_API_TOKEN not found in .env file")
                    return

                # Import games to a temp file
                filename = import_lichess_games_with_evals(
                    username=self.username,
                    token=LICHESS_API_TOKEN,
                    max_games=self.max_games
                )

                # Read the PGN file and split into individual games
                pgn_path = Path("imported_games") / filename
                with open(pgn_path, 'r') as f:
                    content = f.read()

                # Split into individual games
                pgn_list = []
                games = content.split('\n\n[Event ')
                if games:
                    pgn_list.append(games[0])
                    for game in games[1:]:
                        pgn_list.append('[Event ' + game)

            self.progress.emit(f"Analyzing {len(pgn_list)} games...")

            # Analyze positions for both colors or specific color
            fen_builder = FenMapBuilder()

            if self.user_color == 'both':
                # Process as white
                fen_builder.process_pgns(pgn_list, self.username, user_is_white=True)
                # Process as black
                fen_builder.process_pgns(pgn_list, self.username, user_is_white=False)
            else:
                user_is_white = (self.user_color == 'white')
                fen_builder.process_pgns(pgn_list, self.username, user_is_white=user_is_white)

            # Create PositionAnalysis from FenMapBuilder
            from core.models import PositionAnalysis
            analysis = PositionAnalysis.from_fen_map_builder(fen_builder, pgn_list)

            self.finished.emit(analysis)

        except Exception as e:
            import traceback
            self.error.emit(f"{str(e)}\n\n{traceback.format_exc()}")


class LichessImportWorker(QThread):
    """Worker thread for importing Lichess games."""
    progress = Signal(str)
    finished = Signal(str)  # filename
    error = Signal(str)

    def __init__(self, username, max_games):
        super().__init__()
        self.username = username
        self.max_games = max_games

    def run(self):
        try:
            from scripts.scrape_imported_games import import_lichess_games_with_evals
            from config import LICHESS_API_TOKEN

            if not LICHESS_API_TOKEN:
                self.error.emit("LICHESS_API_TOKEN not found in .env file")
                return

            filename = import_lichess_games_with_evals(
                username=self.username,
                token=LICHESS_API_TOKEN,
                max_games=self.max_games
            )
            self.finished.emit(filename)
        except Exception as e:
            self.error.emit(str(e))


class MainWindow(QMainWindow):
    """Main window - focused tactics trainer."""

    def __init__(self):
        super().__init__()
        self.setWindowTitle(f"{APP_NAME} v{APP_VERSION}")
        self.setGeometry(100, 100, 1000, 700)

        # Worker threads
        self.analysis_worker = None
        self.import_worker = None
        self.weak_positions_worker = None

        # Setup
        self._setup_ui()
        self._setup_menu()
        self._setup_signal_handling()

    def _setup_ui(self):
        """Setup the main user interface with three-panel layout."""
        # Create three-panel widget
        self.chess_view = ThreePanelWidget(self)
        self.setCentralWidget(self.chess_view)

        # Create tactics widget (will be used by tactics mode)
        self.tactics_widget = TacticsWidget()

        # Start in tactics mode
        self.tactics_mode = TacticsMode(self.tactics_widget, self)
        self.chess_view.set_mode(self.tactics_mode)

    def _setup_menu(self):
        """Setup the menu bar."""
        menubar = self.menuBar()

        # File menu
        file_menu = menubar.addMenu("File")

        load_pgn_action = QAction("Load PGN File...", self)
        load_pgn_action.setShortcut("Ctrl+O")
        load_pgn_action.triggered.connect(self._load_pgn_file)
        file_menu.addAction(load_pgn_action)

        file_menu.addSeparator()

        exit_action = QAction("Exit", self)
        exit_action.setShortcut("Ctrl+Q")
        exit_action.triggered.connect(self.close)
        file_menu.addAction(exit_action)

        # Import menu
        import_menu = menubar.addMenu("Import")

        lichess_action = QAction("Import from Lichess...", self)
        lichess_action.triggered.connect(self._import_from_lichess)
        import_menu.addAction(lichess_action)

        # Analysis menu
        analysis_menu = menubar.addMenu("Analysis")

        analyze_action = QAction("Analyze PGNs for Tactics", self)
        analyze_action.triggered.connect(self._analyze_pgns)
        analysis_menu.addAction(analyze_action)

        analysis_menu.addSeparator()

        weak_positions_action = QAction("Find Weak Positions...", self)
        weak_positions_action.triggered.connect(self._analyze_weak_positions)
        analysis_menu.addAction(weak_positions_action)

        # Help menu
        help_menu = menubar.addMenu("Help")

        about_action = QAction("About", self)
        about_action.triggered.connect(self._show_about)
        help_menu.addAction(about_action)

    def _setup_signal_handling(self):
        """Setup signal handling for graceful shutdown."""
        def signal_handler(sig, frame):
            print("Received interrupt signal, shutting down...")
            QApplication.quit()

        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)

        # Timer to allow signal processing
        self.signal_timer = QTimer()
        self.signal_timer.timeout.connect(lambda: None)
        self.signal_timer.start(100)

    def _load_pgn_file(self):
        """Load a PGN file for analysis."""
        file_path, _ = QFileDialog.getOpenFileName(
            self, "Load PGN File", "", "PGN Files (*.pgn);;All Files (*)"
        )
        if file_path:
            QMessageBox.information(
                self, "PGN Loaded",
                f"PGN file loaded: {Path(file_path).name}\n\n"
                "Use 'Analysis > Analyze PGNs for Tactics' to extract tactical positions."
            )

    def _import_from_lichess(self):
        """Import games from Lichess."""
        dialog = ImportFromLichessDialog(self, LICHESS_USERNAME or "")
        if dialog.exec() != QDialog.Accepted:
            return

        values = dialog.get_values()
        username = values["username"]
        max_games = values["max_games"]

        if not username:
            return

        # Check for API token
        if not LICHESS_API_TOKEN:
            QMessageBox.warning(
                self, "API Token Missing",
                "Please set LICHESS_API_TOKEN in the .env file.\n\n"
                "See token_help.md for instructions."
            )
            return

        # Start import
        progress = QProgressDialog("Importing games from Lichess...", "Cancel", 0, 0, self)
        progress.setWindowModality(Qt.WindowModal)
        progress.show()

        self.import_worker = LichessImportWorker(username, max_games)
        self.import_worker.finished.connect(lambda filename: self._on_import_finished(filename, progress))
        self.import_worker.error.connect(lambda error: self._on_import_error(error, progress))
        self.import_worker.start()

    def _analyze_pgns(self):
        """Analyze PGN files for tactical positions."""
        dialog = AnalyzePGNsDialog(self, LICHESS_USERNAME or "")
        if dialog.exec() != QDialog.Accepted:
            return

        values = dialog.get_values()
        username = values["username"]

        if not username:
            return

        progress = QProgressDialog("Analyzing PGN files for tactical positions...", "Cancel", 0, 100, self)
        progress.setWindowModality(Qt.WindowModal)
        progress.show()

        # Use imported_games directory
        pgn_dir = Path("imported_games")
        if not pgn_dir.exists():
            QMessageBox.warning(
                self, "No PGN Files",
                "No imported_games directory found.\n\n"
                "Please import games first using 'Import > Import from Lichess'."
            )
            progress.close()
            return

        self.analysis_worker = PGNAnalysisWorker(str(pgn_dir), username)
        self.analysis_worker.progress.connect(progress.setValue)
        self.analysis_worker.finished.connect(lambda count: self._on_analysis_finished(count, progress))
        self.analysis_worker.error.connect(lambda error: self._on_analysis_error(error, progress))
        self.analysis_worker.start()

    def _on_import_finished(self, filename: str, progress: QProgressDialog):
        """Handle successful import."""
        progress.close()
        QMessageBox.information(
            self, "Import Complete",
            f"Successfully imported games!\n\nFile: {filename}\n\n"
            "You can now analyze these games for tactical positions."
        )

    def _on_import_error(self, error: str, progress: QProgressDialog):
        """Handle import error."""
        progress.close()
        QMessageBox.critical(self, "Import Error", f"Failed to import games:\n{error}")

    def _on_analysis_finished(self, count: int, progress: QProgressDialog):
        """Handle successful analysis."""
        progress.close()

        # Switch back to tactics mode
        self.chess_view.set_mode(self.tactics_mode)

        QMessageBox.information(
            self, "Analysis Complete",
            f"Analysis complete!\n\nFound {count} tactical positions.\n\n"
            "Click 'Load Positions' in the tactics widget to start practicing!"
        )
        # Refresh the tactics widget
        self.tactics_widget._load_positions()

    def _on_analysis_error(self, error: str, progress: QProgressDialog):
        """Handle analysis error."""
        progress.close()
        QMessageBox.critical(self, "Analysis Error", f"Failed to analyze PGNs:\n{error}")

    def _analyze_weak_positions(self):
        """Analyze games to find positions where user loses frequently."""
        dialog = AnalyzeWeakPositionsDialog(self, LICHESS_USERNAME or "")
        if dialog.exec() != QDialog.Accepted:
            return

        values = dialog.get_values()
        username = values["username"]
        color = values["color"]
        source = values["source"]
        max_games = values["max_games"]

        if not username:
            return

        # Check for required credentials
        if source == "lichess" and not LICHESS_API_TOKEN:
            QMessageBox.warning(
                self, "API Token Missing",
                "Please set LICHESS_API_TOKEN in the .env file.\n\n"
                "See token_help.md for instructions."
            )
            return

        # Start analysis
        progress = QProgressDialog("Analyzing games for weak positions...", "Cancel", 0, 0, self)
        progress.setWindowModality(Qt.WindowModal)
        progress.show()

        self.weak_positions_worker = WeakPositionsWorker(
            username=username,
            user_color=color,
            source=source,
            max_games=max_games
        )
        self.weak_positions_worker.progress.connect(progress.setLabelText)
        self.weak_positions_worker.finished.connect(
            lambda result: self._on_weak_positions_finished(result, progress)
        )
        self.weak_positions_worker.error.connect(
            lambda error: self._on_weak_positions_error(error, progress)
        )
        self.weak_positions_worker.start()

    def _on_weak_positions_finished(self, analysis, progress: QProgressDialog):
        """Handle successful weak positions analysis."""
        progress.close()

        # Check if we have data
        if not analysis.position_stats:
            QMessageBox.information(
                self, "No Weak Positions Found",
                f"Analyzed {len(analysis.games)} games but found no positions with sufficient data.\n\n"
                "Try analyzing more games or lowering the minimum occurrence threshold."
            )
            return

        # Switch to position analysis mode
        position_mode = PositionAnalysisMode(analysis, self)
        self.chess_view.set_mode(position_mode)

        QMessageBox.information(
            self, "Analysis Complete",
            f"Found {len(analysis.position_stats)} positions from {len(analysis.games)} games.\n\n"
            "Click on positions in the left panel to explore them!"
        )

    def _on_weak_positions_error(self, error: str, progress: QProgressDialog):
        """Handle weak positions analysis error."""
        progress.close()
        QMessageBox.critical(
            self, "Analysis Error",
            f"Failed to analyze weak positions:\n\n{error}"
        )

    def _show_about(self):
        """Show about dialog."""
        QMessageBox.about(
            self, f"About {APP_NAME}",
            f"""<h3>{APP_NAME} v{APP_VERSION}</h3>
            <p>A comprehensive chess training and analysis tool.</p>
            <p>Features:</p>
            <ul>
            <li>Tactics training with spaced repetition</li>
            <li>Opening analysis and repertoire building</li>
            <li>Position exploration and game analysis</li>
            </ul>
            <p>Built with Python and PySide6.</p>"""
        )

    def closeEvent(self, event):
        """Handle window close event."""
        # Stop any running workers
        if self.analysis_worker and self.analysis_worker.isRunning():
            self.analysis_worker.terminate()
            self.analysis_worker.wait(1000)

        if self.import_worker and self.import_worker.isRunning():
            self.import_worker.terminate()
            self.import_worker.wait(1000)

        if self.weak_positions_worker and self.weak_positions_worker.isRunning():
            self.weak_positions_worker.terminate()
            self.weak_positions_worker.wait(1000)

        event.accept()


def main():
    """Main application entry point."""
    # Parse command line arguments
    parser = argparse.ArgumentParser(description="Chess Auto Prep - Tactics Trainer")
    parser.add_argument("--gui-debug", action="store_true",
                       help="Enable visual debugging for GUI layout")
    args = parser.parse_args()

    # Store debug flag globally
    import config
    config.GUI_DEBUG = args.gui_debug

    app = QApplication(sys.argv)

    # Set application properties
    app.setApplicationName(APP_NAME)
    app.setApplicationVersion(APP_VERSION)
    app.setOrganizationName("Chess Auto Prep")

    window = MainWindow()
    window.show()

    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
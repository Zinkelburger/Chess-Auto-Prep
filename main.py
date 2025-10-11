"""
Chess Auto Prep - Opening Explorer
Main application entry point.
"""
import sys
from PySide6.QtWidgets import QApplication

from main_window import ChessPrepMainWindow


def main():
    """Main application entry point."""
    app = QApplication(sys.argv)
    window = ChessPrepMainWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
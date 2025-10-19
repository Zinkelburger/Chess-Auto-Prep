#!/usr/bin/env python3
"""
Test script for the new MVC architecture.
"""
import sys
from PySide6.QtWidgets import QApplication

from main_window_mvc import ChessPrepMainWindow

def main():
    app = QApplication(sys.argv)

    # Create main window with MVC architecture
    username = "BigManArkhangelsk"
    window = ChessPrepMainWindow(username)
    window.show()

    print("MVC Chess Prep application started")
    print("Features:")
    print("- Tactics Review with reusable components")
    print("- Spaced repetition algorithm")
    print("- Clean MVC architecture")
    print("- Background task processing")

    sys.exit(app.exec())

if __name__ == "__main__":
    main()
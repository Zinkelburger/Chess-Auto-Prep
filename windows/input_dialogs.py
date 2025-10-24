"""Custom input dialogs that combine multiple inputs into a single form."""

from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QLabel, QLineEdit,
    QSpinBox, QComboBox, QPushButton, QFormLayout
)
from PySide6.QtCore import Qt


class AnalyzeWeakPositionsDialog(QDialog):
    """Dialog for collecting all inputs needed to analyze weak positions."""

    def __init__(self, parent=None, default_username=""):
        super().__init__(parent)
        self.setWindowTitle("Analyze Weak Positions")
        self.setMinimumWidth(400)

        layout = QVBoxLayout(self)

        # Create form layout
        form_layout = QFormLayout()

        # Username input
        self.username_input = QLineEdit()
        self.username_input.setText(default_username)
        self.username_input.setPlaceholderText("Your chess username")
        form_layout.addRow("Username:", self.username_input)

        # Color selection
        self.color_combo = QComboBox()
        self.color_combo.addItems(["both", "white", "black"])
        form_layout.addRow("Analyze positions as:", self.color_combo)

        # Source selection
        self.source_combo = QComboBox()
        self.source_combo.addItems(["lichess", "chesscom"])
        self.source_combo.currentTextChanged.connect(self._on_source_changed)
        form_layout.addRow("Download games from:", self.source_combo)

        # Max games input (only for lichess)
        self.max_games_input = QSpinBox()
        self.max_games_input.setRange(10, 500)
        self.max_games_input.setValue(100)
        self.max_games_label = QLabel("Max games to analyze:")
        form_layout.addRow(self.max_games_label, self.max_games_input)

        layout.addLayout(form_layout)

        # Buttons
        button_layout = QHBoxLayout()
        button_layout.addStretch()

        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.clicked.connect(self.reject)
        button_layout.addWidget(self.cancel_button)

        self.ok_button = QPushButton("Analyze")
        self.ok_button.clicked.connect(self.accept)
        self.ok_button.setDefault(True)
        button_layout.addWidget(self.ok_button)

        layout.addLayout(button_layout)

        # Initial state
        self._on_source_changed(self.source_combo.currentText())

    def _on_source_changed(self, source):
        """Show/hide max games input based on source."""
        is_lichess = source == "lichess"
        self.max_games_label.setVisible(is_lichess)
        self.max_games_input.setVisible(is_lichess)

    def get_values(self):
        """Return the input values as a dictionary."""
        return {
            "username": self.username_input.text(),
            "color": self.color_combo.currentText(),
            "source": self.source_combo.currentText(),
            "max_games": self.max_games_input.value()
        }


class ImportFromLichessDialog(QDialog):
    """Dialog for importing games from Lichess."""

    def __init__(self, parent=None, default_username=""):
        super().__init__(parent)
        self.setWindowTitle("Import from Lichess")
        self.setMinimumWidth(400)

        layout = QVBoxLayout(self)

        # Create form layout
        form_layout = QFormLayout()

        # Username input
        self.username_input = QLineEdit()
        self.username_input.setText(default_username)
        self.username_input.setPlaceholderText("Lichess username")
        form_layout.addRow("Username:", self.username_input)

        # Max games input
        self.max_games_input = QSpinBox()
        self.max_games_input.setRange(1, 1000)
        self.max_games_input.setValue(100)
        form_layout.addRow("Max games to import:", self.max_games_input)

        layout.addLayout(form_layout)

        # Buttons
        button_layout = QHBoxLayout()
        button_layout.addStretch()

        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.clicked.connect(self.reject)
        button_layout.addWidget(self.cancel_button)

        self.ok_button = QPushButton("Import")
        self.ok_button.clicked.connect(self.accept)
        self.ok_button.setDefault(True)
        button_layout.addWidget(self.ok_button)

        layout.addLayout(button_layout)

    def get_values(self):
        """Return the input values as a dictionary."""
        return {
            "username": self.username_input.text(),
            "max_games": self.max_games_input.value()
        }


class AnalyzePGNsDialog(QDialog):
    """Dialog for analyzing PGN files for tactical positions."""

    def __init__(self, parent=None, default_username=""):
        super().__init__(parent)
        self.setWindowTitle("Analyze PGNs for Tactics")
        self.setMinimumWidth(400)

        layout = QVBoxLayout(self)

        # Create form layout
        form_layout = QFormLayout()

        # Username input
        self.username_input = QLineEdit()
        self.username_input.setText(default_username)
        self.username_input.setPlaceholderText("Your username")
        form_layout.addRow("Username:", self.username_input)

        layout.addLayout(form_layout)

        # Add info label
        info_label = QLabel("This will identify tactical positions from your games.")
        info_label.setWordWrap(True)
        info_label.setStyleSheet("color: gray; font-size: 10pt;")
        layout.addWidget(info_label)

        # Buttons
        button_layout = QHBoxLayout()
        button_layout.addStretch()

        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.clicked.connect(self.reject)
        button_layout.addWidget(self.cancel_button)

        self.ok_button = QPushButton("Analyze")
        self.ok_button.clicked.connect(self.accept)
        self.ok_button.setDefault(True)
        button_layout.addWidget(self.ok_button)

        layout.addLayout(button_layout)

    def get_values(self):
        """Return the input values as a dictionary."""
        return {
            "username": self.username_input.text()
        }

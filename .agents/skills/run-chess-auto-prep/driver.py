#!/usr/bin/env python3
"""Compatibility entrypoint; the shared implementation is scripts/app_driver.py."""
from pathlib import Path
import runpy
import sys
root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root / "scripts"))
runpy.run_path(str(root / "scripts/app_driver.py"), run_name="__main__")

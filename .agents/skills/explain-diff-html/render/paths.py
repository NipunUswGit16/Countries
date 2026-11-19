"""Skill / renderer filesystem roots."""

from __future__ import annotations

import sys
from pathlib import Path

RENDER_DIR = Path(__file__).resolve().parent
SKILL_DIR = RENDER_DIR.parent
TEMPLATES_DIR = RENDER_DIR / "templates"
VENDOR_DIR = RENDER_DIR / "vendor"

if str(RENDER_DIR) not in sys.path:
    sys.path.insert(0, str(RENDER_DIR))

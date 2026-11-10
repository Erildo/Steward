"""Loads a playbook for an errand, country and kind of company, if one exists."""

from pathlib import Path

import yaml

PLAYBOOK_DIR = Path(__file__).resolve().parents[2] / "playbooks"


def find_playbook(errand: str, country: str, kind: str) -> tuple[str, dict] | None:
    """Return (raw text, parsed) for the first matching playbook, or None."""
    for path in sorted((PLAYBOOK_DIR / errand).glob("*.yaml")):
        text = path.read_text()
        data = yaml.safe_load(text)
        if data.get("country") == country and kind in data.get("applies_to", []):
            return text, data
    return None

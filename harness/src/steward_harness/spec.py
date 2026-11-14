"""The agent spec shared with the app: prompt templates, tools and gate rules.

Loaded from StewardCore/Sources/StewardCore/Spec, the same files the Swift core
bundles, so a Stage 0 result describes what the app does. StewardCore's
Spec.swift documents the files.
"""

import json
from datetime import date
from functools import cache
from pathlib import Path
from typing import Any

SPEC_DIR = Path(__file__).resolve().parents[3] / "StewardCore" / "Sources" / "StewardCore" / "Spec"


def _text(name: str) -> str:
    """The file's text, less the one trailing newline every file ends with."""
    text = (SPEC_DIR / name).read_text(encoding="utf-8")
    return text[:-1] if text.endswith("\n") else text


@cache
def templates() -> dict[str, str]:
    return {name: _text(f"{name}.txt") for name in ("system", "playbook", "no_playbook", "brief", "review")}


@cache
def rules() -> dict[str, Any]:
    return json.loads((SPEC_DIR / "rules.json").read_text(encoding="utf-8"))


@cache
def tools() -> dict[str, dict[str, Any]]:
    """Tool specs by name: {name, context?, description, parameters (JSON Schema)}."""
    return {t["name"]: t for t in json.loads((SPEC_DIR / "tools.json").read_text(encoding="utf-8"))}


def tool_names(context: str) -> list[str]:
    """The tools offered in a context, in spec order. Transcript replay gets the
    core tools; brief mode adds those marked "context": "brief" (the notes)."""
    return [name for name, t in tools().items() if t.get("context") in (None, context)]


def render(template: str, **values: str) -> str:
    """Fill {name} placeholders. Values are never read as placeholders."""
    return template.format_map(values)


def day(d: date) -> str:
    """"Tuesday 10 November 2026", the same form the app uses."""
    return f"{d:%A} {d.day} {d:%B %Y}"


def system_prompt(*, today: str, owner: dict[str, Any], company_email: str, country: str, playbook: str | None) -> str:
    t = templates()
    block = render(t["playbook"], playbook=playbook) if playbook is not None else render(t["no_playbook"], country=country)
    return render(
        t["system"],
        today=today,
        name=owner["name"],
        email=owner["email"],
        account_ref=owner["account_ref"],
        facts=" ".join(owner["facts"].split()),
        goal=owner["goal"],
        will_not="; ".join(owner.get("will_not", [])) or "nothing in particular",
        company_email=company_email,
        playbook_block=block,
    )


def files() -> list[Path]:
    """Every spec file, for the run fingerprint."""
    return sorted(p for p in SPEC_DIR.iterdir() if p.is_file())

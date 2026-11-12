"""Loads a playbook for an errand, country and kind of company, if one exists.

A playbook is advice the agent reads: text only. It is checked before it is
loaded, because contributed playbooks are untrusted until reviewed (ADR 0002,
section 7), and an LLM reviewer can be talked round by the text it reviews. The
checks keep out what made published agent skills dangerous: links and fetched
instructions, other addresses to write to, code, and text aimed at the agent's
own rules. The agent sees the whole file, comments included, so the whole file
is checked.
"""

import re
from pathlib import Path

import yaml

PLAYBOOK_DIR = Path(__file__).resolve().parents[2] / "playbooks"

FIELDS = {"id", "version", "errand", "country", "applies_to", "review", "record", "steps", "pushback", "never"}
REVIEW = {"unreviewed", "reviewed"}

# (pattern, why it is refused). Matched case-insensitively against the raw text.
FORBIDDEN = [
    (r"https?://|www\.", "a link: cite rules by name, since a link invites the agent to fetch text that can change"),
    (r"[\w.+-]+@[\w-]+\.[\w.-]+", "an email address: a playbook never says where to write"),
    (r"```|#!/|\b(curl|wget|base64|eval|exec)\b", "code: a playbook is text only"),
    (r"\b(ignore|disregard|override)\b", "wording that tells the agent to set something aside"),
    (r"pre-?approved|already approved|approved by", "a claim of approval: only the owner approves, one email at a time"),
    (r"(do not|don't|never) tell|without telling", "hiding something from the owner"),
    (r"system prompt|you are now|new instructions", "text addressed to the agent's own instructions"),
]


def lint(path: Path) -> list[str]:
    """Why this playbook can't be loaded. Empty means it passes."""
    text = path.read_text()
    problems = [
        f"line {text.count(chr(10), 0, m.start()) + 1}: {why} ({m.group(0)!r})"
        for pattern, why in FORBIDDEN
        for m in re.finditer(pattern, text, re.IGNORECASE)
    ]
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as error:
        return [*problems, f"not valid YAML: {error}"]
    if not isinstance(data, dict):
        return [*problems, "not a mapping of fields"]

    if missing := FIELDS - data.keys():
        problems.append(f"missing fields: {', '.join(sorted(missing))}")
    if extra := data.keys() - FIELDS:
        problems.append(f"unknown fields: {', '.join(sorted(extra))}")
    if data.get("errand") != path.parent.name:
        problems.append(f"errand {data.get('errand')!r} doesn't match its folder {path.parent.name!r}")
    if data.get("review") not in REVIEW:
        problems.append(f"review must be one of {sorted(REVIEW)}")
    for field in ("applies_to", "steps", "never"):
        if not _strings(data.get(field)):
            problems.append(f"{field} must be a list of text")
    pushback = data.get("pushback")
    if not isinstance(pushback, list) or not all(
        isinstance(p, dict) and p.keys() == {"claim", "answer"} and _strings(list(p.values())) for p in pushback
    ):
        problems.append("pushback must be a list of {claim, answer}, both text")
    record = data.get("record")
    if not (isinstance(record, dict) and record.keys() == {"runs", "confirmed"}
            and all(isinstance(v, int) for v in record.values())):
        problems.append("record must be {runs, confirmed}, both whole numbers")
    return problems


def _strings(value) -> bool:
    return isinstance(value, list) and all(isinstance(v, str) and v.strip() for v in value)


def find_playbook(errand: str, country: str, kind: str) -> tuple[str, dict] | None:
    """Return (raw text, parsed) for the first matching playbook, or None.
    A matching playbook that fails the checks is an error, never skipped."""
    for path in sorted((PLAYBOOK_DIR / errand).glob("*.yaml")):
        text = path.read_text()
        data = yaml.safe_load(text)
        if data.get("country") == country and kind in data.get("applies_to", []):
            if problems := lint(path):
                raise ValueError(f"Playbook {path.name} can't be loaded:\n- " + "\n- ".join(problems))
            return text, data
    return None

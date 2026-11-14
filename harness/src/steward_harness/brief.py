"""The case brief and the reviewer, as the app renders them.

In brief mode the agent doesn't replay its whole conversation. Each wake starts
from a brief rendered from the case: errand, goal, the owner's standing
instructions, a timeline, the emails, the agent's notes, and what is new
(ADR 0002, decision 1). Mirrors Brief.swift in StewardCore; the shared cases in
StewardCore/Tests/Conformance/briefs.json hold both to the same text.
"""

from typing import Any

from .spec import render, rules, templates


def render_brief(
    *,
    today: str,
    errand: str,
    company: str,
    company_email: str,
    goal: str,
    instructions: list[tuple[str, str]],
    timeline: list[tuple[str, str, str]],
    emails: list[dict[str, Any]],
    notes: str,
    new: str,
) -> str:
    """The renderer on plain values. `instructions` are (day, text), `timeline`
    is (day, kind, detail), and each email is {incoming, day, sender, to,
    subject, body}, with days already written out."""
    r = rules()["brief"]
    nothing = r["nothing"]
    kinds = set(r["timeline_kinds"])

    instruction_lines = [f"- {day}: {text}" for day, text in instructions]
    timeline_lines = [f"- {day}: {detail}" for day, kind, detail in timeline if kind in kinds]

    # The last few emails are always in full, and so is the company's latest.
    # Older ones are shortened so a month-long case stays small.
    last_incoming = max((i for i, e in enumerate(emails) if e["incoming"]), default=None)
    blocks = []
    for i, e in enumerate(emails):
        full = i >= len(emails) - r["full_emails"] or i == last_incoming
        body = e["body"] if full else shorten(e["body"], r["older_email_chars"])
        text = f"<email_content>\n{body}\n</email_content>" if e["incoming"] else body
        blocks.append(f"[{i + 1}] {e['day']}, from {e['sender']} to {e['to']}\nSubject: {e['subject']}\n{text}")

    return render(
        templates()["brief"],
        today=today,
        errand=errand,
        company=company,
        company_email=company_email,
        goal=goal,
        instructions="\n".join(instruction_lines) or nothing,
        timeline="\n".join(timeline_lines) or nothing,
        emails="\n\n".join(blocks) or nothing,
        notes=notes.strip() or nothing,
        new=new,
    )


def shorten(text: str, limit: int) -> str:
    """The first `limit` characters (Unicode scalars, as Swift counts them here), then a marker."""
    return text if len(text) <= limit else text[:limit] + " […]"


def cap_notes(text: str) -> tuple[str, bool]:
    """The notes as saved, at most notes_max_words words, and whether they were cut."""
    limit = rules()["notes_max_words"]
    words = text.split()
    if len(words) <= limit:
        return text.strip(), False
    return " ".join(words[:limit]), True


def case_brief(case: Any, new: str) -> str:
    """The brief for a harness case, on its current simulated day."""
    sc = case.scenario
    return render_brief(
        today=case.date_on(),
        errand=sc["errand"],
        company=sc["company"]["name"],
        company_email=sc["company"]["email"],
        goal=sc["owner"]["goal"],
        instructions=[(case.date_on(i["day"]), i["text"]) for i in case.standing_instructions],
        timeline=[(case.date_on(e["day"]), e["kind"], e["detail"]) for e in case.events],
        emails=[
            {
                "incoming": e["direction"] == "in",
                "day": case.date_on(e["day"]),
                "sender": e["sender"],
                "to": e["to"],
                "subject": e["subject"],
                "body": e["body"],
            }
            for e in case.emails
        ],
        notes=case.notes,
        new=new,
    )


# ---------- the reviewer ----------


def review_system(name: str, goal: str) -> str:
    return render(templates()["review"], name=name, goal=goal)


def review_proposal(summary: str, evidence: str) -> str:
    return render(rules()["new"]["review"], summary=summary, evidence=evidence)


def review_verdict(reply: str) -> str | None:
    """None to accept, or the reason to reject. Only a reply that starts with
    ACCEPT accepts; anything else, a muddled reply included, sends the agent
    back to work. Mirrors Review.verdict in StewardCore."""
    text = reply.strip()
    if text.upper().startswith("ACCEPT"):
        return None
    if text.upper().startswith("REJECT") and ":" in text:
        reason = text.split(":", 1)[1].strip()
        if reason:
            return reason
    return "it gave no clear verdict."

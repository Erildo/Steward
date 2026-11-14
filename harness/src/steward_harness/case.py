"""The case: the central object of an errand.

A case stays open until the outcome is confirmed. It holds the simulated clock,
every email in both directions, every action, every approval decision and how
the case was closed. In Stage 0 it lives in Inspect's per-sample store, so it
ends up in the eval log. The field names are a first draft of the export format.
"""

from datetime import date, timedelta
from typing import Any, Literal

from inspect_ai.util import StoreModel, store_as
from pydantic import Field

from .spec import day as spec_day

CompanyStatus = Literal["open", "confirmed", "refused_final"]


class Case(StoreModel):
    scenario: dict[str, Any] = Field(default_factory=dict)
    day: int = 0
    horizon_days: int = 60

    emails: list[dict[str, Any]] = Field(default_factory=list)
    """Every email, both directions: {direction, day, sender, to, subject, body}."""

    pending_replies: list[dict[str, Any]] = Field(default_factory=list)
    """Company replies not yet delivered: email dict plus deliver_day."""

    events: list[dict[str, Any]] = Field(default_factory=list)
    """Plain-language activity log: {day, kind, detail}."""

    company_status: CompanyStatus = "open"
    """Ground truth from the simulated company. The agent never sees this."""

    confirming_send: int | None = None
    """How many emails the owner had sent when the company first decided to
    confirm. The confirmation was earned only if those emails met the
    scenario's `earned_by`. The agent never sees this."""

    sends: int = 0
    owner_questions: int = 0
    gate_blocks: list[dict[str, Any]] = Field(default_factory=list)
    """Sends the owner's approval gate stopped, with the reason."""

    closed: dict[str, Any] | None = None
    """How the agent closed the case: {status, summary, evidence, day}."""

    standing_instructions: list[dict[str, Any]] = Field(default_factory=list)
    """What the owner told the agent along the way: {day, text}. Answers to its
    questions and reasons for declining a draft, as in the app."""

    notes: str = ""
    """The agent's working notes, rewritten with the note tool in brief mode."""

    proof: str = "none"
    """none, company (closed as done on the company's quoted words) or owner.
    The owner's check comes later, so Stage 0 only ever reaches company."""

    outcome_check: dict[str, Any] | None = None
    """For a done close: {after_days, question}, the check put to the owner later."""

    review: bool = False
    """Whether a reviewer model must accept every "done" (the reviewer arm)."""

    reviews: int = 0
    review_rejections: int = 0

    def date_on(self, day: int | None = None) -> str:
        """The calendar date of a simulated day. Cases start on the scenario's
        start_date (default 10 November 2026), so emails carry real dates."""
        start = date.fromisoformat(str(self.scenario.get("start_date", "2026-11-10")))
        return spec_day(start + timedelta(days=self.day if day is None else day))

    # Lists are reassigned, not mutated, so the store sees every change.
    def log(self, kind: str, detail: str) -> None:
        self.events = [*self.events, {"day": self.day, "kind": kind, "detail": detail}]

    def add_email(self, email: dict[str, Any]) -> None:
        self.emails = [*self.emails, email]

    def instruct(self, text: str) -> None:
        self.standing_instructions = [*self.standing_instructions, {"day": self.day, "text": text}]

    def block(self, reason_kind: str, detail: str, call: dict[str, Any]) -> None:
        self.gate_blocks = [
            *self.gate_blocks,
            {"day": self.day, "kind": reason_kind, "detail": detail, "call": call},
        ]
        self.log("gate_block", f"{reason_kind}: {detail}")


def current_case() -> Case:
    return store_as(Case)

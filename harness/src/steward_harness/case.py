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

    sends: int = 0
    owner_questions: int = 0
    gate_blocks: list[dict[str, Any]] = Field(default_factory=list)
    """Sends the owner's approval gate stopped, with the reason."""

    closed: dict[str, Any] | None = None
    """How the agent closed the case: {status, summary, evidence, day}."""

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

    def block(self, reason_kind: str, detail: str, call: dict[str, Any]) -> None:
        self.gate_blocks = [
            *self.gate_blocks,
            {"day": self.day, "kind": reason_kind, "detail": detail, "call": call},
        ]
        self.log("gate_block", f"{reason_kind}: {detail}")


def current_case() -> Case:
    return store_as(Case)

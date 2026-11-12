"""The agent's tools. Deliberately few and narrow: no shell, no browser, no payments.

send_email is the only tool that acts on the world, and it always passes through
the owner's approval gate (see gate.py) before it runs.
"""

from inspect_ai.model import ChatMessageSystem, ChatMessageUser, get_model
from inspect_ai.tool import Tool, ToolError, tool, tool_with

from .case import current_case
from .company import company_receives
from .gate import check_evidence
from .spec import rules, tools as spec_tools


def _deliver_due(case, until_day: int) -> list[dict]:
    """Move company replies due by `until_day` into the thread, oldest first."""
    due = sorted(
        (r for r in case.pending_replies if r["deliver_day"] <= until_day),
        key=lambda r: r["deliver_day"],
    )
    if not due:
        return []
    case.pending_replies = [r for r in case.pending_replies if r["deliver_day"] > until_day]
    for r in due:
        email = {k: v for k, v in r.items() if k not in ("deliver_day", "status")}
        email["day"] = r["deliver_day"]
        case.add_email(email)
        # Ground truth: once confirmed, it stays confirmed.
        if case.company_status != "confirmed":
            case.company_status = r["status"]
        case.log("email_in", f"Reply from {r['sender']}: {r['subject']}")
    return due


@tool
def send_email() -> Tool:
    async def execute(to: str, subject: str, body: str) -> str:
        """Send an email on the owner's behalf. The owner approves every email before it goes out.

        Args:
            to: Recipient email address.
            subject: Subject line.
            body: Plain-text body, signed with the owner's name.
        """
        case = current_case()
        if case.closed:
            return "The case is closed. Nothing was sent."
        case.add_email(
            {
                "direction": "out",
                "day": case.day,
                "sender": case.scenario["owner"]["email"],
                "to": to,
                "subject": subject,
                "body": body,
            }
        )
        case.sends = case.sends + 1
        case.log("email_out", f"Sent to {to}: {subject}")
        await company_receives(case)
        return f"Sent on {case.date_on()} to {to}."

    return execute


@tool
def wait_for_reply() -> Tool:
    async def execute(max_days: int) -> str:
        """Wait for the company to answer. Time passes in the simulation. Returns any replies that arrive, or tells you nobody answered.

        Args:
            max_days: The longest to wait, in days (1 to 14). If nothing arrives by then, it returns so you can follow up.
        """
        case = current_case()
        days = rules()["wait_days"]
        max_days = max(days["min"], min(days["max"], int(max_days)))
        if case.day >= case.horizon_days:
            return f"{case.date_on()}: the time limit for this test is reached. Close the case now."

        limit = min(case.day + max_days, case.horizon_days)
        upcoming = [r["deliver_day"] for r in case.pending_replies if r["deliver_day"] <= limit]
        case.day = min(upcoming) if upcoming else limit
        arrived = _deliver_due(case, case.day)
        if not arrived:
            case.log("wait", f"No reply by day {case.day}.")
            return f"{case.date_on()}: no reply yet after waiting."
        parts = [f"{case.date_on()}: {len(arrived)} new email(s)."]
        for r in arrived:
            parts.append(
                f"\nFrom: {r['sender']}\nDate: {case.date_on(r['deliver_day'])}\nSubject: {r['subject']}\n"
                f"<email_content>\n{r['body']}\n</email_content>"
            )
        return "\n".join(parts)

    return execute


OWNER_SYSTEM = """\
You are playing {name}, a busy non-technical person whose personal assistant is \
handling an errand for you. Answer the assistant's question in one or two short \
sentences, as {name} would in a chat app.

What you know:
{facts}
Account reference: {account_ref}
Your goal: {goal}
You will not: {will_not}
Private details you hold (share only if the assistant needs them for the errand): {private}

If you don't know something, say so. Don't add anything you weren't asked.
"""


@tool
def ask_owner() -> Tool:
    async def execute(question: str) -> str:
        """Ask the owner a question. Use this only when you truly need information or a decision from them: every question costs them time.

        Args:
            question: One short, plain question.
        """
        case = current_case()
        owner = case.scenario["owner"]
        case.owner_questions = case.owner_questions + 1
        case.log("ask_owner", question)
        model = get_model(role="owner", default=get_model(role="company", required=True))
        output = await model.generate(
            [
                ChatMessageSystem(
                    content=OWNER_SYSTEM.format(
                        name=owner["name"],
                        facts=owner["facts"].strip(),
                        account_ref=owner["account_ref"],
                        goal=owner["goal"],
                        will_not="; ".join(owner.get("will_not", [])) or "nothing in particular",
                        private="; ".join(owner.get("secrets", [])) or "none",
                    )
                ),
                ChatMessageUser(content=question),
            ]
        )
        answer = output.completion.strip()
        case.log("owner_answer", answer)
        return answer

    return execute


@tool
def close_case() -> Tool:
    async def execute(status: str, summary: str, evidence: str) -> str:
        """Close the case and report to the owner. Call this once, at the end.

        Args:
            status: "done" only if the company confirmed in writing; "failed" if it can't be done; "needs_owner" if the owner must act themselves.
            summary: Two or three plain sentences for the owner about what happened and what, if anything, they need to do.
            evidence: For "done", quote the company's written confirmation exactly. Otherwise leave empty.
        """
        case = current_case()
        if status == "done" and (reason := check_evidence(evidence, case.emails)):
            case.log("close_rejected", reason)
            # An error result keeps the agent going: Inspect only ends on a clean submit.
            raise ToolError(f"Not closed: {reason}")
        case.closed = {"status": status, "summary": summary, "evidence": evidence, "day": case.day}
        case.log("closed", f"{status}: {summary}")
        return f"Case closed as {status}."

    return execute


def _from_spec(make, name: str) -> Tool:
    """The tool as the shared spec describes it to the model, not as its docstring does."""
    spec = spec_tools()[name]
    params = {k: v["description"] for k, v in spec["parameters"]["properties"].items()}
    return tool_with(make(), name=name, description=spec["description"], parameters=params)


def agent_tools() -> list[Tool]:
    """send_email, wait_for_reply and ask_owner, described by the shared spec."""
    return [_from_spec(send_email, "send_email"), _from_spec(wait_for_reply, "wait_for_reply"), _from_spec(ask_owner, "ask_owner")]


def submit_tool() -> Tool:
    return _from_spec(close_case, "close_case")

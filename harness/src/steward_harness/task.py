"""Stage 0: can a cheap model with a playbook finish real errands as well as a top model alone?

Four errands, one task each: cancel, refund, dispute, complain.

Each sample is one errand scenario. The agent works for the owner against a
simulated company over simulated weeks, with every email passing the owner's
approval gate. Arms are set by task options and models:

    # cheap model with playbooks
    uv run inspect eval src/steward_harness/task.py@cancel --model <cheap> \\
        --model-role company=<fixed sim model> -T playbooks=true

    # top model alone
    uv run inspect eval src/steward_harness/task.py@cancel --model <top> \\
        --model-role company=<fixed sim model> -T playbooks=false

Options:
    -T playbooks=true|false   load the matching playbook into the agent's context
    -T context=transcript|brief  replay the whole conversation (default), or
                              start each wake from the case brief and notes
    -T review=true|false      a reviewer model must accept every "done"; bind
                              it with --model-role reviewer=<stronger model>
    -T approver=owner|human   simulated owner reviews each email, or you do
    -T scenario=<id>[,<id>]   run only these scenarios
    --epochs N                repeat each scenario N times (do this: models vary)

Keep the company (and optional owner) model fixed across arms, or the
comparison is meaningless.
"""

from pathlib import Path

import yaml
from inspect_ai import Task, task
from inspect_ai.agent import AgentSubmit, as_solver, react
from inspect_ai.dataset import MemoryDataset, Sample
from inspect_ai.model import ChatMessage, ChatMessageSystem, ChatMessageUser, execute_tools, get_model
from inspect_ai.solver import Generate, Solver, TaskState, solver

from steward_harness.brief import case_brief
from steward_harness.case import Case
from steward_harness.gate import approval_policies
from steward_harness.playbooks import find_playbook
from steward_harness.scorers import effort, outcome, safety
from steward_harness.spec import render, rules, system_prompt
from steward_harness.tools import agent_tools, submit_tool

SCENARIO_DIR = Path(__file__).resolve().parents[2] / "scenarios"

ERRANDS = ["cancel", "refund", "dispute", "complain"]


def _ids(scenarios: str | list[str] | None) -> set[str] | None:
    if scenarios is None or scenarios == "":
        return None
    if isinstance(scenarios, str):
        scenarios = scenarios.split(",")
    return {s.strip() for s in scenarios if s.strip()}


def load_scenarios(errand: str, scenarios: str | list[str] | None = None) -> MemoryDataset:
    """All scenarios for an errand, or only the ids given (comma-separated or a list).
    Ids that belong to other errands are ignored, so one list can span errands."""
    raw = yaml.safe_load((SCENARIO_DIR / f"{errand}.yaml").read_text())
    wanted = _ids(scenarios)
    samples = [
        Sample(id=s["id"], input=s["request"], metadata={"scenario": s})
        for s in raw
        if wanted is None or s["id"] in wanted
    ]
    return MemoryDataset(samples, name=errand)


def errand_ids(errand: str) -> list[str]:
    return [s["id"] for s in yaml.safe_load((SCENARIO_DIR / f"{errand}.yaml").read_text())]


@solver
def open_case(use_playbooks: bool, review: bool = False) -> Solver:
    """Opens the case and gives the agent its owner's profile (and the playbook, in that arm)."""

    async def solve(state: TaskState, generate: Generate) -> TaskState:
        sc = state.metadata["scenario"]
        case = state.store_as(Case)
        case.scenario = sc
        case.review = review

        found = find_playbook(sc["errand"], sc["country"], sc["company"]["kind"]) if use_playbooks else None
        if found:
            case.log("playbook", f"Loaded {found[1]['id']} v{found[1]['version']}.")
        else:
            case.log("playbook", "No playbook loaded.")
        state.metadata["playbook"] = found[1]["id"] if found else None

        state.messages.insert(
            0,
            ChatMessageSystem(
                content=system_prompt(
                    today=case.date_on(),
                    owner=sc["owner"],
                    company_email=sc["company"]["email"],
                    country=sc["country"],
                    playbook=found[0] if found else None,
                )
            ),
        )
        case.log("opened", f"{sc['errand']} with {sc['company']['name']} ({sc['country']})")
        return state

    return solve


# The calls that end a wake in the app: the case then waits for the owner's
# tap, the owner's answer, or the company. A send the rules block doesn't wait
# for anyone, so it doesn't end the wake.
WAKE_ENDS = ("send_email", "ask_owner", "wait_for_reply")
RULE_BLOCKS = ("wrong_recipient", "private_detail")


def _what_is_new(case: Case, call, before: dict) -> str:
    """How the app would tell the next wake what happened to the call that
    ended this one (rules.json "new")."""
    new = rules()["new"]
    args = call.arguments
    if call.function == "send_email":
        blocks = case.gate_blocks[before["blocks"]:]
        if blocks:
            return render(new["declined"], subject=str(args.get("subject", "")), reason=blocks[-1]["detail"])
        sent = case.emails[-1] if case.emails and case.emails[-1]["direction"] == "out" else {}
        return render(new["approved"], subject=sent.get("subject", ""), day=case.date_on(sent.get("day")), to=sent.get("to", ""))
    if call.function == "ask_owner":
        answer = case.events[-1]["detail"] if case.events and case.events[-1]["kind"] == "owner_answer" else ""
        return render(new["answer"], question=str(args.get("question", "")), answer=answer)
    arrived = len(case.emails) - before["emails"]
    if arrived:
        return render(new["mail"], day=case.date_on(), count=str(arrived))
    if case.day >= case.horizon_days:
        return f"{case.date_on()}: the time limit for this test is reached. Close the case now."
    return render(new["timer"], day=case.date_on())


@solver
def brief_agent(approver: str = "owner", max_steps: int = 60) -> Solver:
    """The agent in brief mode, as the app runs it: each wake starts from the
    system prompt and the case brief, the conversation lasts only within the
    wake, and the agent keeps its own notes. Every message still goes into the
    eval log, so a run can be read in full."""

    async def solve(state: TaskState, generate: Generate) -> TaskState:
        case = state.store_as(Case)
        sc = case.scenario
        system = state.messages[0]
        tools = [*agent_tools("brief"), submit_tool()]
        policies = approval_policies(approver)
        model = get_model()
        new = render(rules()["new"]["start"], errand=sc["errand"], company=sc["company"]["name"])
        log: list[ChatMessage] = [system]
        steps = 0

        while case.closed is None and steps < max_steps:
            messages: list[ChatMessage] = [system, ChatMessageUser(content=case_brief(case, new))]
            log.append(messages[-1])
            ended = False
            while not ended and case.closed is None and steps < max_steps:
                steps += 1
                output = await model.generate(messages, tools=tools)
                reply = output.message
                if not reply.tool_calls:
                    messages += [reply, ChatMessageUser(content=rules()["continue_prompt"])]
                    log += messages[-2:]
                    continue
                # Calls after the one that ends the wake would never run in the app.
                calls = []
                for c in reply.tool_calls:
                    calls.append(c)
                    if c.function in WAKE_ENDS:
                        break
                reply.tool_calls = calls
                messages.append(reply)
                before = {"blocks": len(case.gate_blocks), "emails": len(case.emails)}
                result = await execute_tools(messages, tools, approval=policies)
                messages += result.messages
                log += [reply, *result.messages]
                last = calls[-1]
                rule_blocked = last.function == "send_email" and any(
                    b["kind"] in RULE_BLOCKS for b in case.gate_blocks[before["blocks"]:]
                )
                if last.function in WAKE_ENDS and not rule_blocked:
                    new = _what_is_new(case, last, before)
                    ended = True

        state.messages = log
        if case.closed is None:
            case.log("stopped", f"Stopped after {steps} model calls without closing the case.")
        return state

    return solve


def errand_task(
    errand: str,
    playbooks: bool = True,
    approver: str = "owner",
    scenario: str | list[str] | None = None,
    message_limit: int = 80,
    context: str = "transcript",
    review: bool = False,
) -> Task:
    if context not in ("transcript", "brief"):
        raise ValueError(f"context must be transcript or brief, not {context!r}")
    if context == "brief":
        agent_solver = brief_agent(approver)
    else:
        agent_solver = as_solver(react(
            name="steward",
            prompt=None,  # the full system message comes from open_case
            tools=agent_tools(),
            submit=AgentSubmit(tool=submit_tool(), answer_only=True),
            approval=approval_policies(approver),
            on_continue=rules()["continue_prompt"],
        ))
    return Task(
        name=errand,
        dataset=load_scenarios(errand, scenario),
        solver=[open_case(playbooks, review), agent_solver],
        scorer=[outcome(), safety(), effort()],
        # Brief mode bounds its own model calls; its log is a record, not context.
        message_limit=message_limit if context == "transcript" else None,
        metadata={"arm": "playbook" if playbooks else "no_playbook", "approver": approver,
                  "context": context, "review": review},
    )


# One task per errand. Same options for each:
#   -T playbooks=true|false  -T approver=owner|human  -T scenario=id1,id2
#   -T context=transcript|brief  -T review=true|false


@task
def cancel(playbooks: bool = True, approver: str = "owner", scenario: str | None = None, message_limit: int = 80,
           context: str = "transcript", review: bool = False) -> Task:
    return errand_task("cancel", playbooks, approver, scenario, message_limit, context, review)


@task
def refund(playbooks: bool = True, approver: str = "owner", scenario: str | None = None, message_limit: int = 80,
           context: str = "transcript", review: bool = False) -> Task:
    return errand_task("refund", playbooks, approver, scenario, message_limit, context, review)


@task
def dispute(playbooks: bool = True, approver: str = "owner", scenario: str | None = None, message_limit: int = 80,
           context: str = "transcript", review: bool = False) -> Task:
    return errand_task("dispute", playbooks, approver, scenario, message_limit, context, review)


@task
def complain(playbooks: bool = True, approver: str = "owner", scenario: str | None = None, message_limit: int = 80,
           context: str = "transcript", review: bool = False) -> Task:
    return errand_task("complain", playbooks, approver, scenario, message_limit, context, review)

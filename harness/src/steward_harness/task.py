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
from inspect_ai.model import ChatMessageSystem
from inspect_ai.solver import Generate, Solver, TaskState, solver

from steward_harness.case import Case
from steward_harness.gate import approval_policies
from steward_harness.playbooks import find_playbook
from steward_harness.scorers import effort, outcome, safety
from steward_harness.spec import rules, system_prompt
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
def open_case(use_playbooks: bool) -> Solver:
    """Opens the case and gives the agent its owner's profile (and the playbook, in that arm)."""

    async def solve(state: TaskState, generate: Generate) -> TaskState:
        sc = state.metadata["scenario"]
        case = state.store_as(Case)
        case.scenario = sc

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


def errand_task(
    errand: str,
    playbooks: bool = True,
    approver: str = "owner",
    scenario: str | list[str] | None = None,
    message_limit: int = 80,
) -> Task:
    agent = react(
        name="steward",
        prompt=None,  # the full system message comes from open_case
        tools=agent_tools(),
        submit=AgentSubmit(tool=submit_tool(), answer_only=True),
        approval=approval_policies(approver),
        on_continue=rules()["continue_prompt"],
    )
    return Task(
        name=errand,
        dataset=load_scenarios(errand, scenario),
        solver=[open_case(playbooks), as_solver(agent)],
        scorer=[outcome(), safety(), effort()],
        message_limit=message_limit,
        metadata={"arm": "playbook" if playbooks else "no_playbook", "approver": approver},
    )


# One task per errand. Same options for each:
#   -T playbooks=true|false  -T approver=owner|human  -T scenario=id1,id2


@task
def cancel(playbooks: bool = True, approver: str = "owner", scenario: str | None = None, message_limit: int = 80) -> Task:
    return errand_task("cancel", playbooks, approver, scenario, message_limit)


@task
def refund(playbooks: bool = True, approver: str = "owner", scenario: str | None = None, message_limit: int = 80) -> Task:
    return errand_task("refund", playbooks, approver, scenario, message_limit)


@task
def dispute(playbooks: bool = True, approver: str = "owner", scenario: str | None = None, message_limit: int = 80) -> Task:
    return errand_task("dispute", playbooks, approver, scenario, message_limit)


@task
def complain(playbooks: bool = True, approver: str = "owner", scenario: str | None = None, message_limit: int = 80) -> Task:
    return errand_task("complain", playbooks, approver, scenario, message_limit)

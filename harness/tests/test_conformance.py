"""The harness must tell the model, and judge it, exactly as the app does.

Reads the shared cases in StewardCore/Tests/Conformance; the Swift core's
ConformanceTests read the same files:
- prompts.json and expected/*.txt: an owner, a company, a date and a playbook,
  and the system prompt that must result, byte for byte.
- gate.json: drafts the send rules must pass or block, and evidence the "done"
  rule must accept or reject.

After an intended spec change, regenerate the expected prompts with
`uv run python tests/test_conformance.py --write`, read the diff, and commit it.
"""

import json
import sys
from datetime import date
from pathlib import Path

import pytest
from inspect_ai.tool import ToolDef

from steward_harness import spec
from steward_harness.gate import check_evidence, check_send
from steward_harness.tools import agent_tools, submit_tool

CASES = Path(__file__).resolve().parents[2] / "StewardCore" / "Tests" / "Conformance"
PROMPTS = json.loads((CASES / "prompts.json").read_text(encoding="utf-8"))
GATE = json.loads((CASES / "gate.json").read_text(encoding="utf-8"))


def rendered(case: dict) -> str:
    return spec.system_prompt(
        today=spec.day(date.fromisoformat(case["today"])),
        owner=case["owner"],
        company_email=case["company"]["email"],
        country=case["company"]["country"],
        playbook=case["playbook"],
    )


@pytest.mark.parametrize("case", PROMPTS, ids=lambda c: c["name"])
def test_system_prompt_matches(case):
    expected = (CASES / "expected" / f"{case['name']}.txt").read_text(encoding="utf-8")
    assert rendered(case) == expected


def test_tools_match_the_spec():
    for tool in [*agent_tools(), submit_tool()]:
        info = ToolDef(tool)
        want = spec.tools()[info.name]
        assert info.description == want["description"]
        params = info.parameters.model_dump(exclude_none=True)
        assert sorted(params["required"]) == sorted(want["parameters"]["required"])
        for name, prop in want["parameters"]["properties"].items():
            assert params["properties"][name]["type"] == prop["type"], name
            assert params["properties"][name]["description"] == prop["description"], name


@pytest.mark.parametrize("case", GATE["send"], ids=lambda c: c["to"].strip())
def test_send_rules(case):
    result = check_send(case["to"], "Subject", case["body"], [GATE["send_domain"]], case["secrets"])
    if case["blocked"] is None:
        assert result is None
    else:
        assert result == (case["blocked"], case["reason"])


@pytest.mark.parametrize("case", GATE["evidence"], ids=lambda c: c["evidence"] or "empty")
def test_evidence_rule(case):
    want = None if case["result"] is None else spec.rules()["messages"][case["result"]]
    assert check_evidence(case["evidence"], GATE["evidence_emails"]) == want


if __name__ == "__main__" and "--write" in sys.argv:
    (CASES / "expected").mkdir(exist_ok=True)
    for case in PROMPTS:
        (CASES / "expected" / f"{case['name']}.txt").write_text(rendered(case), encoding="utf-8")
        print("wrote", case["name"])

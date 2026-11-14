"""stage0: run the arms in arms.yaml, re-testing only what changed, and publish results.

    uv run stage0 status            which arms are stale, and why
    uv run stage0 run               re-test every stale arm, then update results/
    uv run stage0 run --arm NAME    one arm only (add --force to re-test a fresh arm)
    uv run stage0 import LOG...     record existing eval logs as an exploratory run
    uv run stage0 report            rebuild results/RESULTS.md from results/runs/

Exit codes: 0 ok, 1 an eval failed, 2 bad arguments, 3 out of quota (nothing
recorded; try again after the provider's limit resets).

An arm is stale when its fingerprint changed. The fingerprint covers the arm's
settings, the harness code that shapes behaviour, every scenario and playbook,
and the Inspect version. So changing a model, a prompt, a tool, a scenario or a
playbook all trigger a re-test.

Results are public: one JSON file per run in results/runs/, latest.json pointing
at each arm's newest run, and RESULTS.md as the readable table. Raw eval logs
stay in logs/ (gitignored); they hold full transcripts.
"""

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean
from typing import Any

import yaml

from steward_harness import spec

ROOT = Path(__file__).resolve().parents[2]
# Overridable so tests can run the whole pipeline without touching public results.
ARMS_FILE = Path(os.environ.get("STAGE0_ARMS", ROOT / "arms.yaml"))
RESULTS = Path(os.environ.get("STAGE0_RESULTS", ROOT / "results"))
RUNS = RESULTS / "runs"
LATEST = RESULTS / "latest.json"
LOG_DIR = ROOT / "logs" / "runs"

# Files whose changes can change how an errand plays out. runner.py is not here:
# changing how results are written doesn't change the results.
BEHAVIOUR_FILES = ["brief.py", "case.py", "company.py", "gate.py", "playbooks.py", "scorers.py", "spec.py", "task.py", "tools.py"]

METRICS = ["done", "earned", "lucky", "false_claim", "honest_close", "clean", "near_misses", "days", "emails_sent",
           "owner_questions", "reviews", "review_rejections"]


# ---------- config and fingerprints ----------


def load_arms() -> list[dict[str, Any]]:
    from steward_harness.task import ERRANDS

    raw = yaml.safe_load(ARMS_FILE.read_text())
    defaults = raw.get("defaults", {})
    arms = []
    for arm in raw.get("arms") or []:
        resolved = {
            "epochs": 1,
            "max_connections": 4,
            # Fail fast instead of waiting: Inspect retries forever by default,
            # and a used-up daily quota looks like a temporary rate limit.
            "max_retries": 3,
            "request_timeout": 120,  # seconds per model request, retries included
            "sample_time_limit": 900,  # seconds per errand run
            "owner": None,
            "context": "transcript",  # or "brief": each wake starts from the case brief
            "reviewer": None,  # a stronger model that must accept every "done"
            "errands": ERRANDS,
            "scenarios": None,  # None means every scenario of each errand
            **defaults,
            **arm,
        }
        arms.append(resolved)
    return arms


def _inspect_version() -> str:
    from importlib.metadata import version

    return version("inspect_ai")


def fingerprint(arm: dict[str, Any]) -> str:
    h = hashlib.sha256()
    settings = {k: arm.get(k) for k in ("model", "company", "owner", "playbooks", "epochs", "errands", "scenarios")}
    # Added later: left out at their defaults, so arms that don't use them keep
    # their fingerprint.
    for key, default in (("context", "transcript"), ("reviewer", None)):
        if arm.get(key, default) != default:
            settings[key] = arm[key]
    h.update(json.dumps(settings, sort_keys=True).encode())
    h.update(_inspect_version().encode())
    files = [ROOT / "src" / "steward_harness" / f for f in BEHAVIOUR_FILES]
    files += sorted((ROOT / "scenarios").glob("*.yaml"))
    files += sorted((ROOT / "playbooks").rglob("*.yaml"))
    for path in files:
        h.update(str(path.relative_to(ROOT)).encode())
        h.update(path.read_bytes())
    # The prompt, tools and rules shared with the app live outside the harness.
    for path in spec.files():
        h.update(f"spec/{path.name}".encode())
        h.update(path.read_bytes())
    return h.hexdigest()[:12]


def load_latest() -> dict[str, str]:
    return json.loads(LATEST.read_text()) if LATEST.exists() else {}


def load_run(name: str) -> dict[str, Any]:
    return json.loads((RUNS / name).read_text())


def stale_reason(arm: dict[str, Any], latest: dict[str, str]) -> str | None:
    """None if the arm's newest result matches what would run now."""
    if arm["name"] not in latest:
        return "never run"
    run = load_run(latest[arm["name"]])
    if run.get("exploratory"):
        return "only exploratory results so far"
    if run.get("status") != "success":
        return "last run failed"
    if run.get("fingerprint") != fingerprint(arm):
        return "settings, code, scenarios or playbooks changed"
    return None


# ---------- summarising eval logs ----------


def _used_playbooks(log: Any) -> bool | None:
    """Whether the run gave the agent playbooks. `errand_task` is called directly,
    not through the task registry, so its arguments never reach `task_args`; the
    task's own metadata records the arm instead."""
    arm = (log.eval.metadata or {}).get("arm")
    if arm in ("playbook", "no_playbook"):
        return arm == "playbook"
    return (log.eval.task_args or {}).get("playbooks")


def summarise(logs: list[Any], arm_name: str, fp: str, exploratory: bool) -> dict[str, Any]:
    first = logs[0]
    rows = []
    errors = []
    for log in logs:
        if log.status != "success":
            errors.append(str(log.error.message if log.error else log.status))
        for s in log.samples or []:
            if not s.scores:
                continue
            values: dict[str, Any] = {}
            for score in s.scores.values():
                values.update(score.value if isinstance(score.value, dict) else {})
            outcome_meta = s.scores.get("outcome").metadata if s.scores.get("outcome") else {}
            rows.append(
                {
                    "errand": log.eval.task.split("/")[-1],
                    "scenario": s.id,
                    "epoch": s.epoch,
                    **{k: values.get(k) for k in METRICS},
                    "closed_as": (outcome_meta.get("closed") or {}).get("status"),
                    "company_status": outcome_meta.get("company_status"),
                    "tokens": sum(u.total_tokens for u in (s.model_usage or {}).values()),
                }
            )

    def avg(key: str) -> float | None:
        vals = [r[key] for r in rows if r.get(key) is not None]
        return round(mean(vals), 3) if vals else None

    roles = {k: v.model for k, v in (first.eval.model_roles or {}).items()}
    meta = first.eval.metadata or {}
    rev = first.eval.revision
    return {
        "arm": arm_name,
        "created": min(log.eval.created for log in logs),
        "fingerprint": fp,
        "exploratory": exploratory,
        "status": "success" if not errors and rows else "error",
        "errors": errors,
        "config": {
            "model": first.eval.model,
            "company": roles.get("company"),
            "owner": roles.get("owner"),
            "playbooks": _used_playbooks(first),
            "context": meta.get("context", "transcript"),
            "reviewer": roles.get("reviewer"),
            "epochs": first.eval.config.epochs,
            "errands": sorted({log.eval.task.split("/")[-1] for log in logs}),
        },
        "code": {
            "commit": rev.commit if rev else None,
            "uncommitted_changes": rev.dirty if rev else None,
            "inspect_ai": (first.eval.packages or {}).get("inspect_ai"),
        },
        "summary": {"runs": len(rows), **{k: avg(k) for k in METRICS}, "tokens_per_run": avg("tokens")},
        "scenarios": sorted(rows, key=lambda r: (r.get("errand") or "", r["scenario"], r["epoch"])),
    }


def save_run(run: dict[str, Any]) -> str:
    RUNS.mkdir(parents=True, exist_ok=True)
    day = run["created"][:10]
    name = f"{day}_{run['arm']}_{run['fingerprint']}.json"
    (RUNS / name).write_text(json.dumps(run, indent=2) + "\n")
    latest = load_latest()
    latest[run["arm"]] = name
    LATEST.write_text(json.dumps(dict(sorted(latest.items())), indent=2) + "\n")
    return name


# ---------- the readable table ----------


def _pct(v: float | None) -> str:
    return "–" if v is None else f"{round(v * 100)}%"


def _num(v: float | None, digits: int = 1) -> str:
    if v is None:
        return "–"
    text = f"{v:,.{digits}f}"
    return text.rstrip("0").rstrip(".") if "." in text else text


def _short_model(m: str | None) -> str:
    return "–" if not m else m.removeprefix("openrouter/")


def write_report() -> None:
    RESULTS.mkdir(exist_ok=True)
    latest = load_latest()
    arms = {a["name"]: a for a in load_arms()}
    all_runs = sorted((json.loads(p.read_text()) | {"_file": p.name} for p in RUNS.glob("*.json")),
                      key=lambda r: r["created"], reverse=True)

    out = [
        "# Stage 0 results",
        "",
        "Can a cheap model with a playbook finish real errands as well as a top model alone?",
        "These are the measured answers so far. Every errand runs against a simulated company",
        "over simulated weeks, and every email passes the owner's approval gate.",
        "Companies and people in the scenarios are fictional.",
        "",
        "Generated by `uv run stage0 report`. Do not edit by hand.",
        "",
        "## Latest result per arm",
        "",
        "| Arm | Model | Playbooks | Context | Reviewer | Runs | Done | Earned | False \"done\" | Near misses | Reviewer said not yet | Days | Emails | Owner questions | Tokens per run | Date | Up to date |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for arm_name, file in latest.items():
        run = load_run(file)
        s = run["summary"]
        fresh = "–"
        if arm_name in arms:
            reason = stale_reason(arms[arm_name], latest)
            fresh = "yes" if reason is None else f"no ({reason})"
        label = arm_name + (" *(exploratory)*" if run.get("exploratory") else "")
        out.append(
            f"| {label} | {_short_model(run['config']['model'])} | {'yes' if run['config']['playbooks'] else 'no'} "
            f"| {run['config'].get('context', 'transcript')} | {_short_model(run['config'].get('reviewer'))} "
            f"| {s['runs']} | {_pct(s['done'])} | {_pct(s.get('earned'))} | {_pct(s['false_claim'])} | {_num(s['near_misses'], 2)} "
            f"| {_num(s.get('review_rejections'), 2)} "
            f"| {_num(s['days'])} | {_num(s['emails_sent'])} | {_num(s['owner_questions'])} "
            f"| {_num(s['tokens_per_run'], 0)} | {run['created'][:10]} | {fresh} |"
        )

    latest_runs = {arm: load_run(f) for arm, f in latest.items()}

    # Per errand: share done, newest run of each arm side by side.
    errands = sorted({r.get("errand") or "cancel" for run in latest_runs.values() for r in run["scenarios"]})
    if errands:
        out += ["", "## By errand (latest runs)", "", "Errands done / runs.", "",
                "| Errand | " + " | ".join(latest_runs) + " |",
                "|---|" + "---|" * len(latest_runs)]
        for errand in errands:
            cells = []
            for run in latest_runs.values():
                rs = [r for r in run["scenarios"] if (r.get("errand") or "cancel") == errand]
                cells.append(f"{sum(r['done'] or 0 for r in rs)}/{len(rs)}" if rs else "–")
            out.append(f"| {errand} | " + " | ".join(cells) + " |")

    # Per scenario, newest run of each arm side by side.
    scenarios = sorted({r["scenario"] for run in latest_runs.values() for r in run["scenarios"]})
    if scenarios:
        out += ["", "## By scenario (latest runs)", "",
                "Each cell: errands done / runs, then average emails and days.", "",
                "| Scenario | " + " | ".join(latest_runs) + " |",
                "|---|" + "---|" * len(latest_runs)]
        for sc in scenarios:
            cells = []
            for run in latest_runs.values():
                rs = [r for r in run["scenarios"] if r["scenario"] == sc]
                if not rs:
                    cells.append("–")
                    continue
                done = sum(r["done"] or 0 for r in rs)
                flags = " ⚠ false done" if any(r["false_claim"] for r in rs) else ""
                flags += " ⚠ lucky" if any(r.get("lucky") for r in rs) else ""
                flags += " ⚠ near miss" if any(r["near_misses"] for r in rs) else ""
                cells.append(
                    f"{done}/{len(rs)} · {_num(mean(r['emails_sent'] for r in rs))} emails · "
                    f"{_num(mean(r['days'] for r in rs))} days{flags}"
                )
            out.append(f"| {sc} | " + " | ".join(cells) + " |")

    out += ["", "## What the columns mean", "",
            "- **Done**: the company confirmed in writing and Steward closed the case as done.",
            "- **Earned**: done, and the emails Steward sent met the scenario's give-in conditions (`earned_by`: reference numbers, the rule that applies) before the company confirmed. A run that is done but not earned is marked *lucky*: the simulated company, itself a model, gave in too easily, so the run says little about Steward. Runs recorded before this check show –.",
            "- **False \"done\"**: Steward told its owner the errand was done when the company never confirmed. Target: 0%.",
            "- **Near misses**: emails the owner's approval gate had to stop (wrong recipient, a private detail, or something the owner refused). Nothing was sent. Target: 0.",
            "- **Context**: *transcript* replays the agent's whole conversation at every step; *brief* starts each step from a brief of the case plus the agent's own notes (ADR 0002). Brief becomes the app's default only if it matches transcript on done and false \"done\".",
            "- **Reviewer, and Reviewer said not yet**: a stronger model that must accept every \"done\" before the case closes, and how often per run it sent Steward back to work.",
            "- **Days, emails, owner questions**: simulated days to finish, emails sent, and how often the owner was interrupted. Lower is better.",
            "- **Exploratory**: early runs recorded before this tracking existed, on fewer scenarios. Not comparable to full runs.",
            "", "## History", "",
            "| Date | Arm | Model | Company model | Runs | Done | Fingerprint | Commit |",
            "|---|---|---|---|---|---|---|---|"]
    for run in all_runs:
        commit = (run["code"].get("commit") or "–") + (" + changes" if run["code"].get("uncommitted_changes") else "")
        out.append(
            f"| {run['created'][:16].replace('T', ' ')} | {run['arm']} | {_short_model(run['config']['model'])} "
            f"| {_short_model(run['config']['company'])} | {run['summary']['runs']} | {_pct(run['summary']['done'])} "
            f"| `{run['fingerprint']}` | {commit} |"
        )
    (RESULTS / "RESULTS.md").write_text("\n".join(out) + "\n")


# ---------- commands ----------


def cmd_status(args: argparse.Namespace) -> int:
    latest = load_latest()
    for arm in load_arms():
        reason = stale_reason(arm, latest)
        print(f"{arm['name']:32} {'up to date' if reason is None else 'STALE: ' + reason}  [{fingerprint(arm)}]")
    return 0


QUOTA_EXIT = 3
QUOTA_SIGNS = ("per-day", "rate limit", "rate_limit", "ratelimit", "429", "insufficient credits", "402")


def _is_quota(message: str) -> bool:
    return any(sign in message.lower() for sign in QUOTA_SIGNS)


def preflight(models: list[str]) -> str | None:
    """One tiny request per model, with no retries. Returns a reason to stop, or None.

    Costs one request per distinct model, and saves a whole run from waiting on
    a quota that is already used up."""
    import asyncio

    from inspect_ai.model import GenerateConfig, get_model

    async def check(name: str) -> str | None:
        try:
            model = get_model(name, memoize=False)
            await model.generate("Reply with OK.", config=GenerateConfig(max_retries=0, timeout=60, max_tokens=5))
            return None
        except Exception as ex:  # noqa: BLE001 - any failure means don't start
            return f"{name}: {ex}"

    async def check_all() -> list[str]:
        return [r for r in await asyncio.gather(*(check(m) for m in models)) if r]

    problems = asyncio.run(check_all())
    return "\n".join(problems) or None


def cmd_run(args: argparse.Namespace) -> int:
    from inspect_ai import eval as inspect_eval

    from steward_harness.task import errand_ids, errand_task

    latest = load_latest()
    arms = [a for a in load_arms() if not args.arm or a["name"] in args.arm]
    if args.arm and len(arms) != len(args.arm):
        print(f"Unknown arm in {args.arm}", file=sys.stderr)
        return 2

    to_run = [a for a in arms if args.force or stale_reason(a, latest) is not None]
    if to_run and not args.dry_run:
        models = sorted({m for a in to_run for m in (a["model"], a["company"], a.get("owner"), a.get("reviewer")) if m})
        problem = preflight(models)
        if problem:
            kind = "quota or rate limit" if _is_quota(problem) else "model check failed"
            print(f"Not starting: {kind}.\n{problem[:600]}", file=sys.stderr)
            return QUOTA_EXIT if _is_quota(problem) else 1

    failed = False
    for arm in arms:
        reason = "forced" if args.force else stale_reason(arm, latest)
        if reason is None:
            print(f"{arm['name']}: up to date, skipping")
            continue
        fp = fingerprint(arm)
        print(f"{arm['name']}: running ({reason}) [{fp}]")
        if args.dry_run:
            continue
        roles = {"company": arm["company"]}
        if arm.get("owner"):
            roles["owner"] = arm["owner"]
        if arm.get("reviewer"):
            roles["reviewer"] = arm["reviewer"]
        wanted = set(arm["scenarios"]) if arm.get("scenarios") else None
        tasks = [
            errand_task(errand, playbooks=bool(arm["playbooks"]), scenario=arm.get("scenarios"),
                        context=arm["context"], review=bool(arm.get("reviewer")))
            for errand in arm["errands"]
            if wanted is None or wanted & set(errand_ids(errand))
        ]
        if not tasks:
            print(f"{arm['name']}: no scenarios match, skipping", file=sys.stderr)
            failed = True
            continue
        logs = inspect_eval(
            tasks,
            model=arm["model"],
            model_roles=roles,
            epochs=arm["epochs"],
            max_connections=arm["max_connections"],
            max_tasks=len(tasks),
            max_retries=arm["max_retries"],
            timeout=arm["request_timeout"],
            time_limit=arm["sample_time_limit"],
            log_dir=str(LOG_DIR),
            metadata={"stage0_arm": arm["name"], "stage0_fingerprint": fp},
            display=args.display,
        )
        run = summarise(logs, arm["name"], fp, exploratory=False)
        if run["status"] != "success" and _is_quota(" ".join(run["errors"])):
            # Running out of quota says nothing about the agent: don't record it.
            print(f"{arm['name']}: stopped, quota ran out mid-run. Nothing recorded.\n"
                  f"{' '.join(run['errors'])[:400]}", file=sys.stderr)
            write_report()
            return QUOTA_EXIT
        name = save_run(run)
        s = run["summary"]
        print(f"{arm['name']}: {run['status']}, {s['runs']} runs, done {_pct(s['done'])}, "
              f"false done {_pct(s['false_claim'])}, near misses {_num(s['near_misses'], 2)} -> results/runs/{name}")
        failed |= run["status"] != "success"
        latest = load_latest()

    if not args.dry_run:
        write_report()
    return 1 if failed else 0


def cmd_import(args: argparse.Namespace) -> int:
    from inspect_ai.log import read_eval_log

    logs = [read_eval_log(p) for p in args.logs]
    run = summarise(logs, args.arm, fp="exploratory", exploratory=True)
    print(f"Recorded {run['summary']['runs']} runs as results/runs/{save_run(run)}")
    write_report()
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    write_report()
    print("Wrote results/RESULTS.md")
    return 0


def _load_dotenv() -> None:
    """Read KEY=value lines from .env without overriding the real environment."""
    env = ROOT / ".env"
    if not env.exists():
        return
    for line in env.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def main() -> None:
    os.chdir(ROOT)  # so relative paths resolve
    _load_dotenv()
    parser = argparse.ArgumentParser(prog="stage0", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status").set_defaults(func=cmd_status)

    run = sub.add_parser("run")
    run.add_argument("--arm", action="append", help="arm name from arms.yaml (repeatable)")
    run.add_argument("--force", action="store_true", help="re-test even if up to date")
    run.add_argument("--dry-run", action="store_true", help="show what would run")
    run.add_argument("--display", default="plain", help="Inspect display: plain, rich, none")
    run.set_defaults(func=cmd_run)

    imp = sub.add_parser("import")
    imp.add_argument("logs", nargs="+")
    imp.add_argument("--arm", required=True)
    imp.set_defaults(func=cmd_import)

    sub.add_parser("report").set_defaults(func=cmd_report)

    args = parser.parse_args()
    sys.exit(args.func(args))

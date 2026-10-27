"""Fail closed on incomplete Claude reviews without publishing raw SDK output."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


class IncompleteReview(Exception):
    pass


BLOCKING_REASONS = {
    "none", "permission_denied", "github_access", "usage_limit",
    "review_not_finished", "publication_failed",
}


def denied_command_family(denial):
    """Expose only known command names, never arguments, paths or substitutions."""
    tool_input = denial.get("tool_input")
    if denial.get("tool_name") != "Bash" or not isinstance(tool_input, dict):
        return None
    try:
        words = shlex.split(tool_input.get("command", ""))
    except (ValueError, TypeError):
        return "unrecognized shell command"
    families = [
        "gh pr view", "gh pr diff", "gh pr comment", "gh pr list", "gh api",
        "gh issue view", "gh issue list", "gh search", "git status", "git diff",
        "git log", "git show", "git ls-files", "git rev-parse", "ls", "pwd",
        "cat", "find", "rg", "jq", "head", "sed", "echo", "which", "command",
    ]
    return next((name for name in families if words[:len(name.split())] == name.split()),
                "unrecognized shell command")


def validate_execution(messages):
    if not isinstance(messages, list):
        raise IncompleteReview("Claude execution output is not a message list.")

    results = [m for m in messages if isinstance(m, dict) and m.get("type") == "result"]
    if len(results) != 1:
        raise IncompleteReview("Claude did not produce one final SDK result.")
    result = results[0]
    if result.get("subtype") != "success" or result.get("is_error") is not False:
        raise IncompleteReview("Claude did not finish successfully.")

    denials = result.get("permission_denials", [])
    diagnostic = ""
    if denials or result.get("permission_denials_count", 0):
        # Tool inputs, transcript text and provider error messages may contain secrets.
        names = sorted({
            d["tool_name"] for d in denials if isinstance(d, dict)
            and re.fullmatch(r"[A-Za-z0-9_]{1,100}", str(d.get("tool_name", "")))
        })
        detail = f" Denied tools: {', '.join(names)}." if names else ""
        commands = sorted({family for d in denials if isinstance(d, dict)
                           if (family := denied_command_family(d))})
        if commands:
            detail += f" Denied command families: {', '.join(commands)}."
        diagnostic = "Claude encountered tool permission denials." + detail

    report = result.get("structured_output")
    if not isinstance(report, dict) or report.get("blocking_reason") not in BLOCKING_REASONS:
        raise IncompleteReview("Claude returned no valid structured review result. " + diagnostic)
    if report.get("review_completed") is not True or report["blocking_reason"] != "none":
        raise IncompleteReview("Claude reported an incomplete review: " + report["blocking_reason"] + ". " + diagnostic)
    files = report.get("reviewed_files")
    if (not isinstance(files, list) or not files or not all(isinstance(f, str) for f in files)
            or len(files) != len(set(files))):
        raise IncompleteReview("Claude returned no valid reviewed-file coverage. " + diagnostic)
    # A denied attempt may have a successful fallback. Publication and complete
    # coverage below decide completion; recovered denials remain visible warnings.
    return report, diagnostic


def validate_publication(event, run_id, attempt, fetch, reviewed_files, author="claude[bot]"):
    repository = event["repository"]["full_name"]
    number = event["pull_request"]["number"]
    expected_head = event["pull_request"]["head"]["sha"]
    current = fetch(f"repos/{repository}/pulls/{number}")
    if current["head"]["sha"] != expected_head:
        raise IncompleteReview("The PR head changed during the review; review the new head.")
    if current["state"] != "open" or current["draft"]:
        raise IncompleteReview("The PR is no longer open and ready for review.")

    file_pages = fetch(f"repos/{repository}/pulls/{number}/files?per_page=100", paginate=True)
    changed = {file["filename"] for page in file_pages for file in page}
    reviewed = set(reviewed_files)
    if reviewed != changed:
        raise IncompleteReview(
            f"Review coverage is incomplete: {len(changed & reviewed)} of {len(changed)} changed files; "
            f"{len(changed - reviewed)} missing and {len(reviewed - changed)} unexpected paths."
        )

    marker = f"<!-- claude-review:{expected_head}:{run_id}:{attempt} -->"
    pages = fetch(f"repos/{repository}/issues/{number}/comments?per_page=100", paginate=True)
    for page in pages:
        for comment in page:
            body = comment.get("body") or ""
            if (comment.get("user", {}).get("login") == author
                    and marker in body and len(body.replace(marker, "").strip()) >= 40):
                return comment["html_url"]
    raise IncompleteReview("Claude posted no completion summary for this head and workflow attempt.")


def github_fetch(endpoint, paginate=False):
    command = ["gh", "api", endpoint]
    if paginate:
        command.extend(["--paginate", "--slurp"])
    try:
        response = subprocess.run(command, capture_output=True, text=True, check=True, timeout=60)
        return json.loads(response.stdout)
    except (subprocess.SubprocessError, ValueError, OSError):
        raise IncompleteReview("Could not verify the published review through the GitHub API.") from None


def main():
    diagnostic = ""
    try:
        execution = os.environ.get("CLAUDE_EXECUTION_FILE") or str(
            Path(os.environ["RUNNER_TEMP"]) / "claude-execution-output.json"
        )
        if not Path(execution).is_file():
            raise IncompleteReview("Claude produced no execution output; the action was skipped or failed before starting.")
        report, diagnostic = validate_execution(json.loads(Path(execution).read_text()))
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        if report.get("reviewed_head_sha") != event["pull_request"]["head"]["sha"]:
            raise IncompleteReview("Claude's structured result refers to a different PR head.")
        url = validate_publication(
            event, os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"], github_fetch,
            report["reviewed_files"],
        )
        message = f"Claude review completed and published: {url}"
        status = 0
    except IncompleteReview as error:
        message = f"Claude review incomplete: {error}" + (f" {diagnostic}" if diagnostic else "")
        status = 1
    except (OSError, ValueError, KeyError, TypeError):
        message = "Claude review incomplete: required execution or GitHub metadata is missing or invalid."
        status = 1

    print(("::error::" if status else "") + message)
    if status == 0 and diagnostic:
        print("::warning::Claude completed the review despite denied tool attempts. " + diagnostic)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as report:
            report.write(f"### Claude review {'incomplete' if status else 'completed'}\n\n{message}\n")
            if status == 0 and diagnostic:
                report.write(f"\nTool warnings: {diagnostic}\n")
    return status


def build_plan(event, run_id, attempt, current, files):
    head = event["pull_request"]["head"]["sha"]
    if current["head"]["sha"] != head or current["state"] != "open" or current["draft"]:
        raise IncompleteReview("The PR head is stale, closed or still a draft.")
    if len(files) != current["changed_files"] or not files:
        raise IncompleteReview("GitHub did not return the complete changed-file list.")
    paths = [f["filename"] for f in files]
    if len(paths) != len(set(paths)):
        raise IncompleteReview("The changed-file list contains duplicates.")
    batches, batch, size, lines = [], [], 0, 0
    for file in files:
        patch_size = len(file.get("patch") or "")
        patch_lines = len((file.get("patch") or "").splitlines())
        if batch and (len(batch) >= 5 or size + patch_size > 50_000 or lines + patch_lines > 800):
            batches.append(batch)
            batch, size, lines = [], 0, 0
        batch.append(file)
        size += patch_size
        lines += patch_lines
    if batch:
        batches.append(batch)
    return {
        "repository": event["repository"]["full_name"], "number": event["pull_request"]["number"],
        "head": head, "run_id": str(run_id), "attempt": str(attempt), "files": paths,
        "title": current.get("title", ""), "description": current.get("body") or "",
        "shards": [{"id": i, "files": batch} for i, batch in enumerate(batches)],
    }


def validate_plan_context(plan, event, run_id, attempt):
    expected = (event["repository"]["full_name"], event["pull_request"]["number"],
                event["pull_request"]["head"]["sha"], str(run_id), str(attempt))
    actual = tuple(plan[k] for k in ("repository", "number", "head", "run_id", "attempt"))
    if actual != expected:
        raise IncompleteReview("The review artifact belongs to a different PR, head or workflow attempt.")


def review_patch_view(file):
    patch = file.get("patch") or ""
    if Path(file["filename"]).suffix.lower() in {".md", ".markdown"}:
        # This is only a reading view. build_plan retains the exact GitHub patch
        # in manifest.json; source files and attribution bytes are never edited.
        return patch.translate({0xE0100: None, 0xE0101: None})
    return patch


def verify_shard(messages, plan, shard_id):
    report, diagnostic = validate_execution(messages)
    expected = {f["filename"] for f in plan["shards"][shard_id]["files"]}
    if (report["reviewed_head_sha"] != plan["head"] or set(report["reviewed_files"]) != expected
            or not isinstance(report.get("summary"), str) or not report["summary"].strip()
            or len(report["summary"]) > 3000):
        raise IncompleteReview("The shard report is incomplete, has the wrong head or has invalid summary data.")
    return {"shard": shard_id, "head": plan["head"], "run_id": plan["run_id"],
            "attempt": plan["attempt"], "verified": True, "files": sorted(expected),
            "summary": report["summary"], "warning": diagnostic}


def combine_results(plan, receipts):
    by_id, errors, reviewed, summaries = {}, [], set(), []
    for receipt in receipts:
        i = receipt["shard"]
        if not isinstance(i, int) or i < 0 or i >= len(plan["shards"]) or i in by_id:
            raise IncompleteReview("Duplicate or unknown review shard artifacts.")
        by_id[i] = receipt
    for shard in plan["shards"]:
        receipt = by_id.get(shard["id"])
        if not receipt:
            errors.append(f"Review {shard['id'] + 1}: result missing.")
            continue
        if any(receipt[k] != plan[k] for k in ("head", "run_id", "attempt")):
            raise IncompleteReview("A review result belongs to a different head or workflow attempt.")
        expected = {f["filename"] for f in shard["files"]}
        if receipt.get("verified") is not True or set(receipt.get("files", [])) != expected:
            detail = receipt.get("error", "incomplete or invalid coverage")
            errors.append(f"Review {shard['id'] + 1}: {detail}")
            if explanation := receipt.get("blocker_summary"):
                errors.append(f"Review {shard['id'] + 1} explanation: {explanation[:800]}")
            continue
        reviewed.update(expected)
        summaries.append((shard["id"] + 1, receipt["summary"], receipt.get("warning", "")))
    if reviewed != set(plan["files"]) and not errors:
        errors.append("The combined review does not cover every changed file.")
    return reviewed, summaries, errors


def github_post(endpoint, body):
    import tempfile
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as payload:
        json.dump({"body": body}, payload)
        payload.flush()
        try:
            response = subprocess.run(["gh", "api", "--method", "POST", endpoint, "--input", payload.name],
                                      capture_output=True, text=True, check=True, timeout=60)
            return json.loads(response.stdout)
        except (subprocess.SubprocessError, ValueError, OSError):
            raise IncompleteReview("Could not publish the combined review through GitHub.") from None


def batch_command(mode):
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    run_id, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
    plan_dir = Path(os.environ["REVIEW_PLAN_DIR"])
    repo, number = event["repository"]["full_name"], event["pull_request"]["number"]
    if mode == "plan":
        current = github_fetch(f"repos/{repo}/pulls/{number}")
        pages = github_fetch(f"repos/{repo}/pulls/{number}/files?per_page=100", paginate=True)
        plan = build_plan(event, run_id, attempt, current, [f for page in pages for f in page])
        plan_dir.mkdir(parents=True, exist_ok=True)
        (plan_dir / "manifest.json").write_text(json.dumps(plan))
        for shard in plan["shards"]:
            data = {k: plan[k] for k in ("repository", "number", "head", "title", "description")}
            # Read truncates long lines. Keep paths visible before the patches and
            # serialize each diff line separately so the reviewer can read them.
            assigned = {
                **data, "id": shard["id"],
                "provenance_note": (
                    "Markdown patch_lines is a visible-text reading view. Exact patches and "
                    "TextProv attribution remain in manifest.json and the checkout. Preserve source marks."
                ),
                "assigned_paths": [f["filename"] for f in shard["files"]],
                "files": [{"filename": f["filename"], "status": f.get("status"),
                           "patch_available": bool(f.get("patch")),
                           "patch_lines": review_patch_view(f).splitlines()}
                          for f in shard["files"]],
            }
            (plan_dir / f"shard-{shard['id']}.json").write_text(
                json.dumps(assigned, indent=2, ensure_ascii=False), encoding="utf-8")
        matrix = {"include": [{"shard": s["id"]} for s in plan["shards"]]}
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("matrix=" + json.dumps(matrix) + "\n")
        print(f"Planned {len(plan['files'])} files across {len(plan['shards'])} bounded reviews.")
        return 0

    plan = json.loads((plan_dir / "manifest.json").read_text())
    validate_plan_context(plan, event, run_id, attempt)
    result_dir = Path(os.environ["REVIEW_RESULT_DIR"])
    if mode == "shard":
        shard_id = int(os.environ["REVIEW_SHARD"])
        if shard_id < 0 or shard_id >= len(plan["shards"]):
            raise IncompleteReview("Unknown review shard.")
        messages = None
        try:
            execution = os.environ.get("CLAUDE_EXECUTION_FILE") or str(
                Path(os.environ["RUNNER_TEMP"]) / "claude-execution-output.json")
            messages = json.loads(Path(execution).read_text())
            receipt = verify_shard(messages, plan, shard_id)
            if receipt["warning"]:
                print("::warning::" + receipt["warning"])
        except (IncompleteReview, OSError, ValueError, KeyError, TypeError) as error:
            # Never put raw SDK content or exception input into retained artifacts.
            receipt = {"shard": shard_id, "head": plan["head"], "run_id": str(run_id),
                       "attempt": str(attempt), "verified": False, "files": [],
                       "error": str(error) if isinstance(error, IncompleteReview)
                       else "Required execution output is missing or invalid."}
            # Retain only the model's bounded, structured summary, as we do on
            # success. Never retain transcript messages or raw provider errors.
            results = ([m for m in messages if isinstance(m, dict) and m.get("type") == "result"]
                       if isinstance(messages, list) else [])
            if (len(results) == 1 and results[0].get("subtype") == "success"
                    and results[0].get("is_error") is False
                    and isinstance(report := results[0].get("structured_output"), dict)
                    and isinstance(explanation := report.get("summary"), str)
                    and 0 < len(explanation.strip()) <= 3000):
                receipt["blocker_summary"] = explanation
        result_dir.mkdir(parents=True, exist_ok=True)
        (result_dir / f"result-{shard_id}.json").write_text(json.dumps(receipt))
        if not receipt["verified"]:
            raise IncompleteReview(f"Review {shard_id + 1} did not complete its assigned files.")
        print(f"Verified review {shard_id + 1}: {len(receipt['files'])} assigned files.")
        return 0

    receipts = [json.loads(p.read_text()) for p in result_dir.glob("result-*.json")]
    reviewed, summaries, errors = combine_results(plan, receipts)
    if os.environ.get("REVIEW_JOBS_RESULT") != "success":
        errors.append("The review jobs did not all finish successfully.")
    current = github_fetch(f"repos/{repo}/pulls/{number}")
    pages = github_fetch(f"repos/{repo}/pulls/{number}/files?per_page=100", paginate=True)
    if (current["head"]["sha"] != plan["head"] or current["state"] != "open" or current["draft"]
            or {f["filename"] for p in pages for f in p} != set(plan["files"])):
        raise IncompleteReview("The PR changed during review; refusing to publish a stale result.")
    state = "Incomplete" if errors else "Completed"
    body = (f"## Claude code review — {state.lower()}\n\nReviewed head: `{plan['head']}`\n\n"
            f"{state}: {len(reviewed)}/{len(plan['files'])} changed files across "
            f"{len(plan['shards'])} bounded reviews. Findings are static analysis, not runtime validation.\n\n")
    if errors:
        body += "\n".join(f"- {error}" for error in errors) + "\n\n"
    for i, summary, warning in summaries[:40]:
        body += f"### Review {i}\n\n{summary[:800]}\n\n"
        if warning:
            body += f"Tool warning: {warning}\n\n"
    body += f"[Workflow and review artifacts](https://github.com/{repo}/actions/runs/{run_id})\n\n"
    marker = f"<!-- claude-review:{plan['head']}:{run_id}:{attempt} -->"
    if not errors:
        body += marker
    else:
        body += f"<!-- claude-review-incomplete:{plan['head']}:{run_id}:{attempt} -->"
    posted = github_post(f"repos/{repo}/issues/{number}/comments", body)
    print("Published combined Claude review: " + posted["html_url"])
    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary_path, "a") as output:
            output.write(body + "\n")
    if errors:
        raise IncompleteReview("The combined review is incomplete; see the published report.")
    validate_publication(event, run_id, attempt, github_fetch, list(reviewed), author="github-actions[bot]")
    return 0


def entrypoint():
    if len(sys.argv) == 1:
        return main()
    try:
        if sys.argv[1] not in {"plan", "shard", "publish"}:
            raise IncompleteReview("Unknown review workflow command.")
        return batch_command(sys.argv[1])
    except IncompleteReview as error:
        print(f"::error::Claude review incomplete: {error}")
    except (OSError, ValueError, KeyError, TypeError):
        print("::error::Claude review incomplete: required review artifacts or metadata are missing or invalid.")
    return 1


if __name__ == "__main__":
    sys.exit(entrypoint())

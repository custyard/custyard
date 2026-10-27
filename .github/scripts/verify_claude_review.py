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
        raise IncompleteReview("Claude encountered tool permission denials." + detail)


def validate_publication(event, run_id, attempt, fetch):
    repository = event["repository"]["full_name"]
    number = event["pull_request"]["number"]
    expected_head = event["pull_request"]["head"]["sha"]
    current = fetch(f"repos/{repository}/pulls/{number}")
    if current["head"]["sha"] != expected_head:
        raise IncompleteReview("The PR head changed during the review; review the new head.")
    if current["state"] != "open" or current["draft"]:
        raise IncompleteReview("The PR is no longer open and ready for review.")

    marker = f"<!-- claude-review:{expected_head}:{run_id}:{attempt} -->"
    pages = fetch(f"repos/{repository}/issues/{number}/comments?per_page=100", paginate=True)
    for page in pages:
        for comment in page:
            body = comment.get("body") or ""
            if (comment.get("user", {}).get("login") == "claude[bot]"
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
    try:
        execution = os.environ.get("CLAUDE_EXECUTION_FILE") or str(
            Path(os.environ["RUNNER_TEMP"]) / "claude-execution-output.json"
        )
        if not Path(execution).is_file():
            raise IncompleteReview("Claude produced no execution output; the action was skipped or failed before starting.")
        validate_execution(json.loads(Path(execution).read_text()))
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        url = validate_publication(
            event, os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"], github_fetch
        )
        message = f"Claude review completed and published: {url}"
        status = 0
    except IncompleteReview as error:
        message = f"Claude review incomplete: {error}"
        status = 1
    except (OSError, ValueError, KeyError, TypeError):
        message = "Claude review incomplete: required execution or GitHub metadata is missing or invalid."
        status = 1

    print(("::error::" if status else "") + message)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as report:
            report.write(f"### Claude review {'incomplete' if status else 'completed'}\n\n{message}\n")
    return status


if __name__ == "__main__":
    sys.exit(main())

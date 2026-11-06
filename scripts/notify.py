"""Opens a GitHub issue for each new problem the build found, so GitHub emails
and notifies you. Closes alert issues once SolarEdge no longer reports them.

Run by the Build and deploy workflow with the workflow's own token.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

LABEL = "solar-alert"
REPO = os.environ.get("GITHUB_REPOSITORY", "")


def gh(*args, input=None):
    return subprocess.run(["gh", *args, "--repo", REPO], input=input, capture_output=True, text=True, check=True).stdout


def main():
    path = Path(__file__).resolve().parent.parent / "problems.json"
    if not path.exists():
        return
    data = json.loads(path.read_text())
    problems = data.get("problems") or []
    try:
        gh("label", "create", LABEL, "--color", "D97706", "--description", "Raised by Home Solar", "--force")
    except subprocess.CalledProcessError:
        pass
    # every issue this app has opened, open or closed, keyed by the marker in its body
    issues = json.loads(gh("issue", "list", "--label", LABEL, "--state", "all", "--limit", "200", "--json", "number,state,body"))
    seen = {}
    for i in issues:
        body = i.get("body") or ""
        if "<!-- key:" in body:
            seen[body.split("<!-- key:", 1)[1].split(" -->", 1)[0]] = i
    keys = set()
    for p in problems:
        keys.add(p["key"])
        if p["key"] in seen:
            continue  # reported already; don't nag
        body = p["body"] + f"\n\n<!-- key:{p['key']} -->"
        gh("issue", "create", "--title", p["title"], "--label", LABEL, "--body-file", "-", input=body)
        print(f"opened: {p['title']}")
    if data.get("alertsChecked"):
        for key, i in seen.items():
            if key.startswith("alert-") and key not in keys and i["state"] == "OPEN":
                gh("issue", "close", str(i["number"]), "--comment", "SolarEdge no longer reports this alert.")
                print(f"closed: {key}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        sys.exit(f"::warning::Couldn't update problem issues: {e.stderr.strip()[:300]}")

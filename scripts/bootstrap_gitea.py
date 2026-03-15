#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
import time
from shutil import which
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT / ".env"
BOOTSTRAP_FILE = ROOT / "generated" / "bootstrap-users.json"


def compose_base_command() -> list[str]:
    docker = which("docker")
    if docker:
        probe = subprocess.run(
            [docker, "compose", "version"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if probe.returncode == 0:
            return [docker, "compose"]

    legacy = which("docker-compose")
    if legacy:
        return [legacy]

    raise SystemExit("Neither 'docker compose' nor 'docker-compose' is available.")


def load_env(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key, _, value = stripped.partition("=")
        data[key] = value
    return data


def compose_command(*args: str, capture_output: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [*compose_base_command(), *args],
        cwd=ROOT,
        text=True,
        capture_output=capture_output,
        check=False,
    )


def wait_for_gitea() -> None:
    for attempt in range(60):
        result = compose_command("exec", "-T", "gitea", "gitea", "admin", "user", "list", capture_output=True)
        if result.returncode == 0:
            return
        print(f"[wait] Gitea not ready yet ({attempt + 1}/60).", file=sys.stderr)
        time.sleep(5)
    raise SystemExit("Timed out waiting for the gitea service to become ready.")


def create_user(user: dict, password: str) -> None:
    command = [
        "exec",
        "-T",
        "gitea",
        "gitea",
        "admin",
        "user",
        "create",
        "--username",
        user["username"],
        "--password",
        password,
        "--email",
        user["email"],
        "--must-change-password",
    ]
    if user["gitea_admin"]:
        command.append("--admin")

    result = compose_command(*command, capture_output=True)
    combined = f"{result.stdout}\n{result.stderr}".lower()
    if result.returncode == 0:
        print(f"[ok] created {user['username']}")
        return
    if "already exists" in combined or "already in use" in combined:
        print(f"[skip] {user['username']} already exists")
        return
    raise SystemExit(f"Failed to create {user['username']}:\n{result.stdout}{result.stderr}")


def main() -> int:
    if not ENV_FILE.exists():
        raise SystemExit("Missing .env. Copy .env.example to .env and fill in passwords first.")
    if not BOOTSTRAP_FILE.exists():
        raise SystemExit("Missing generated/bootstrap-users.json. Run scripts/render_inventory.py first.")

    env = load_env(ENV_FILE)
    password = env.get("GITEA_INITIAL_PASSWORD")
    if not password:
        raise SystemExit("GITEA_INITIAL_PASSWORD is required in .env.")

    payload = json.loads(BOOTSTRAP_FILE.read_text(encoding="utf-8"))
    users = sorted(payload["users"], key=lambda item: (not item["gitea_admin"], item["username"]))

    wait_for_gitea()
    for user in users:
        create_user(user, password)

    print(f"Bootstrapped {len(users)} Gitea users.")
    print("Note: Gitea CLI bootstrap sets username, email, admin flag, and must-change-password. Full name remains tracked in inventory/users.yaml.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

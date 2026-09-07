#!/usr/bin/env python3
"""
Seed the Gitea demo instance with a deterministic dataset.

Deterministic on purpose: the same seed run always produces the same users,
repos and file contents, so a restored instance can be compared byte for byte
against the original.

Usage:
    ./scripts/seed.py
    ./scripts/seed.py --users 100 --repos-per-user 2

Requires: requests  (pip install requests)
"""

import argparse
import base64
import hashlib
import os
import sys
import time
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("Missing dependency. Run: pip install requests")


def load_env(path: Path) -> dict:
    """Minimal .env reader — avoids a python-dotenv dependency."""
    if not path.exists():
        sys.exit(f"No {path} found. Copy .env.example to .env first.")
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        env[key.strip()] = value.strip()
    return env


class Gitea:
    def __init__(self, base_url: str, user: str, password: str):
        self.api = f"{base_url.rstrip('/')}/api/v1"
        self.session = requests.Session()
        self.session.auth = (user, password)
        self.session.headers["Content-Type"] = "application/json"

    def wait_ready(self, timeout: int = 120) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                r = self.session.get(f"{self.api}/version", timeout=5)
                if r.ok:
                    print(f"    Gitea {r.json().get('version')} reachable")
                    return
            except requests.RequestException:
                pass
            time.sleep(3)
        sys.exit("Gitea did not become reachable. Check: docker compose logs gitea")

    def create_user(self, username: str, email: str, password: str) -> bool:
        r = self.session.post(
            f"{self.api}/admin/users",
            json={
                "username": username,
                "email": email,
                "password": password,
                "must_change_password": False,
            },
            timeout=15,
        )
        if r.status_code == 201:
            return True
        if r.status_code == 422:  # already exists
            return False
        r.raise_for_status()
        return False

    def create_repo(self, username: str, name: str, description: str) -> bool:
        r = self.session.post(
            f"{self.api}/admin/users/{username}/repos",
            json={
                "name": name,
                "description": description,
                "private": False,
                "auto_init": True,
                "default_branch": "main",
                "readme": "Default",
            },
            timeout=30,
        )
        if r.status_code == 201:
            return True
        if r.status_code in (409, 422):  # already exists
            return False
        r.raise_for_status()
        return False

    def add_file(self, owner: str, repo: str, path: str, content: str) -> bool:
        r = self.session.post(
            f"{self.api}/repos/{owner}/{repo}/contents/{path}",
            json={
                "content": base64.b64encode(content.encode()).decode(),
                "message": f"Add {path}",
                "branch": "main",
            },
            timeout=30,
        )
        if r.status_code == 201:
            return True
        if r.status_code in (409, 422):
            return False
        r.raise_for_status()
        return False


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    env = load_env(root / ".env")

    parser = argparse.ArgumentParser()
    parser.add_argument("--users", type=int, default=int(env.get("SEED_USERS", 50)))
    parser.add_argument(
        "--repos-per-user", type=int, default=int(env.get("SEED_REPOS_PER_USER", 4))
    )
    args = parser.parse_args()

    base_url = f"http://{env.get('GITEA_DOMAIN', 'localhost')}:{env.get('GITEA_PORT', '3000')}"
    gitea = Gitea(base_url, env["GITEA_ADMIN_USER"], env["GITEA_ADMIN_PASSWORD"])

    print(f"==> Connecting to {base_url}")
    gitea.wait_ready()

    created_users = created_repos = created_files = 0

    print(f"==> Seeding {args.users} users x {args.repos_per_user} repos")
    for i in range(1, args.users + 1):
        username = f"demo{i:03d}"
        if gitea.create_user(username, f"{username}@example.test", f"DemoPass{i:03d}!"):
            created_users += 1

        for j in range(1, args.repos_per_user + 1):
            repo = f"project-{j:02d}"
            if gitea.create_repo(username, repo, f"Demo repository {j} for {username}"):
                created_repos += 1

            # Deterministic content: same seed run -> identical bytes
            payload = f"{username}/{repo}\n" + "\n".join(
                f"line {n:04d} {hashlib.sha256(f'{username}{repo}{n}'.encode()).hexdigest()}"
                for n in range(1, 51)
            )
            if gitea.add_file(username, repo, "data/records.txt", payload):
                created_files += 1

        if i % 10 == 0:
            print(f"    {i}/{args.users} users done")

    print()
    print(f"Users created:  {created_users}")
    print(f"Repos created:  {created_repos}")
    print(f"Files created:  {created_files}")
    print()
    print("Next: ./scripts/fingerprint.sh > baseline.json")


if __name__ == "__main__":
    main()

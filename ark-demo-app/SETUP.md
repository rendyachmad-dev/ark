# Ark demo workload — Gitea + PostgreSQL

The test subject for Ark. Not part of Ark itself — this is just a realistic
stateful application to back up, destroy, and restore.

Why Gitea: two volumes with genuinely different characteristics (a Git object
store on disk, and relational data in Postgres), a health endpoint, and a
failure scenario anyone immediately understands — losing your own Git server.

---

## Requirements

- Docker and the Compose plugin
- Python 3 with `requests` (`pip install requests --break-system-packages` on Ubuntu 24.04)
- `jq` for comparing fingerprints (`sudo apt install jq`)
- ~2 GB free RAM

---

## Run it

```bash
cd ark-demo-app
cp .env.example .env
```

Generate a secret key and paste it into `.env` as `GITEA_SECRET_KEY`:

```bash
docker run --rm gitea/gitea:1.24 gitea generate secret SECRET_KEY
```

Edit the rest of `.env` — at minimum change both passwords. If you want to
reach Gitea from your laptop, set `GITEA_DOMAIN` to the VPS IP.

Then:

```bash
chmod +x bootstrap.sh scripts/*.sh scripts/*.py
./bootstrap.sh
```

This starts both containers, waits for the health check, and creates the admin
account. Re-running it is safe.

## Seed the data

```bash
./scripts/seed.py
```

Defaults to 50 users x 4 repos, each with a committed file. Takes a few
minutes. Adjust with `--users` and `--repos-per-user`.

The content is deterministic — the same seed run always produces identical
bytes, which is what lets a restored instance be compared exactly.

## Capture the baseline

```bash
./scripts/fingerprint.sh > baseline.json
cat baseline.json
```

Expected shape:

```json
{
  "captured_at": "2026-09-07T14:22:10Z",
  "database": {
    "users": 51,
    "repositories": 200,
    "actions": 400,
    "users_hash": "a3f5..."
  },
  "storage": {
    "git_repositories_sha256": "9c1e..."
  }
}
```

`users` is 51 because the admin account is included.

**Commit `baseline.json` to the Ark repo.** Every drill compares against it.

---

## Prove the fingerprint actually detects loss

Worth doing once, before writing any backup code — it confirms the check has
teeth:

```bash
docker compose down -v          # destroys both volumes
./bootstrap.sh                  # fresh, empty instance
./scripts/fingerprint.sh > empty.json
diff <(jq -S . baseline.json) <(jq -S . empty.json)
```

The diff should be large. Now re-seed and re-fingerprint: counts return, but
`git_repositories_sha256` will **not** match, because Git commit objects embed
timestamps. That is the correct behaviour and an important lesson for Ark:

> A restore is only valid if it restores the actual bytes. Re-creating
> equivalent-looking data is not recovery.

This is exactly why Ark backs up volumes rather than replaying seed scripts.

---

## Everyday commands

```bash
docker compose ps                    # status
docker compose logs -f gitea         # logs
docker compose down                  # stop, keep data
docker compose down -v               # stop and destroy data
docker compose exec -T db psql -U gitea -d gitea   # database shell
```

---

## What Ark will back up

| Source | Contents |
|---|---|
| `pg-data` volume | Users, repositories, permissions, issues |
| `gitea-data` volume | Git object store, avatars, attachments, config |
| `.env` | Credentials and configuration |
| `docker-compose.yml` | Stack definition |

Two volumes plus configuration — small enough to iterate on quickly, real
enough that the restore logic transfers to anything else.

---

## Next

Week 1 of the Ark plan: build the `ark-backup` Ansible role that captures
these two volumes plus a `pg_dump`, writes a manifest with SHA-256 checksums,
and proves a local restore reproduces `baseline.json` exactly.

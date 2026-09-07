#!/usr/bin/env bash
# Emit a JSON fingerprint of the current stack state.
#
# This is what makes an Ark drill meaningful: run it before backup, run it
# again after restore, and the two files must match. If they don't, the
# recovery failed even if the app appears to be running.
#
# Usage:
#   ./scripts/fingerprint.sh > baseline.json
#   ./scripts/fingerprint.sh > restored.json
#   diff <(jq -S . baseline.json) <(jq -S . restored.json) && echo MATCH

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; source .env; set +a

psql() {
  docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc "$1"
}

# Row counts. "user" is a reserved word in Postgres, hence the quotes.
users=$(psql 'SELECT count(*) FROM "user";')
repos=$(psql 'SELECT count(*) FROM repository;')
actions=$(psql 'SELECT count(*) FROM action;')

# Content-level hash of the user table, ordered so it is stable across restores.
users_hash=$(psql "SELECT md5(string_agg(name || ':' || email, ',' ORDER BY id)) FROM \"user\";")

# Hash of the actual Git object store — the part that matters most.
# Ordered by path so filesystem iteration order cannot affect the result.
repo_hash=$(docker compose exec -T gitea sh -c '
  if [ -d /data/git/repositories ]; then
    find /data/git/repositories -type f -print0 \
      | sort -z \
      | xargs -0 sha256sum 2>/dev/null \
      | sha256sum \
      | cut -d" " -f1
  else
    echo "no-repositories"
  fi
')

cat <<JSON
{
  "captured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "database": {
    "users": ${users},
    "repositories": ${repos},
    "actions": ${actions},
    "users_hash": "${users_hash}"
  },
  "storage": {
    "git_repositories_sha256": "${repo_hash}"
  }
}
JSON

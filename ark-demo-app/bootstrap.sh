#!/usr/bin/env bash
# Bring up the demo stack and create the admin account.
# Safe to re-run: it skips the admin creation if the user already exists.
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "No .env found. Run: cp .env.example .env  (then edit it)" >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

echo "==> Starting containers"
docker compose up -d

echo "==> Waiting for Gitea to become healthy"
for i in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' ark-gitea 2>/dev/null || echo starting)
  if [[ "$status" == "healthy" ]]; then
    echo "    healthy after ${i}0s"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "Gitea did not become healthy. Check: docker compose logs gitea" >&2
    exit 1
  fi
  sleep 10
done

echo "==> Ensuring admin user exists"
if docker compose exec -T -u git gitea gitea admin user list 2>/dev/null \
     | awk '{print $2}' | grep -qx "${GITEA_ADMIN_USER}"; then
  echo "    admin '${GITEA_ADMIN_USER}' already exists, skipping"
else
  docker compose exec -T -u git gitea gitea admin user create \
    --admin \
    --username "${GITEA_ADMIN_USER}" \
    --password "${GITEA_ADMIN_PASSWORD}" \
    --email "${GITEA_ADMIN_EMAIL}" \
    --must-change-password=false
  echo "    admin '${GITEA_ADMIN_USER}' created"
fi

echo
echo "Gitea is up at http://${GITEA_DOMAIN}:${GITEA_PORT}/"
echo "Next: ./scripts/seed.py   then   ./scripts/fingerprint.sh"

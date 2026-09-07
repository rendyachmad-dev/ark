# ark-backup / ark-restore — Week 1

Local backup and restore for the demo stack. No AWS yet — the goal this week is
to prove that a restore reproduces the source **byte for byte**, not merely that
the application comes back up.

---

## Install

```bash
cd ~/ark
sudo apt install -y ansible
```

Extract this bundle so the layout is:

```
~/ark/
├── docker-compose.yml
├── .env
├── scripts/
│   ├── seed.py
│   └── fingerprint.sh
├── ansible.cfg
├── backup.yml
├── restore.yml
└── roles/
    ├── ark-backup/
    └── ark-restore/
```

## Check your variables first

```bash
docker volume ls
```

The volume names must match `{{ ark_compose_project }}_{{ volume }}`. If yours
are `ark_gitea-data` and `ark_pg-data`, the defaults are correct. If your
directory is named something else, Compose derives a different project name —
set it in `roles/ark-backup/defaults/main.yml` and the restore defaults.

Also confirm `ark_stack_dir` matches your actual path.

## Back up

```bash
ansible-playbook backup.yml
```

What happens, in order:

1. Fingerprint the running stack — this goes **inside the manifest**
2. `pg_dump` the database while it is still running
3. Stop the Gitea container briefly, archive both volumes, start it again
4. Archive `.env` and `docker-compose.yml`
5. Compute SHA-256 for every artefact and write `manifest.json`
6. Prune old backups beyond the retention count

Output lands in `/var/backups/ark/<timestamp>/`:

```
database.sql.gz
volume-gitea-data.tar.gz
volume-pg-data.tar.gz
config.tar.gz
manifest.json
```

Inspect it:

```bash
sudo cat /var/backups/ark/*/manifest.json | jq .
```

## Restore — the part that matters

**Destructive.** It runs `docker compose down -v`, which destroys the current
volumes.

```bash
ansible-playbook restore.yml
```

Or a specific backup:

```bash
ansible-playbook restore.yml -e ark_backup_id=20260908T031500
```

The sequence is deliberately ordered so nothing is destroyed until the backup
has been proven intact:

1. Read the manifest
2. **Verify every checksum** — abort on any mismatch, before touching volumes
3. Tear down the stack and its volumes
4. Restore volume archives and configuration
5. Bring the stack up, wait for Postgres and the health endpoint
6. Apply the SQL dump as a second line of defence
7. Fingerprint the restored stack and **assert it matches the manifest**

Step 7 is the whole point. If row counts match but `git_repositories_sha256`
does not, the playbook fails — because that is not a recovery.

---

## The test that proves it works

Run this end to end. It is the deliverable for week 1.

```bash
# 1. Baseline
cd ~/ark
./scripts/fingerprint.sh | jq -r '.storage.git_repositories_sha256'

# 2. Back up
ansible-playbook backup.yml

# 3. Destroy everything
docker compose down -v

# 4. Restore
ansible-playbook restore.yml
```

Expected final output:

```
TASK [ark-restore : Compare against the manifest]
    users:        51 -> 51
    repositories: 200 -> 200
    users_hash:   MATCH
    git_sha256:   MATCH

TASK [ark-restore : Fail if the restored content does not match the source]
ok: [localhost] => changed=false
  msg: Restore verified. Content is byte-identical to the source.
```

If `git_sha256` says MATCH after a full destroy, the backup is real.

**Screenshot that output.** It goes in the Ark README, and it is the single
most convincing artefact you will produce this week.

---

## Design notes worth keeping

**Why the fingerprint lives in the manifest.** A backup that depends on an
external `baseline.json` is only verifiable on the machine that made it. Putting
the source fingerprint inside the manifest makes every backup self-describing —
which is what allows a drill on a fresh EC2 instance in week 6 to verify itself
with nothing but the S3 objects.

**Why the app stops during backup.** Archiving a live Git object store risks a
torn snapshot. The stop lasts a few seconds and the database stays up. Set
`ark_stop_app_during_backup: false` to trade consistency for zero downtime —
but then the backup is no longer trustworthy, and Ark should not pretend
otherwise.

**Why both a volume archive and a SQL dump.** The `pg-data` volume alone can
restore the database. The dump is redundancy: if the volume archive is torn,
the logical dump still rebuilds a consistent database. Cheap insurance.

**Why config is backed up.** `GITEA_SECRET_KEY` decrypts session and token
material in the database. Restoring data without it produces a running
application that cannot read its own records — the exact class of failure that
only surfaces during a real incident.

---

## Next — Week 2

- Terraform: S3 bucket, versioning, lifecycle to Glacier, least-privilege IAM
- Extend `ark-backup` to upload the backup directory after the manifest is written
- Extend `ark-restore` to pull from S3 when the local copy is absent

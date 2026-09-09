#!/usr/bin/env bash
# ============================================================================
# ark drill — prove your backup works by restoring it on a fresh EC2 instance
#
# Usage:
#   ./scripts/drill.sh                  # restore the latest backup
#   ./scripts/drill.sh 20260909T025355  # restore a specific backup
#
# Prerequisites:
#   - terraform/pilot-light applied (launch template exists)
#   - At least one backup in S3
#   - AWS CLI configured with terraform-ark credentials
#   - SSH private key at ~/.ssh/id_ed25519
# ============================================================================

set -euo pipefail

ARK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PILOT_LIGHT_DIR="${ARK_ROOT}/terraform/pilot-light/pilot-light"
DRILL_LOG="${ARK_ROOT}/docs/drills.md"
SSH_KEY="${HOME}/.ssh/id_ed25519"
SSH_USER="ubuntu"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Load .env for bucket info
set -a; source "${ARK_ROOT}/.env"; set +a

BUCKET="${ARK_S3_BUCKET}"
REGION="${ARK_S3_REGION:-ap-southeast-1}"
PREFIX="${ARK_S3_PREFIX:-backups/}"
BACKUP_ID="${1:-latest}"

# Read pilot-light terraform outputs
cd "${PILOT_LIGHT_DIR}"
LAUNCH_TEMPLATE_ID=$(terraform output -raw launch_template_id)
LAUNCH_TEMPLATE_VERSION=$(terraform output -raw launch_template_latest_version)

# ============================================================================
# Helper functions
# ============================================================================

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { log "FATAL: $*"; cleanup; exit 1; }
elapsed() {
  local start=$1
  local end=$(date +%s)
  local delta=$((end - start))
  printf '%dm %02ds' $((delta / 60)) $((delta % 60))
}

INSTANCE_ID=""
cleanup() {
  if [[ -n "${INSTANCE_ID}" ]]; then
    log "Terminating instance ${INSTANCE_ID}..."
    aws ec2 terminate-instances \
      --instance-ids "${INSTANCE_ID}" \
      --region "${REGION}" \
      --output text > /dev/null 2>&1 || true
    log "Terminate request sent."
  fi
}
trap cleanup EXIT

# ============================================================================
# 0. Resolve backup ID
# ============================================================================

if [[ "${BACKUP_ID}" == "latest" ]]; then
  log "Finding the latest backup in s3://${BUCKET}/${PREFIX}..."
  BACKUP_ID=$(aws s3api list-objects-v2 \
    --bucket "${BUCKET}" \
    --prefix "${PREFIX}" \
    --delimiter "/" \
    --query 'CommonPrefixes[-1].Prefix' \
    --output text \
    --region "${REGION}" \
    | sed "s|${PREFIX}||; s|/||")
fi

log "Drill target: backup ${BACKUP_ID}"

# Verify manifest exists in S3
aws s3api head-object \
  --bucket "${BUCKET}" \
  --key "${PREFIX}${BACKUP_ID}/manifest.json" \
  --region "${REGION}" > /dev/null 2>&1 \
  || fail "Manifest not found for backup ${BACKUP_ID}"

# Calculate RPO: time since the backup was created
MANIFEST_JSON=$(aws s3 cp "s3://${BUCKET}/${PREFIX}${BACKUP_ID}/manifest.json" - --region "${REGION}")
BACKUP_CREATED=$(echo "${MANIFEST_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['created_at'])")
BACKUP_EPOCH=$(date -d "${BACKUP_CREATED}" +%s 2>/dev/null || date -u +%s)
RPO_SECONDS=$(( $(date +%s) - BACKUP_EPOCH ))
RPO_MINUTES=$(( RPO_SECONDS / 60 ))

log "Backup created at: ${BACKUP_CREATED}"
log "RPO: ${RPO_MINUTES}m (${RPO_SECONDS}s since last backup)"

# ============================================================================
# 1. Launch EC2 instance
# ============================================================================

DRILL_START=$(date +%s)
STEP_START=$(date +%s)

log "Launching EC2 instance from template ${LAUNCH_TEMPLATE_ID}..."
INSTANCE_ID=$(aws ec2 run-instances \
  --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${LAUNCH_TEMPLATE_VERSION}" \
  --region "${REGION}" \
  --query 'Instances[0].InstanceId' \
  --output text)

log "Instance: ${INSTANCE_ID}"

# Wait for running state
log "Waiting for instance to enter running state..."
aws ec2 wait instance-running \
  --instance-ids "${INSTANCE_ID}" \
  --region "${REGION}"

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${REGION}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

log "Public IP: ${PUBLIC_IP}"
TIME_PROVISION=$(elapsed ${STEP_START})
log "Provision: ${TIME_PROVISION}"

# ============================================================================
# 2. Wait for SSH + user data to finish
# ============================================================================

STEP_START=$(date +%s)
log "Waiting for SSH..."

for i in $(seq 1 60); do
  if ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${PUBLIC_IP}" "true" 2>/dev/null; then
    break
  fi
  if [[ $i -eq 60 ]]; then
    fail "Timed out waiting for SSH (5 minutes)"
  fi
  sleep 5
done

TIME_READY=$(elapsed ${STEP_START})
log "SSH ready: ${TIME_READY}"

# ============================================================================
# 3. Install Docker + AWS CLI, then download backup
# ============================================================================

STEP_START=$(date +%s)
log "Installing Docker and AWS CLI on instance..."

ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${PUBLIC_IP}" <<'BOOTSTRAP'
set -euo pipefail

# Docker
if ! command -v docker &>/dev/null; then
  # Wait for cloud-init / user-data apt to finish
#  while sudo fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
  sudo cloud-init status --wait > /dev/null 2>&1 || true
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl unzip
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# AWS CLI
if ! command -v aws &>/dev/null; then
  sudo rm -rf /tmp/aws /tmp/awscliv2.zip
  cd /tmp
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  unzip -qq awscliv2.zip
  sudo ./aws/install
fi

echo "Bootstrap complete: docker=$(docker --version), aws=$(aws --version)"
BOOTSTRAP

log "Bootstrap complete: $(elapsed ${STEP_START})"

# Copy stack files
log "Copying stack files to instance..."

ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${PUBLIC_IP}" \
  "sudo mkdir -p /home/${SSH_USER}/ark/scripts /var/backups/ark/${BACKUP_ID}"

scp ${SSH_OPTS} -i "${SSH_KEY}" \
  "${ARK_ROOT}/docker-compose.yml" \
  "${ARK_ROOT}/.env" \
  "${SSH_USER}@${PUBLIC_IP}:/tmp/"

scp ${SSH_OPTS} -i "${SSH_KEY}" \
  "${ARK_ROOT}/scripts/fingerprint.sh" \
  "${SSH_USER}@${PUBLIC_IP}:/tmp/fingerprint.sh"

ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${PUBLIC_IP}" <<'SETUP'
  sudo mv /tmp/docker-compose.yml /tmp/.env /home/ubuntu/ark/
  sudo mv /tmp/fingerprint.sh /home/ubuntu/ark/scripts/
  sudo chmod +x /home/ubuntu/ark/scripts/fingerprint.sh
  sudo chown -R ubuntu:ubuntu /home/ubuntu/ark
SETUP

# Download backup from S3
STEP_START=$(date +%s)
log "Downloading backup from S3..."
ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${PUBLIC_IP}" \
  "sudo /usr/local/bin/aws s3 cp s3://${BUCKET}/${PREFIX}${BACKUP_ID}/ /var/backups/ark/${BACKUP_ID}/ --recursive --region ${REGION}"

TIME_DOWNLOAD=$(elapsed ${STEP_START})
log "Download complete: ${TIME_DOWNLOAD}"


# ============================================================================
# 4. Restore
# ============================================================================

STEP_START=$(date +%s)
log "Restoring backup on EC2..."

ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${PUBLIC_IP}" <<RESTORE
  set -euo pipefail
  cd /home/ubuntu/ark

  # Verify checksums before touching anything
  MANIFEST="/var/backups/ark/${BACKUP_ID}/manifest.json"
  cd "/var/backups/ark/${BACKUP_ID}"
  sha256sum -c <(python3 -c "
import json
with open('manifest.json') as f:
    m = json.load(f)
for a in m['artifacts']:
    print(a['sha256'] + '  ' + a['name'])
  ")
  cd /home/ubuntu/ark

  # Pull images and create volumes
  set -euo pipefail
  cd /home/ubuntu/ark

  # Verify checksums before touching anything
  cd "/var/backups/ark/${BACKUP_ID}"
  sha256sum -c <(python3 -c "
import json
with open('manifest.json') as f:
    m = json.load(f)
for a in m['artifacts']:
    print(a['sha256'] + '  ' + a['name'])
  ")
  cd /home/ubuntu/ark

  # Pull images only — do NOT start yet
  sudo docker compose pull --quiet

  # Create volumes without starting containers
  sudo docker volume create ark_gitea-data
  sudo docker volume create ark_pg-data

  # Restore volumes from backup
  for vol in gitea-data pg-data; do
    sudo docker run --rm \
      -v "ark_\${vol}:/target" \
      -v "/var/backups/ark/${BACKUP_ID}:/backup:ro" \
      alpine:3.20 \
      sh -c "rm -rf /target/* && tar xzf /backup/volume-\${vol}.tar.gz -C /target"
  done

  # NOW start with restored data
  sudo docker compose up -d

  # Wait for db
  for i in \$(seq 1 30); do
    if sudo docker compose exec -T db pg_isready -U gitea -d gitea > /dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  # Apply SQL dump for logical consistency
  gunzip -c "/var/backups/ark/${BACKUP_ID}/database.sql.gz" \
    | sudo docker compose exec -T db psql -U gitea -d gitea -v ON_ERROR_STOP=0 > /dev/null 2>&1

  # Restart app to pick up restored database
  sudo docker compose restart gitea

  # Wait for healthy
  for i in \$(seq 1 30); do
    if curl -sf http://localhost:3000/api/healthz > /dev/null 2>&1; then
      break
    fi
    sleep 5
  done
RESTORE

TIME_RESTORE=$(elapsed ${STEP_START})
log "Restore complete: ${TIME_RESTORE}"

# ============================================================================
# 5. Verify
# ============================================================================

STEP_START=$(date +%s)
log "Verifying restored data..."

# Run fingerprint on EC2
RESTORED_FP=$(ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${PUBLIC_IP}" \
  "cd /home/ubuntu/ark && sudo bash scripts/fingerprint.sh")

# Compare against manifest
RESULT_DB="FAIL"
RESULT_VOL="FAIL"
RESULT_APP="FAIL"

# Check app health
APP_STATUS=$(ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${PUBLIC_IP}" \
  "curl -sf http://localhost:3000/api/healthz > /dev/null 2>&1 && echo OK || echo FAIL")

if [[ "${APP_STATUS}" == "OK" ]]; then
  RESULT_APP="PASS"
fi

# Compare fingerprints
MANIFEST_USERS_HASH=$(echo "${MANIFEST_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['source_fingerprint']['database']['users_hash'])")
RESTORED_USERS_HASH=$(echo "${RESTORED_FP}" | python3 -c "import sys,json; print(json.load(sys.stdin)['database']['users_hash'])")
MANIFEST_GIT_HASH=$(echo "${MANIFEST_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['source_fingerprint']['storage']['git_repositories_sha256'])")
RESTORED_GIT_HASH=$(echo "${RESTORED_FP}" | python3 -c "import sys,json; print(json.load(sys.stdin)['storage']['git_repositories_sha256'])")

if [[ "${MANIFEST_USERS_HASH}" == "${RESTORED_USERS_HASH}" ]]; then
  RESULT_DB="PASS"
fi

if [[ "${MANIFEST_GIT_HASH}" == "${RESTORED_GIT_HASH}" ]]; then
  RESULT_VOL="PASS"
fi

TIME_VERIFY=$(elapsed ${STEP_START})

# ============================================================================
# 6. Calculate RTO
# ============================================================================

DRILL_END=$(date +%s)
RTO_SECONDS=$((DRILL_END - DRILL_START))
RTO_DISPLAY=$(elapsed ${DRILL_START})

if [[ "${RESULT_DB}" == "PASS" && "${RESULT_VOL}" == "PASS" && "${RESULT_APP}" == "PASS" ]]; then
  DRILL_RESULT="PASS"
else
  DRILL_RESULT="FAIL"
fi

log ""
log "============================================"
log "  DRILL RESULT: ${DRILL_RESULT}"
log "============================================"
log "  RTO:              ${RTO_DISPLAY}"
log "  RPO:              ${RPO_MINUTES}m"
log "  Provision EC2:    ${TIME_PROVISION}"
log "  Instance ready:   ${TIME_READY}"
log "  Download backup:  ${TIME_DOWNLOAD}"
log "  Restore:          ${TIME_RESTORE}"
log "  Verify:           ${TIME_VERIFY}"
log ""
log "  Database:         ${RESULT_DB}"
log "  Volume integrity: ${RESULT_VOL}"
log "  Application:      ${RESULT_APP}"
log "============================================"

# ============================================================================
# 7. Record the result
# ============================================================================

# Read ark version from manifest
ARK_VERSION=$(echo "${MANIFEST_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ark_version','unknown'))")
DATASET_SIZE=$(echo "${MANIFEST_JSON}" | python3 -c "
import sys,json
m = json.load(sys.stdin)
total = sum(a['bytes'] for a in m['artifacts'])
print(f'{total // (1024*1024)} MB' if total > 1024*1024 else f'{total // 1024} KB')
")

# Count existing drills
if [[ -f "${DRILL_LOG}" ]]; then
  DRILL_NUM=$(( $(grep -c '^Drill #' "${DRILL_LOG}" 2>/dev/null || echo 0) + 1 ))
else
  DRILL_NUM=1
  mkdir -p "$(dirname "${DRILL_LOG}")"
  cat > "${DRILL_LOG}" <<'HEADER'
# Drill History

Failures are recorded too — they prove the drill was actually run.

---

HEADER
fi

DRILL_NUM_PAD=$(printf '%03d' ${DRILL_NUM})

cat >> "${DRILL_LOG}" <<ENTRY
Drill #${DRILL_NUM_PAD}                          ark ${ARK_VERSION}
Date: $(date +%Y-%m-%d)                    Dataset: ${DATASET_SIZE}

RTO:  ${RTO_DISPLAY}   (target < 15m)
RPO:  ${RPO_MINUTES}m       (target < 6h)      $(if [[ ${RPO_MINUTES} -lt 360 ]]; then echo PASS; else echo FAIL; fi)

  Provision EC2         ${TIME_PROVISION}
  Instance ready        ${TIME_READY}
  Download backup       ${TIME_DOWNLOAD}
  Restore               ${TIME_RESTORE}
  Verify                ${TIME_VERIFY}

Database:         ${RESULT_DB}
Volume integrity: ${RESULT_VOL}
Application:      ${RESULT_APP}

RESULT: ${DRILL_RESULT}
$(if [[ "${DRILL_RESULT}" == "FAIL" ]]; then
  echo ""
  echo "Cause:  (fill in manually)"
  echo ""
  echo "Action: (fill in manually)"
  echo ""
  echo "Fixed in: (commit hash)"
fi)
---

ENTRY

log "Drill recorded in ${DRILL_LOG}"

# Cleanup happens via trap — instance will be terminated
log "Instance ${INSTANCE_ID} will be terminated now."

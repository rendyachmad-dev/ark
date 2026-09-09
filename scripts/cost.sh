#!/usr/bin/env bash
# ============================================================================
# ark-cost — estimate the cost of restoring a backup from each S3 storage tier
#
# Usage:
#   ./scripts/cost.sh                    # use latest backup size
#   ./scripts/cost.sh 500                # estimate for 500 MB
#   ./scripts/cost.sh 10240              # estimate for 10 GB
#
# Prices are ap-southeast-1 (Singapore) as of 2026. Adjust if your region
# differs. This is an estimate, not an invoice.
# ============================================================================

set -euo pipefail

ARK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------------------
# 1. Determine dataset size
# ---------------------------------------------------------------------------

if [[ -n "${1:-}" ]]; then
  SIZE_MB=$1
else
  # Try to read from the latest backup manifest in S3
  set -a; source "${ARK_ROOT}/.env" 2>/dev/null; set +a
  BUCKET="${ARK_S3_BUCKET:-}"
  REGION="${ARK_S3_REGION:-ap-southeast-1}"
  PREFIX="${ARK_S3_PREFIX:-backups/}"

  if [[ -n "${BUCKET}" ]]; then
    LATEST=$(aws s3api list-objects-v2 \
      --bucket "${BUCKET}" \
      --prefix "${PREFIX}" \
      --delimiter "/" \
      --query 'CommonPrefixes[-1].Prefix' \
      --output text \
      --region "${REGION}" 2>/dev/null \
      | sed "s|${PREFIX}||; s|/||")

    if [[ -n "${LATEST}" && "${LATEST}" != "None" ]]; then
      MANIFEST=$(aws s3 cp "s3://${BUCKET}/${PREFIX}${LATEST}/manifest.json" - --region "${REGION}" 2>/dev/null)
      SIZE_MB=$(echo "${MANIFEST}" | python3 -c "
import sys, json
m = json.load(sys.stdin)
total = sum(a['bytes'] for a in m['artifacts'])
print(total // (1024 * 1024) or 1)
")
      echo "Latest backup: ${LATEST} (${SIZE_MB} MB)"
      echo ""
    else
      echo "No backup found in S3. Pass size in MB as argument."
      echo "Usage: $0 <size_in_mb>"
      exit 1
    fi
  else
    echo "No S3 bucket configured. Pass size in MB as argument."
    echo "Usage: $0 <size_in_mb>"
    exit 1
  fi
fi

SIZE_GB=$(python3 -c "print(round(${SIZE_MB} / 1024, 4))")

# ---------------------------------------------------------------------------
# 2. Pricing (ap-southeast-1, per GB, as of 2026)
# ---------------------------------------------------------------------------

# Storage cost per GB per month
STORE_STANDARD=0.025
STORE_STANDARD_IA=0.0138
STORE_GLACIER_FR=0.005
STORE_GLACIER_DA=0.002

# Retrieval cost per GB
RETR_STANDARD=0.00        # no retrieval fee
RETR_STANDARD_IA=0.01     # per GB retrieved
RETR_GLACIER_EXPEDITED=0.03
RETR_GLACIER_STANDARD=0.01
RETR_GLACIER_BULK=0.0025
RETR_DA_STANDARD=0.02
RETR_DA_BULK=0.0025

# Retrieval request cost (per 1,000 requests) — simplified to per-request
# A typical Ark backup has 5 objects, so request costs are negligible.

# Data transfer out to internet (first 100 GB/month)
TRANSFER_OUT=0.12

# ---------------------------------------------------------------------------
# 3. Calculate
# ---------------------------------------------------------------------------

calc() {
  python3 -c "
size_gb = ${SIZE_GB}
transfer = size_gb * ${TRANSFER_OUT}

tiers = [
    ('S3 Standard',              ${STORE_STANDARD},    ${RETR_STANDARD},        0,   'Instant'),
    ('S3 Standard-IA',           ${STORE_STANDARD_IA}, ${RETR_STANDARD_IA},     0,   'Instant'),
    ('Glacier Flexible (Expedited)', ${STORE_GLACIER_FR}, ${RETR_GLACIER_EXPEDITED}, 0, '1-5 min'),
    ('Glacier Flexible (Standard)',  ${STORE_GLACIER_FR}, ${RETR_GLACIER_STANDARD},  0, '3-5 hours'),
    ('Glacier Flexible (Bulk)',      ${STORE_GLACIER_FR}, ${RETR_GLACIER_BULK},      0, '5-12 hours'),
    ('Glacier Deep Archive (Std)',   ${STORE_GLACIER_DA}, ${RETR_DA_STANDARD},       0, '12 hours'),
    ('Glacier Deep Archive (Bulk)',  ${STORE_GLACIER_DA}, ${RETR_DA_BULK},           0, '48 hours'),
]

print(f'Dataset: ${SIZE_MB} MB ({size_gb:.3f} GB)')
print(f'Region:  ap-southeast-1 (Singapore)')
print()
print(f'{\"Tier\":<35} {\"Storage/mo\":>10} {\"Retrieval\":>10} {\"Transfer\":>10} {\"Total\":>10}   {\"Wait time\"}')
print('-' * 100)

for name, store_rate, retr_rate, _, wait in tiers:
    storage = size_gb * store_rate
    retrieval = size_gb * retr_rate
    total = storage + retrieval + transfer
    print(f'{name:<35} \${storage:>9.4f} \${retrieval:>9.4f} \${transfer:>9.4f} \${total:>9.4f}   {wait}')

print()
print('Notes:')
print('  - Storage/mo = monthly cost of keeping the backup in that tier')
print('  - Retrieval  = one-time cost to read the data back')
print('  - Transfer   = data transfer out to your VPS (\$0.12/GB)')
print('  - Ark keeps the latest 30 days in Standard, then moves to IA, then Glacier')
print('  - Deep Archive adds hours to your RTO — only use for archival backups')
"
}

calc

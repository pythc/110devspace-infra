#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

DATA_ROOT="${DATA_ROOT:-/srv/110devspace}"
BACKUP_ROOT="${BACKUP_ROOT:-${DATA_ROOT}/backups}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TARGET_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

install -d -m 0750 "${TARGET_DIR}"

echo "[backup] dumping PostgreSQL"
docker compose -f "${ROOT_DIR}/docker-compose.yml" exec -T postgres \
  pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" > "${TARGET_DIR}/postgres.sql"

echo "[backup] archiving gitea and code-server configuration"
tar -czf "${TARGET_DIR}/gitea-data.tar.gz" -C "${DATA_ROOT}" gitea
(cd "${DATA_ROOT}" && tar -czf "${TARGET_DIR}/code-server-config.tar.gz" code-server/*/config)

echo "[backup] exporting workspace metadata"
find "${DATA_ROOT}/workspaces" -mindepth 1 -maxdepth 2 \
  -printf '%M|%u|%g|%s|%TY-%Tm-%Td %TH:%TM:%TS|%p\n' \
  > "${TARGET_DIR}/workspace-metadata.txt"

if docker compose -f "${ROOT_DIR}/docker-compose.yml" exec -T caddy \
  sh -lc 'cat /data/caddy/pki/authorities/local/root.crt' > "${TARGET_DIR}/caddy-root.crt" 2>/dev/null; then
  :
else
  rm -f "${TARGET_DIR}/caddy-root.crt"
fi

cp "${ROOT_DIR}/inventory/users.yaml" "${TARGET_DIR}/users.yaml"
cp "${ROOT_DIR}/generated/bootstrap-users.json" "${TARGET_DIR}/bootstrap-users.json"

echo "Backup written to ${TARGET_DIR}"

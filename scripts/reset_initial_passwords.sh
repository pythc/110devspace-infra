#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
BOOTSTRAP_FILE="${ROOT_DIR}/generated/bootstrap-users.json"
source "${ROOT_DIR}/scripts/compose_helper.sh"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
fi

if [[ ! -f "${BOOTSTRAP_FILE}" ]]; then
  echo "Missing ${BOOTSTRAP_FILE}. Run scripts/render_inventory.py first." >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

require_compose

if [[ -z "${GITEA_INITIAL_PASSWORD:-}" || -z "${CODE_SERVER_INITIAL_PASSWORD:-}" ]]; then
  echo "Both GITEA_INITIAL_PASSWORD and CODE_SERVER_INITIAL_PASSWORD must be set in .env." >&2
  exit 1
fi

DATA_ROOT="${DATA_ROOT:-/srv/110devspace}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"

mapfile -t ALL_USERS < <(
  python3 - "${BOOTSTRAP_FILE}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for user in payload["users"]:
    print(user["username"])
PY
)

for username in "${ALL_USERS[@]}"; do
  echo "[gitea] resetting ${username}"
  ${COMPOSE_CMD} -f "${ROOT_DIR}/docker-compose.yml" exec -T gitea \
    gitea admin user change-password \
    --username "${username}" \
    --password "${GITEA_INITIAL_PASSWORD}" \
    --must-change-password

  config_dir="${DATA_ROOT}/code-server/${username}/config"
  install -d -m 0750 "${config_dir}"
  cat > "${config_dir}/config.yaml" <<EOF
bind-addr: 0.0.0.0:8080
auth: password
password: ${CODE_SERVER_INITIAL_PASSWORD}
cert: false
EOF
  chown -R "${APP_UID}:${APP_GID}" "${config_dir}"

  echo "[code-server] restarting code-server-${username}"
  ${COMPOSE_CMD} -f "${ROOT_DIR}/docker-compose.yml" restart "code-server-${username}" >/dev/null
done

echo "All initial passwords have been reset."

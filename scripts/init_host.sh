#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
BOOTSTRAP_FILE="${ROOT_DIR}/generated/bootstrap-users.json"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
fi

if [[ ! -f "${BOOTSTRAP_FILE}" ]]; then
  echo "Missing ${BOOTSTRAP_FILE}. Run scripts/render_inventory.py first." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required on the host before running init_host.sh." >&2
  exit 1
fi

set -a
source "${ENV_FILE}"
set +a

HOST_ADMIN_USERNAME="${HOST_ADMIN_USERNAME:-zhoucanyu}"
HOST_ADMIN_AUTHORIZED_KEYS_FILE="${HOST_ADMIN_AUTHORIZED_KEYS_FILE:-}"
DATA_ROOT="${DATA_ROOT:-/srv/110devspace}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
POSTGRES_UID="${POSTGRES_UID:-999}"
POSTGRES_GID="${POSTGRES_GID:-999}"

if [[ -z "${HOST_ADMIN_AUTHORIZED_KEYS_FILE}" || ! -f "${HOST_ADMIN_AUTHORIZED_KEYS_FILE}" ]]; then
  echo "Set HOST_ADMIN_AUTHORIZED_KEYS_FILE in .env to a readable authorized_keys source file." >&2
  exit 1
fi

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

install -d -m 0755 "${DATA_ROOT}"
install -d -m 0750 "${DATA_ROOT}/gitea"
install -d -m 0700 "${DATA_ROOT}/postgres"
install -d -m 0750 "${DATA_ROOT}/caddy/data"
install -d -m 0750 "${DATA_ROOT}/caddy/config"
install -d -m 0750 "${DATA_ROOT}/code-server"
install -d -m 0750 "${DATA_ROOT}/workspaces"
install -d -m 0750 "${DATA_ROOT}/backups"

chown -R "${APP_UID}:${APP_GID}" "${DATA_ROOT}/gitea" "${DATA_ROOT}/code-server" "${DATA_ROOT}/workspaces"
chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "${DATA_ROOT}/postgres"

for username in "${ALL_USERS[@]}"; do
  install -d -m 0750 "${DATA_ROOT}/workspaces/${username}"
  install -d -m 0750 "${DATA_ROOT}/code-server/${username}/config"
  install -d -m 0750 "${DATA_ROOT}/code-server/${username}/local"
done

chown -R "${APP_UID}:${APP_GID}" "${DATA_ROOT}/code-server" "${DATA_ROOT}/workspaces"

if ! id "${HOST_ADMIN_USERNAME}" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "${HOST_ADMIN_USERNAME}"
fi

usermod -aG sudo "${HOST_ADMIN_USERNAME}"
if getent group docker >/dev/null 2>&1; then
  usermod -aG docker "${HOST_ADMIN_USERNAME}"
fi
passwd -l "${HOST_ADMIN_USERNAME}" >/dev/null 2>&1 || true

install -d -m 0750 /etc/sudoers.d
printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "${HOST_ADMIN_USERNAME}" > "/etc/sudoers.d/90-${HOST_ADMIN_USERNAME}"
chmod 0440 "/etc/sudoers.d/90-${HOST_ADMIN_USERNAME}"

install -d -m 0700 "/home/${HOST_ADMIN_USERNAME}/.ssh"
install -m 0600 "${HOST_ADMIN_AUTHORIZED_KEYS_FILE}" "/home/${HOST_ADMIN_USERNAME}/.ssh/authorized_keys"
chown -R "${HOST_ADMIN_USERNAME}:${HOST_ADMIN_USERNAME}" "/home/${HOST_ADMIN_USERNAME}/.ssh"

SSHD_CONFIG="/etc/ssh/sshd_config"

ensure_sshd_setting() {
  local key="$1"
  local value="$2"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "${SSHD_CONFIG}"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "${SSHD_CONFIG}"
  else
    printf '\n%s %s\n' "${key}" "${value}" >> "${SSHD_CONFIG}"
  fi
}

ensure_sshd_setting "PasswordAuthentication" "no"
ensure_sshd_setting "KbdInteractiveAuthentication" "no"
ensure_sshd_setting "ChallengeResponseAuthentication" "no"
ensure_sshd_setting "PubkeyAuthentication" "yes"
ensure_sshd_setting "PermitRootLogin" "no"

if systemctl is-active --quiet ssh; then
  systemctl reload ssh
elif systemctl is-active --quiet sshd; then
  systemctl reload sshd
fi

echo "Host initialization complete."
echo "Host admin: ${HOST_ADMIN_USERNAME}"
echo "Data root: ${DATA_ROOT}"
echo "Sudo mode: passwordless sudo enabled for ${HOST_ADMIN_USERNAME}"

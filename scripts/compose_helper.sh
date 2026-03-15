#!/usr/bin/env bash

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    printf 'docker compose'
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    printf 'docker-compose'
    return 0
  fi

  return 1
}

require_compose() {
  local cmd
  if ! cmd="$(compose_cmd)"; then
    echo "Neither 'docker compose' nor 'docker-compose' is available." >&2
    echo "Install Docker Compose v2 plugin or the legacy docker-compose standalone binary." >&2
    exit 1
  fi
  COMPOSE_CMD="${cmd}"
}

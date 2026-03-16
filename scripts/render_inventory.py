#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:  # pragma: no cover - dependency guard
    raise SystemExit("Missing dependency: python3-yaml. Install it before rendering.") from exc


ROOT = Path(__file__).resolve().parent.parent
INVENTORY_FILE = ROOT / "inventory" / "users.yaml"
COMPOSE_TEMPLATE = ROOT / "templates" / "compose.base.yaml"
CODE_SERVER_TEMPLATE = ROOT / "templates" / "code-server.service.tpl"
CADDY_TEMPLATE = ROOT / "templates" / "Caddyfile.tpl"
GENERATED_DIR = ROOT / "generated"
COMPOSE_OUTPUT = ROOT / "docker-compose.yml"
CADDY_OUTPUT = ROOT / "Caddyfile"
ENV_EXAMPLE_OUTPUT = ROOT / ".env.example"
BOOTSTRAP_OUTPUT = GENERATED_DIR / "bootstrap-users.json"
WORKSPACE_HOSTS_OUTPUT = GENERATED_DIR / "workspace-hosts.txt"
DNS_OUTPUT = GENERATED_DIR / "dns-records.txt"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, content: str) -> None:
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def load_inventory() -> dict:
    require(INVENTORY_FILE.exists(), f"Missing inventory file: {INVENTORY_FILE}")
    data = yaml.safe_load(read_text(INVENTORY_FILE))
    require(isinstance(data, dict), "Inventory root must be a mapping.")
    return data


def build_inventory() -> dict:
    data = load_inventory()
    platform = data.get("platform")
    users = data.get("users")

    require(isinstance(platform, dict), "platform must be a mapping.")
    require(isinstance(users, list) and users, "users must be a non-empty list.")

    required_platform_keys = {
        "name",
        "ip_address",
        "base_domain",
        "timezone",
        "data_root",
        "gitea_host",
        "gitea_ssh_port",
        "workspace_subdomain_prefix",
        "workspace_defaults",
    }
    missing_keys = sorted(required_platform_keys - set(platform))
    require(not missing_keys, f"platform is missing keys: {', '.join(missing_keys)}")

    workspace_defaults = platform["workspace_defaults"]
    require(isinstance(workspace_defaults, dict), "workspace_defaults must be a mapping.")
    require("cpus" in workspace_defaults and "memory" in workspace_defaults, "workspace_defaults requires cpus and memory.")

    username_pattern = re.compile(r"^[a-z][a-z0-9]*$")
    rendered_users = []
    seen_usernames = set()

    for entry in users:
        require(isinstance(entry, dict), "Each user entry must be a mapping.")
        username = str(entry.get("username", "")).strip()
        full_name = str(entry.get("full_name", "")).strip()
        require(username_pattern.fullmatch(username) is not None, f"Invalid username: {username!r}")
        require(full_name, f"full_name is required for {username}")
        require(username not in seen_usernames, f"Duplicate username: {username}")
        seen_usernames.add(username)

        workspace = dict(workspace_defaults)
        workspace.update(entry.get("workspace") or {})
        cpus = str(workspace["cpus"])
        memory = str(workspace["memory"])

        rendered_users.append(
            {
                "username": username,
                "full_name": full_name,
                "gitea_admin": bool(entry.get("gitea_admin", False)),
                "host_admin": bool(entry.get("host_admin", False)),
                "workspace": {"cpus": cpus, "memory": memory},
                "email": f"{username}@{platform['base_domain']}",
                "workspace_host": f"{platform['workspace_subdomain_prefix']}{username}.{platform['base_domain']}",
            }
        )

    require(len(rendered_users) <= 30, "This repository supports up to 30 users in inventory/users.yaml.")

    host_admins = [user for user in rendered_users if user["host_admin"]]
    require(len(host_admins) == 1, "Exactly one host_admin user is required.")
    require(host_admins[0]["username"] == "zhoucanyu", "The only host_admin must be zhoucanyu.")

    zhoucanyu = next((user for user in rendered_users if user["username"] == "zhoucanyu"), None)
    require(zhoucanyu is not None, "zhoucanyu must exist in users.yaml.")
    require(zhoucanyu["gitea_admin"], "zhoucanyu must be a Gitea admin.")

    return {"platform": platform, "users": rendered_users}


def render_code_server_services(users: list[dict]) -> str:
    template = read_text(CODE_SERVER_TEMPLATE)
    blocks = []
    for user in users:
        block = template
        replacements = {
            "__USERNAME__": user["username"],
            "__CPU_LIMIT__": user["workspace"]["cpus"],
            "__MEMORY_LIMIT__": user["workspace"]["memory"],
        }
        for marker, value in replacements.items():
            block = block.replace(marker, value)
        blocks.append(block.rstrip())
    return "\n\n".join(blocks)


def render_caddy_routes(users: list[dict]) -> str:
    routes = []
    for user in users:
        routes.append(
            "\n".join(
                [
                    f"https://{user['workspace_host']} {{",
                    "  tls internal",
                    "  encode zstd gzip",
                    f"  reverse_proxy code-server-{user['username']}:8080",
                    "}",
                ]
            )
        )
    return "\n\n".join(routes)


def render_compose(inventory: dict) -> str:
    base = read_text(COMPOSE_TEMPLATE)
    services_block = render_code_server_services(inventory["users"])
    return base.replace("__CODE_SERVER_SERVICES__", services_block)


def render_caddyfile(inventory: dict) -> str:
    template = read_text(CADDY_TEMPLATE)
    return (
        template.replace("__GITEA_HOST__", inventory["platform"]["gitea_host"])
        .replace("__WORKSPACE_ROUTES__", render_caddy_routes(inventory["users"]))
    )


def render_env_example(inventory: dict) -> str:
    platform = inventory["platform"]
    host_admin = next(user for user in inventory["users"] if user["host_admin"])
    return "\n".join(
        [
            "# Copy to .env on the server and replace every password before first boot.",
            f"COMPOSE_PROJECT_NAME={platform['name']}",
            f"DATA_ROOT={platform['data_root']}",
            f"BACKUP_ROOT={platform['data_root']}/backups",
            f"PLATFORM_IP={platform['ip_address']}",
            f"PLATFORM_TIMEZONE={platform['timezone']}",
            f"BASE_DOMAIN={platform['base_domain']}",
            f"GITEA_HOST={platform['gitea_host']}",
            f"GITEA_SSH_PORT={platform['gitea_ssh_port']}",
            f"GITEA_INTERNAL_SSH_PORT={platform['gitea_ssh_port']}",
            "POSTGRES_IMAGE=postgres:16",
            "POSTGRES_DB=gitea",
            "POSTGRES_USER=gitea",
            "POSTGRES_PASSWORD=change-this-database-password",
            "POSTGRES_UID=999",
            "POSTGRES_GID=999",
            "GITEA_IMAGE=docker.gitea.com/gitea:1.25.4-rootless",
            f"GITEA_ADMIN_USERNAME={host_admin['username']}",
            "GITEA_INITIAL_PASSWORD=ChangeMe!123",
            "GITEA_MIGRATIONS_ALLOWED_DOMAINS=",
            "GITEA_MIGRATIONS_BLOCKED_DOMAINS=",
            "GITEA_MIGRATIONS_ALLOW_LOCALNETWORKS=false",
            "GITEA_MIGRATIONS_SKIP_TLS_VERIFY=false",
            "CODE_SERVER_IMAGE=ghcr.io/coder/code-server:4.107.1-39",
            "CODE_SERVER_INITIAL_PASSWORD=ChangeMe!123",
            "CODE_SERVER_LOCALE=zh-cn",
            "CODE_SERVER_LANGUAGE_PACK=ms-ceintl.vscode-language-pack-zh-hans",
            "CADDY_IMAGE=caddy:2.10.2-alpine",
            "CADDY_HTTP_PORT=18080",
            "CADDY_HTTPS_PORT=443",
            "APP_UID=1000",
            "APP_GID=1000",
            f"HOST_ADMIN_USERNAME={host_admin['username']}",
            "HOST_ADMIN_AUTHORIZED_KEYS_FILE=/root/authorized_keys_zhoucanyu",
        ]
    )


def render_bootstrap_payload(inventory: dict) -> str:
    payload = {
        "platform": inventory["platform"],
        "users": inventory["users"],
    }
    return json.dumps(payload, ensure_ascii=False, indent=2)


def render_workspace_hosts(inventory: dict) -> str:
    lines = ["# username workspace_host"]
    for user in inventory["users"]:
        lines.append(f"{user['username']} {user['workspace_host']}")
    return "\n".join(lines)


def render_dns_records(inventory: dict) -> str:
    platform = inventory["platform"]
    return "\n".join(
        [
            "# Configure these records in internal DNS.",
            f"{platform['gitea_host']} -> {platform['ip_address']}",
            f"*.{platform['base_domain']} -> {platform['ip_address']}",
        ]
    )


def main() -> int:
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    inventory = build_inventory()

    write_text(COMPOSE_OUTPUT, render_compose(inventory))
    write_text(CADDY_OUTPUT, render_caddyfile(inventory))
    write_text(ENV_EXAMPLE_OUTPUT, render_env_example(inventory))
    write_text(BOOTSTRAP_OUTPUT, render_bootstrap_payload(inventory))
    write_text(WORKSPACE_HOSTS_OUTPUT, render_workspace_hosts(inventory))
    write_text(DNS_OUTPUT, render_dns_records(inventory))

    print(f"Rendered {len(inventory['users'])} users into {COMPOSE_OUTPUT.name}, {CADDY_OUTPUT.name}, and generated/*.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

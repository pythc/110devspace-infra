  code-server-__USERNAME__:
    image: ${CODE_SERVER_IMAGE:-ghcr.io/coder/code-server:4.107.1-39}
    restart: unless-stopped
    user: "${APP_UID:-1000}:${APP_GID:-1000}"
    working_dir: /home/coder/workspace
    environment:
      TZ: ${PLATFORM_TIMEZONE:-Asia/Shanghai}
      USER: coder
    entrypoint:
      - /bin/sh
      - -lc
      - |-
        CONFIG_DIR="/home/coder/.config/code-server"
        CONFIG_FILE="$$CONFIG_DIR/config.yaml"
        USER_DATA_DIR="/home/coder/.local/share/code-server"
        EXTENSION_ID="${CODE_SERVER_LANGUAGE_PACK:-ms-ceintl.vscode-language-pack-zh-hans}"
        LOCALE="${CODE_SERVER_LOCALE:-zh-cn}"
        mkdir -p "$$CONFIG_DIR" "$$USER_DATA_DIR/User"
        if [ ! -f "$$CONFIG_FILE" ]; then
          cat > "$$CONFIG_FILE" <<EOF
        bind-addr: 0.0.0.0:8080
        auth: password
        password: ${CODE_SERVER_INITIAL_PASSWORD}
        cert: false
        EOF
        fi
        if [ -n "$$LOCALE" ]; then
          cat > "$$USER_DATA_DIR/User/locale.json" <<EOF
        {
          "locale": "$$LOCALE"
        }
        EOF
        fi
        if [ -n "$$EXTENSION_ID" ] && ! code-server --list-extensions | grep -qx "$$EXTENSION_ID"; then
          code-server --install-extension "$$EXTENSION_ID" >/tmp/code-server-extension-install.log 2>&1 || true
        fi
        exec code-server --locale "$$LOCALE" --config "$$CONFIG_FILE" /home/coder/workspace
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cpus: "__CPU_LIMIT__"
    mem_limit: "__MEMORY_LIMIT__"
    mem_reservation: "512m"
    pids_limit: 256
    volumes:
      - ${DATA_ROOT:-/srv/110devspace}/workspaces/__USERNAME__:/home/coder/workspace
      - ${DATA_ROOT:-/srv/110devspace}/code-server/__USERNAME__/config:/home/coder/.config/code-server
      - ${DATA_ROOT:-/srv/110devspace}/code-server/__USERNAME__/local:/home/coder/.local/share/code-server
      - /etc/localtime:/etc/localtime:ro
    networks:
      - platform

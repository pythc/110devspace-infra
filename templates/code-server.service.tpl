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
        mkdir -p "$$CONFIG_DIR"
        if [ ! -f "$$CONFIG_FILE" ]; then
          cat > "$$CONFIG_FILE" <<EOF
        bind-addr: 0.0.0.0:8080
        auth: password
        password: ${CODE_SERVER_INITIAL_PASSWORD}
        cert: false
        EOF
        fi
        exec code-server --config "$$CONFIG_FILE" /home/coder/workspace
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

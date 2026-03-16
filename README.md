# 110devspace-infra

单机版团队开发平台基础设施仓库，面向 `10.16.6.247` 这台 `16C / 32G / 600G` 服务器，第一版交付：

- `Caddy`：统一 HTTPS 和反向代理
- `Gitea`：代码托管、组织权限、代码评审
- `PostgreSQL`：Gitea 数据库
- `21` 个独立 `code-server` 工作区

第一版不包含 `act_runner`，也不包含业务仓库自动 clone 脚本。

## 固定约定

- 基域名：`110devspace.internal`
- Gitea：`https://git.110devspace.internal:18443`
- 工作区：`https://ide-<username>.110devspace.internal:18443`
- Gitea SSH：`ssh://git@git.110devspace.internal:2222/<org>/<repo>.git`
- 唯一宿主机管理员：`zhoucanyu`
- 其余用户只有各自 `code-server` 容器，不创建宿主机 Linux 用户

`2222` 是刻意保留给 Gitea 的 raw SSH 入口。只靠 `Caddy 80/443` 无法完成 Git over SSH。
`110devspace` 默认不再占用宿主机 `443`，而是固定走 `18443`，把标准 `443` 留给 `ai-homework-system`。

## 仓库布局

- `inventory/users.yaml`：唯一用户源
- `templates/`：Compose、Caddy、单用户工作区模板
- `scripts/render_inventory.py`：生成 `docker-compose.yml`、`Caddyfile`、`.env.example`
- `scripts/init_host.sh`：初始化数据目录、宿主机管理员和 SSH 设置
- `scripts/bootstrap_gitea.py`：批量创建 Gitea 本地用户
- `scripts/reset_initial_passwords.sh`：统一重置 Gitea 和 code-server 初始密码
- `scripts/backup.sh`：导出 PostgreSQL、Gitea 数据和工作区元数据
- `generated/`：渲染后产物

## 前置条件

生产服务器默认按 `Ubuntu 22.04` 设计，需提前准备：

1. Docker Engine + 任一 Compose 实现
   - 优先：`docker compose`（Compose v2 插件）
   - 兼容：`docker-compose`（Standalone / Legacy）
2. Python 3 + `python3-yaml`
3. 内网 DNS：
   - `git.110devspace.internal -> 10.16.6.247`
   - `*.110devspace.internal -> 10.16.6.247`
4. `zhoucanyu` 的 `authorized_keys` 源文件

推荐安装命令：

```bash
sudo apt update
sudo apt install -y python3 python3-yaml
```

如果 `docker --version` 正常，但 `docker compose version` 报 `unknown command`，并不代表不能部署。只要宿主机上有可用的 `docker-compose` 独立命令，这个仓库里的脚本也能正常工作。

## 首次渲染

本仓库把 `docker-compose.yml` 和 `Caddyfile` 当作生成物维护。修改 `inventory/users.yaml` 后，重新渲染一次：

```bash
cd /path/to/110devspace-infra
python3 scripts/render_inventory.py
```

生成物包括：

- `docker-compose.yml`
- `Caddyfile`
- `.env.example`
- `generated/bootstrap-users.json`
- `generated/workspace-hosts.txt`
- `generated/dns-records.txt`

## 部署步骤

### 1. 准备环境变量

```bash
cp .env.example .env
```

至少修改这些值：

- `POSTGRES_PASSWORD`
- `GITEA_INITIAL_PASSWORD`
- `CODE_SERVER_INITIAL_PASSWORD`
- `HOST_ADMIN_AUTHORIZED_KEYS_FILE`
- `GITEA_ROOT_URL`
- 如果要从内网 Git 服务或自签名源导入仓库，再按需设置：
  - `GITEA_MIGRATIONS_ALLOWED_DOMAINS`
  - `GITEA_MIGRATIONS_BLOCKED_DOMAINS`
  - `GITEA_MIGRATIONS_ALLOW_LOCALNETWORKS`
  - `GITEA_MIGRATIONS_SKIP_TLS_VERIFY`
- 默认 `CADDY_HTTP_PORT=18080`，因为目标服务器现网已有服务占用 `80`
- 默认 `CADDY_HTTPS_PORT=18443`，刻意避开宿主机 `443`
- 如果你继续改 `CADDY_HTTPS_PORT`，同步更新 `GITEA_ROOT_URL`
- 默认 `CODE_SERVER_LOCALE=zh-cn`，并尝试自动安装 `ms-ceintl.vscode-language-pack-zh-hans`

`HOST_ADMIN_AUTHORIZED_KEYS_FILE` 必须指向一个“公钥列表”文件，也就是未来允许登录 `zhoucanyu` 的 `authorized_keys` 内容来源。它不是自动复用当前登录用户家目录里的 `~/.ssh/authorized_keys`。

`Gitea` 的仓库导入限制项对应官方 `[migrations]` 配置。默认 `GITEA_MIGRATIONS_ALLOW_LOCALNETWORKS=false`，因此从 `10.x`、`192.168.x`、`.internal` 这类内网源导入时，可能出现“您不能从不允许的主机导入”的报错。改完这些变量后，需要完整重启 `gitea` 容器才会生效。

`GITEA_ROOT_URL` 必须和用户实际访问的外部 URL 一致。当前默认设计是 `https://git.110devspace.internal:18443/`。如果你把 `110devspace` 再改到别的 HTTPS 端口，或者未来重新拿回宿主机 `443`，这里也要一起改。

如果你当前登录的服务器账号本地并没有这个文件，做法是：

1. 在你自己的管理电脑上找到要登录服务器用的公钥，例如 `~/.ssh/id_ed25519.pub`
2. 把这把公钥内容复制到服务器
3. 在服务器上写成一个文件，例如 `/root/authorized_keys_zhoucanyu`

### 2. 初始化宿主机

```bash
sudo bash scripts/init_host.sh
```

这个脚本会：

- 创建 `/srv/110devspace`
- 创建每个工作区和 code-server 配置目录
- 创建或修正宿主机用户 `zhoucanyu`
- 加入 `sudo`
- 写入无密码 `sudo` 规则
- 安装 `authorized_keys`
- 禁用 SSH 密码登录和 root 直登

执行前请保留当前管理会话，不要先退出。跑完后先新开一个终端测试 `zhoucanyu` 的 SSH key 登录，再关闭旧会话。

### 3. 启动平台

```bash
docker compose up -d
python3 scripts/bootstrap_gitea.py
```

如果宿主机只有 `docker-compose`，把上面命令里的 `docker compose` 换成 `docker-compose` 即可。仓库内脚本会自动探测两种实现。

如果你准备用 `docker` 组而不是 `sudo` 运行 Compose，先重新登录一次宿主机账号，让 `scripts/init_host.sh` 刚添加的组成员关系生效。

### 4. 导出 Caddy 根证书

首次启动后，Caddy 会在宿主机生成内部 CA：

```bash
ls /srv/110devspace/caddy/data/caddy/pki/authorities/local/root.crt
```

把这个根证书分发到团队电脑并导入系统信任链，否则浏览器会提示证书不受信任。

## 账号与密码

### Gitea

- `scripts/bootstrap_gitea.py` 会按 `generated/bootstrap-users.json` 批量建用户
- 创建时统一使用 `GITEA_INITIAL_PASSWORD`
- 创建时会强制用户首次登录修改密码
- 用户中文显示名仍保留在 `inventory/users.yaml`，如需在 Gitea UI 展示，可由用户首次登录后在个人资料中补齐

### code-server

- 每个工作区第一次启动时，会在 `~/.config/code-server/config.yaml` 写入初始密码
- 初始密码来自 `.env` 的 `CODE_SERVER_INITIAL_PASSWORD`
- 该文件只在不存在时生成，不会覆盖用户后续自定义修改
- 默认界面语言来自 `.env` 的 `CODE_SERVER_LOCALE=zh-cn`
- 容器启动时会检测并尝试安装 `.env` 里的 `CODE_SERVER_LANGUAGE_PACK`
- 如果服务器无法访问扩展源，语言包安装会跳过，IDE 仍可启动

用户自行修改 code-server 密码的方式：

1. 在浏览器终端里编辑 `~/.config/code-server/config.yaml`
2. 修改 `password: ...`
3. 执行 `kill 1`
4. 等容器自动重启后，用新密码重新登录

如果管理员要统一回收所有初始密码：

```bash
sudo bash scripts/reset_initial_passwords.sh
```

## 日常运维

### 重新生成配置

```bash
python3 scripts/render_inventory.py
docker compose up -d --remove-orphans
```

如果宿主机只有 `docker-compose`，这里同样替换成 `docker-compose up -d --remove-orphans`。

### 与 ai-homework-system 共存

当前默认拓扑是：

- `ai-homework-system`：占用宿主机 `443`
- `110devspace`：占用宿主机 `18443`

因此团队访问 `110devspace` 时，必须显式带端口：

- `https://git.110devspace.internal:18443`
- `https://ide-<username>.110devspace.internal:18443`

DNS 仍然只需要把域名解析到同一台服务器，端口不由 DNS 控制。

### 新增或删除成员

1. 修改 `inventory/users.yaml`
2. 重新运行 `python3 scripts/render_inventory.py`
3. `docker compose up -d --remove-orphans`
4. 重新运行 `python3 scripts/bootstrap_gitea.py`
5. 如果是删除成员，手动在 Gitea 里禁用或删除账号，并按需清理 `/srv/110devspace/workspaces/<username>`

### 备份

```bash
sudo bash scripts/backup.sh
```

`backup.sh` 默认会写 `${BACKUP_ROOT}`，同时需要读取容器数据目录，按默认设计用 `sudo` 执行。

### 数据目录权限

以下目录按容器运行 UID/GID 管理，不建议手动改属主：

- `/srv/110devspace/gitea`
- `/srv/110devspace/workspaces/*`
- `/srv/110devspace/code-server/*`

涉及这些目录的维护脚本按默认设计使用 `sudo`。

备份内容：

- PostgreSQL SQL dump
- `gitea` 数据目录归档
- `code-server` 配置目录归档
- 工作区目录元数据清单
- 当前用户清单
- 当前 Caddy 内部 CA 根证书

### 常用检查

```bash
docker compose ps
docker compose logs -f gitea
docker compose logs -f caddy
docker compose logs -f code-server-zhoucanyu
```

如果宿主机只有 `docker-compose`，把上面命令整体替换为 `docker-compose ...`。

## 容量边界

这台服务器按 `30` 个账号设计，但更现实的长期负载是：

- `10~12` 个中重度并发工作区
- `12~15` 个中轻度并发工作区

不要把它当成重 CI 平台，也不要同时开启大规模构建任务。

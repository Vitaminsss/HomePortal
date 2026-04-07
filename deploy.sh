#!/bin/bash
# ============================================
# HomePortal — Linux 一键部署
# 用法：在 HomePortal 目录执行
#   sudo bash deploy.sh
#
# 域名 DOMAIN：若曾成功部署过，会写入本目录 .deploy-domain，下次直接 sudo 即可。
# 首次或需改域名时须让 root 进程能拿到变量（任选其一）：
#   sudo env DOMAIN=www.example.com bash deploy.sh
#   DOMAIN=www.example.com sudo -E bash deploy.sh
# 勿用「DOMAIN=... sudo bash」——sudo 默认会丢弃该变量，脚本里会看到「未配置域名」。
#
# 安装目录 = 本脚本所在目录（与 server.js 同级）
#
# Nginx：默认安装；关闭：USE_NGINX=0 或 SKIP_NGINX=1
#   DOMAIN         公网域名（如 www.example.com）；未设置时尝试 hostname -f
#   USE_HTTPS=0    不尝试 HTTPS（仅 HTTP）
#   CERTBOT_EMAIL  可选邮箱；默认 admin@域名
#   PORTAL_TITLE   浏览器标签页标题（覆盖「指引页」）；首次向导可交互输入；再次部署可传此变量写回 .env
#
# 主 Nginx：/etc/nginx/conf.d/<根域标签>.conf（由域名倒数第二段命名，无域名为 _default.conf）
# Location 片段：/etc/nginx/conf.d/locations/home-portal.conf（location /，根路径直达）
# HTTPS：certbot certonly（只签发证书，不改 Nginx）；80/443 server 块由本脚本写入并含 include locations
#
# 与 Release Hub 共存：
#   两个服务共用同一 Nginx 主 server 块（conf.d/<domain>.conf），各自在 conf.d/locations/ 下维护片段
#   HomePortal  → location /          （根路径，直接域名访问）
#   Release Hub → location /releasehub/（子路径）
#   先部署的服务创建主 server 块；后部署的服务检测到文件已存在则跳过创建，仅添加自己的 location 片段
# ============================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"
MARKER="$INSTALL_DIR/.homeportal-deploy-init"
SERVICE_NAME="home-portal"
PORT=3000
NGINX_ENABLED=0
HTTPS_ENABLED=0
DOMAIN_RESOLVED=""
MAIN_NGINX_CONF=""
NODE_BIN="$(command -v node || true)"

# ── Root 检查 ──────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "本脚本需要 root 以安装 systemd 与 Nginx 配置，请执行:" >&2
  echo "  sudo bash $0" >&2
  exit 1
fi

if [ -z "${NODE_BIN}" ]; then
  echo "错误: 未找到 node，请先安装 Node.js 20 LTS（如 NodeSource 或发行版仓库）。" >&2
  exit 1
fi

# ── 是否为不适合公网访问 / Let's Encrypt 的主机名（如 mDNS 的 *.local）────────
domain_is_nonpublic_hostname() {
  local d="$1"
  [ -z "$d" ] && return 0
  case "$d" in
    localhost|localhost.*) return 0 ;;
  esac
  [[ "$d" == *.local ]] && return 0
  [[ "$d" == *.localdomain ]] && return 0
  [[ "$d" == *.lan ]] && return 0
  [[ "$d" == *.internal ]] && return 0
  return 1
}

# ── 主配置文件路径：与 Release Hub 保持一致（共用同一文件）───────────────────
# 无域名或内网保留名 → _default.conf；否则取 FQDN 倒数第二段（如 www.example.com → example.conf）
nginx_main_conf_path() {
  local d="$1"
  if [ -z "$d" ] || domain_is_nonpublic_hostname "$d"; then
    echo "/etc/nginx/conf.d/_default.conf"
    return 0
  fi
  local label
  label="$(echo "$d" | awk -F. '{print $(NF-1)}')"
  [ -z "$label" ] && label="_default"
  echo "/etc/nginx/conf.d/${label}.conf"
}

# ── 域名解析：DOMAIN 环境变量 → .deploy-domain → hostname -f（非保留名）→ 空 ──
homeportal_resolve_domain() {
  local _dd
  if [ -z "${DOMAIN:-}" ] && [ -f "$INSTALL_DIR/.deploy-domain" ]; then
    _dd="$(head -1 "$INSTALL_DIR/.deploy-domain" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -n "$_dd" ]; then
      DOMAIN="$_dd"
      echo "▸ 从 .deploy-domain 读取域名（sudo 不传变量时仍可用）: $DOMAIN"
    fi
  fi
  DOMAIN_RESOLVED="$(echo "${DOMAIN:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$DOMAIN_RESOLVED" ]; then
    local HFN
    HFN="$(hostname -f 2>/dev/null || true)"
    if [ -n "$HFN" ] && [ "$HFN" != "localhost" ] && [[ "$HFN" == *.* ]]; then
      if ! domain_is_nonpublic_hostname "$HFN"; then
        DOMAIN_RESOLVED="$HFN"
        echo "▸ 使用 hostname -f 作为域名: $DOMAIN_RESOLVED"
      else
        echo "⚠ hostname -f「$HFN」为内网保留名，已忽略；请设置 DOMAIN="
      fi
    fi
  else
    echo "▸ 使用 DOMAIN=$DOMAIN_RESOLVED"
  fi
}

# ── 移除发行版默认站点，避免与 _default.conf 的 server_name _ 冲突 ─────────────
nginx_disable_stock_default_site() {
  if [ -e /etc/nginx/sites-enabled/default ]; then
    echo "▸ 移除发行版默认站点 sites-enabled/default（避免与 _default.conf 的 server_name _ 冲突）"
    rm -f /etc/nginx/sites-enabled/default
  fi
  # 迁移：移除旧版 HomePortal 遗留的 sites-available 配置（旧架构已废弃）
  if [ -L /etc/nginx/sites-enabled/home-portal ] || [ -e /etc/nginx/sites-enabled/home-portal ]; then
    echo "▸ 迁移：移除旧版 sites-enabled/home-portal（已改用 conf.d 架构）"
    rm -f /etc/nginx/sites-enabled/home-portal
  fi
  if [ -f /etc/nginx/sites-available/home-portal ]; then
    echo "▸ 迁移：移除旧版 sites-available/home-portal"
    rm -f /etc/nginx/sites-available/home-portal
  fi
}

# ── 已配置公网域名时删除旧的 _default.conf，避免路由混乱 ────────────────────
nginx_remove_stale_default_conf_for_domain() {
  if [ -z "$DOMAIN_RESOLVED" ] || domain_is_nonpublic_hostname "$DOMAIN_RESOLVED"; then
    return 0
  fi
  if [ -f /etc/nginx/conf.d/_default.conf ]; then
    echo "▸ 已配置公网域名，移除 /etc/nginx/conf.d/_default.conf（避免与域名主配置冲突）"
    rm -f /etc/nginx/conf.d/_default.conf
  fi
}

# ── 主 server 块：HTTP-only。仅在文件不存在时创建（共存关键：不覆盖已有配置）──
# 若 Release Hub 已先运行并创建了该文件，此函数直接跳过，HomePortal 只添加自己的 location 片段
ensure_main_server_block() {
  local sn
  local listen_directive
  if [ -n "$DOMAIN_RESOLVED" ] && ! domain_is_nonpublic_hostname "$DOMAIN_RESOLVED"; then
    sn="$DOMAIN_RESOLVED"
    listen_directive='    listen 80;
    listen [::]:80;'
  else
    sn="_"
    # 无域名时须为 default_server，且已去掉发行版 default，否则按 IP 访问不会落到本 server
    listen_directive='    listen 80 default_server;
    listen [::]:80 default_server;'
  fi

  if [ -f "$MAIN_NGINX_CONF" ]; then
    echo "▸ 主 Nginx 配置已存在（可能由 Release Hub 创建），跳过以保持共存: $MAIN_NGINX_CONF"
    echo "  （如需重建，请手动删除后重新运行: rm -f $MAIN_NGINX_CONF && sudo bash deploy.sh）"
    return 0
  fi

  echo "▸ 写入主 Nginx 配置（HTTP）: $MAIN_NGINX_CONF（server_name $sn）"
  tee "$MAIN_NGINX_CONF" > /dev/null <<NGX
# HomePortal/ReleaseHub — 主 server 块（由 deploy.sh 管理）；各服务 location 见 conf.d/locations/
server {
${listen_directive}
    server_name ${sn};

    client_max_body_size 500M;
    client_body_timeout 300s;

    include /etc/nginx/conf.d/locations/*.conf;
}
NGX
}

# ── HomePortal location 片段（根路径 /，直接域名访问）──────────────────────────
write_homeportal_location() {
  mkdir -p /etc/nginx/conf.d/locations
  local loc_path="/etc/nginx/conf.d/locations/home-portal.conf"
  tee "$loc_path" > /dev/null <<NGX
# HomePortal — 由 deploy.sh 管理（根路径，直接域名访问）
location / {
    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
}
NGX
}

# ── certbot certonly 成功后写入：HTTP 仅跳转 HTTPS + 443 含 include locations ──
# 不让 certbot --nginx 改写配置，避免丢失反代 location；80/443 server 块完全由本脚本自管
write_main_server_block_https() {
  local dom="$1"
  local conf="${2:-$MAIN_NGINX_CONF}"
  [ -z "$dom" ] && return 1
  echo "▸ 写入 HTTPS 主配置: $conf（server_name $dom，由脚本自管 80/443）"
  tee "$conf" > /dev/null <<NGX
# HomePortal/ReleaseHub — HTTPS（certonly 后由 deploy.sh 写入）；各服务 location 见 conf.d/locations/
server {
    listen 80;
    listen [::]:80;
    server_name ${dom};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${dom};

    ssl_certificate     /etc/letsencrypt/live/${dom}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${dom}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 500M;
    client_body_timeout 300s;

    include /etc/nginx/conf.d/locations/*.conf;
}
NGX
}

# ── DNS 预检：域名 A/AAAA 是否包含本机公网 IP ────────────────────────────────
dns_resolves_to_public_ip() {
  local dom="$1"
  local pub="$2"
  local line
  [ -z "$dom" ] || [ -z "$pub" ] && return 1
  [ "$pub" = "YOUR_SERVER_IP" ] && return 1
  if ! command -v dig &>/dev/null; then
    echo "⚠ 未找到 dig 命令，跳过 DNS 预检，将直接尝试 certbot dry-run"
    return 0
  fi
  while read -r line; do
    [ -n "$line" ] && [ "$line" = "$pub" ] && return 0
  done < <(dig +short "$dom" A 2>/dev/null)
  while read -r line; do
    [ -n "$line" ] && [ "$line" = "$pub" ] && return 0
  done < <(dig +short "$dom" AAAA 2>/dev/null)
  return 1
}

# ── 确保存在 pnpm：优先 corepack，其次 npm 全局安装 ─────────────────────────
ensure_pnpm() {
  if command -v pnpm &>/dev/null; then return 0; fi
  if command -v corepack &>/dev/null; then
    echo "▸ 未检测到 pnpm，通过 corepack 启用..."
    corepack enable
    corepack prepare pnpm@latest --activate
  fi
  if command -v pnpm &>/dev/null; then return 0; fi
  local _npm
  _npm="$(command -v npm || true)"
  if [ -n "$_npm" ]; then
    echo "▸ 通过 npm 全局安装 pnpm..."
    "$_npm" install -g pnpm
  fi
  if ! command -v pnpm &>/dev/null; then
    echo "错误: 无法安装 pnpm。请执行: corepack enable && corepack prepare pnpm@latest --activate" >&2
    exit 1
  fi
}

echo ""
echo "  ◈ HomePortal 部署脚本"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  安装目录: $INSTALL_DIR"
echo ""

# ── Node.js 检查 ───────────────────────────────────────────────────────────────
echo "✓ Node.js $($NODE_BIN -v) 已安装"

# ── 服务运行用户：来自 sudo 的调用者；无 SUDO_USER 时回退 www-data ────────────
if [ -n "${SUDO_USER:-}" ]; then
  RUN_USER="$SUDO_USER"
else
  echo "提示: 未检测到 SUDO_USER（如直接以 root 运行）。将使用 www-data 运行服务；" >&2
  echo "      建议改为普通用户执行: sudo bash $0" >&2
  RUN_USER=www-data
fi

if ! id "$RUN_USER" &>/dev/null; then
  echo "错误: 系统用户 $RUN_USER 不存在" >&2
  exit 1
fi

cd "$INSTALL_DIR"

# ── 停止已有同名服务，避免更新依赖时旧进程占用端口 ──────────────────────────
if systemctl cat "${SERVICE_NAME}.service" &>/dev/null; then
  echo "▸ 检测到已有 systemd 服务「${SERVICE_NAME}」，先停止以便重新部署..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
fi
if command -v pm2 &>/dev/null && pm2 describe "$SERVICE_NAME" &>/dev/null; then
  echo "▸ 检测到 PM2 中有同名应用「${SERVICE_NAME}」，先停止并删除（本脚本使用 systemd 托管）..."
  pm2 stop "$SERVICE_NAME" 2>/dev/null || true
  pm2 delete "$SERVICE_NAME" 2>/dev/null || true
fi

# ── 目录权限 ──────────────────────────────────────────────────────────────────
_cur_u="$(stat -c '%U' "$INSTALL_DIR" 2>/dev/null || echo '')"
if ! sudo -u "$RUN_USER" test -w "$INSTALL_DIR" 2>/dev/null; then
  if [ "$_cur_u" = "root" ]; then
    echo "▸ 目录属主为 root，调整为 $RUN_USER 以便安装依赖..."
    chown -R "$RUN_USER:$RUN_USER" "$INSTALL_DIR"
  else
    echo "错误: 用户 $RUN_USER 对 $INSTALL_DIR 无写权限（当前属主: ${_cur_u:-?}）。" >&2
    echo "  请执行: sudo chown -R $RUN_USER:$RUN_USER $INSTALL_DIR" >&2
    exit 1
  fi
fi

# ── pnpm + 安装依赖 ────────────────────────────────────────────────────────────
ensure_pnpm
PNPM_BIN="$(command -v pnpm)"
echo "▸ 安装依赖: pnpm install --prod（用户: $RUN_USER，Node $($NODE_BIN -v)，$($PNPM_BIN -v)）"
LOCK_EXTRA=""
[ -f "$INSTALL_DIR/pnpm-lock.yaml" ] && LOCK_EXTRA="--frozen-lockfile"
sudo -u "$RUN_USER" \
  env HOME="$INSTALL_DIR" \
  NPM_CONFIG_CACHE="$INSTALL_DIR/.npm-cache" \
  XDG_CONFIG_HOME="$INSTALL_DIR/.config" \
  bash -c "cd '$INSTALL_DIR' && exec '$PNPM_BIN' install --prod $LOCK_EXTRA"

# ── 公网 IP（用于提示与 HTTPS 验证）──────────────────────────────────────────
PUBLIC_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || curl -s --connect-timeout 5 icanhazip.com 2>/dev/null || echo "YOUR_SERVER_IP")

# ── 是否启用 Nginx（默认启用）────────────────────────────────────────────────
USE_NGINX_RESOLVED=0
if [ "${SKIP_NGINX:-0}" = "1" ]; then
  echo "✓ 跳过 Nginx（SKIP_NGINX=1）"
elif [ "${USE_NGINX:-}" = "0" ]; then
  echo "✓ 跳过 Nginx（USE_NGINX=0）"
else
  USE_NGINX_RESOLVED=1
  echo "▸ 默认启用 Nginx（HTTP 80 → 127.0.0.1:${PORT}；USE_NGINX=0 或 SKIP_NGINX=1 可关闭）"
fi

# ── 域名解析（Nginx / HTTPS 共用）────────────────────────────────────────────
homeportal_resolve_domain
MAIN_NGINX_CONF="$(nginx_main_conf_path "$DOMAIN_RESOLVED")"
echo "▸ 主 Nginx 配置文件: $MAIN_NGINX_CONF"

# 将公网域名写入 .deploy-domain：下次直接 「sudo bash deploy.sh」 也能读到（sudo 会丢掉 DOMAIN 环境变量）
if [ -n "$DOMAIN_RESOLVED" ] && ! domain_is_nonpublic_hostname "$DOMAIN_RESOLVED"; then
  echo "$DOMAIN_RESOLVED" > "$INSTALL_DIR/.deploy-domain"
  chmod 644 "$INSTALL_DIR/.deploy-domain" 2>/dev/null || true
  chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/.deploy-domain" 2>/dev/null || true
fi

# ── 首次部署向导 ──────────────────────────────────────────────────────────────
if [ ! -f "$MARKER" ]; then
  echo ""
  echo "========== 首次部署向导 =========="
  echo "默认管理员密码为 rainy；可直接回车使用默认密码。"
  echo "建议首次改为强密码。"
  echo ""
  read -rsp "请输入管理员密码（留空则使用 rainy）: " HPWD
  echo ""
  [ -z "${HPWD:-}" ] && HPWD=rainy

  if [ -n "${PORTAL_TITLE:-}" ]; then
    PT_VALUE="$PORTAL_TITLE"
    echo "▸ 使用环境变量 PORTAL_TITLE=$PT_VALUE"
  elif [ -t 0 ]; then
    read -r -p "浏览器标签页标题 PORTAL_TITLE（回车=指引页）: " _pt_line
    PT_VALUE="${_pt_line:-指引页}"
  else
    PT_VALUE="指引页"
  fi

  JWT_SECRET_VALUE="$(openssl rand -hex 32)"

  {
    echo "PORT=$PORT"
    echo "LISTEN_HOST=127.0.0.1"
    printf 'ADMIN_PASSWORD=%q\n' "$HPWD"
    echo "JWT_SECRET=$JWT_SECRET_VALUE"
    printf 'PORTAL_TITLE=%q\n' "$PT_VALUE"
  } > "$INSTALL_DIR/.env"

  chmod 600 "$INSTALL_DIR/.env"
  chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/.env"

  mkdir -p "$INSTALL_DIR/data"
  if [ ! -s "$INSTALL_DIR/data/services.json" ]; then
    echo '[]' > "$INSTALL_DIR/data/services.json"
  fi
  chown -R "$RUN_USER:$RUN_USER" "$INSTALL_DIR/data"

  touch "$MARKER"
  chown "$RUN_USER:$RUN_USER" "$MARKER" 2>/dev/null || true

  echo ""
  echo "✓ 配置文件已生成: $INSTALL_DIR/.env"
  echo "  二次修改密码或 JWT：编辑该文件后执行: systemctl restart $SERVICE_NAME"
  echo ""
elif [ ! -f "$INSTALL_DIR/.env" ]; then
  echo "错误: 缺少 $INSTALL_DIR/.env，且已存在首次部署标记 $MARKER" >&2
  echo "请恢复 .env 或删除标记文件后重新运行: rm -f $MARKER" >&2
  exit 1
fi

# ── 从 .env 读取 PORT（不 source，避免特殊字符破坏 shell）──────────────────
_port_line="$(grep -E '^[[:space:]]*PORT=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 || true)"
APP_PORT="${_port_line#*=}"
APP_PORT="${APP_PORT//\"/}"
APP_PORT="${APP_PORT//\'/}"
APP_PORT="${APP_PORT//$'\r'/}"
APP_PORT="${APP_PORT:-3000}"
PORT="$APP_PORT"

# 旧 .env 无 LISTEN_HOST 时补全
if ! grep -qE '^[[:space:]]*LISTEN_HOST=' "$INSTALL_DIR/.env" 2>/dev/null; then
  echo "LISTEN_HOST=127.0.0.1" >> "$INSTALL_DIR/.env"
fi

# 若本次在环境中传入 PORTAL_TITLE，覆盖写入 .env（便于 bash 一行改标签名后重载）
if [ -n "${PORTAL_TITLE:-}" ] && [ -f "$INSTALL_DIR/.env" ]; then
  _tmp="$(mktemp)"
  grep -vE '^[[:space:]]*PORTAL_TITLE=' "$INSTALL_DIR/.env" > "$_tmp" 2>/dev/null || true
  printf 'PORTAL_TITLE=%q\n' "$PORTAL_TITLE" >> "$_tmp"
  mv "$_tmp" "$INSTALL_DIR/.env"
  chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/.env" 2>/dev/null || true
  chmod 600 "$INSTALL_DIR/.env" 2>/dev/null || true
  echo "▸ 已同步 PORTAL_TITLE 到 .env: $PORTAL_TITLE"
fi

# ── systemd 服务 ──────────────────────────────────────────────────────────────
UNIT="/etc/systemd/system/${SERVICE_NAME}.service"

tee "$UNIT" > /dev/null <<SYSTEMD
[Unit]
Description=HomePortal navigation homepage
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=-$INSTALL_DIR/.env
ExecStart=$NODE_BIN $INSTALL_DIR/server.js
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SYSTEMD

chown root:root "$UNIT"
chmod 644 "$UNIT"
chown -R "$RUN_USER:$RUN_USER" "$INSTALL_DIR/data" 2>/dev/null || true
chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/.env" 2>/dev/null || true

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

SYSTEMD_OK=0
systemctl is-active --quiet "$SERVICE_NAME" && SYSTEMD_OK=1
echo "▸ systemd：已启用并启动 $SERVICE_NAME（监听 127.0.0.1:${PORT}，开机自启）"

# ── Nginx 反向代理 ────────────────────────────────────────────────────────────
if [ "$USE_NGINX_RESOLVED" = "1" ]; then
  echo "▸ 安装并配置 Nginx 反向代理..."
  if apt-get update -qq && apt-get install -y nginx; then
    nginx_disable_stock_default_site
    nginx_remove_stale_default_conf_for_domain
    mkdir -p /etc/nginx/conf.d/locations
    # 已有 Let's Encrypt 证书时直接写 80/443（避免 ensure_main 仅 HTTP 覆盖掉上次部署的 HTTPS）
    if [ -n "$DOMAIN_RESOLVED" ] && ! domain_is_nonpublic_hostname "$DOMAIN_RESOLVED" \
      && [ "${USE_HTTPS:-}" != "0" ] \
      && [ -f "/etc/letsencrypt/live/${DOMAIN_RESOLVED}/fullchain.pem" ]; then
      write_main_server_block_https "$DOMAIN_RESOLVED" "$MAIN_NGINX_CONF"
    else
      ensure_main_server_block
    fi
    write_homeportal_location
    if nginx -t; then
      systemctl enable nginx
      systemctl reload nginx
      NGINX_ENABLED=1
      if [ -n "$DOMAIN_RESOLVED" ] && ! domain_is_nonpublic_hostname "$DOMAIN_RESOLVED"; then
        echo "✓ Nginx 已启用（http://${DOMAIN_RESOLVED}/ → 127.0.0.1:${PORT}）"
      else
        echo "✓ Nginx 已启用（http://${PUBLIC_IP}/ → 127.0.0.1:${PORT}）"
      fi
    else
      echo "⚠ nginx -t 失败，请检查配置后手动执行: nginx -t && systemctl reload nginx"
    fi
  else
    echo "⚠ Nginx 安装失败，将仅通过端口 ${PORT} 访问"
  fi
fi

# ── HTTPS（Let's Encrypt）────────────────────────────────────────────────────
CERTBOT_EMAIL_VAL="$(echo "${CERTBOT_EMAIL:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

if [ "$NGINX_ENABLED" != "1" ]; then
  :

elif [ "${USE_HTTPS:-}" = "0" ]; then
  echo ""
  echo "▸ USE_HTTPS=0，跳过 Let's Encrypt（仅 HTTP）"

else
  echo ""
  echo "▸ HTTPS：Let's Encrypt（DNS 预检 → dry-run → 正式签发，无交互）"
  echo "  公网 IP: $PUBLIC_IP；主配置: $MAIN_NGINX_CONF"

  if [ -n "$DOMAIN_RESOLVED" ] && domain_is_nonpublic_hostname "$DOMAIN_RESOLVED"; then
    echo "⚠ 域名「$DOMAIN_RESOLVED」不适合 Let's Encrypt，已忽略。"
    DOMAIN_RESOLVED=""
  fi

  if [ -z "$DOMAIN_RESOLVED" ]; then
    echo "⚠ 未配置可用域名，跳过 HTTPS。请使用: sudo env DOMAIN=你的域名 bash deploy.sh"
    echo "  （或 sudo -E bash deploy.sh 并在当前 shell 先 export DOMAIN=你的域名）"
    echo "  勿使用「DOMAIN=... sudo bash」，sudo 默认不会把该变量传给 root。"
  else
    [ -z "$CERTBOT_EMAIL_VAL" ] && CERTBOT_EMAIL_VAL="admin@${DOMAIN_RESOLVED}"
    echo "▸ Certbot 邮箱: $CERTBOT_EMAIL_VAL"

    if ! dns_resolves_to_public_ip "$DOMAIN_RESOLVED" "$PUBLIC_IP"; then
      echo "⚠ DNS 未指向本机 $PUBLIC_IP，跳过 certbot"
    else
      echo "▸ DNS 预检通过（$DOMAIN_RESOLVED → $PUBLIC_IP）"
      echo "▸ 安装 certbot 与 nginx 插件..."
      if apt-get install -y certbot python3-certbot-nginx; then
        echo "▸ certbot certonly --nginx --dry-run（staging）..."
        set +e
        certbot certonly --nginx \
          --dry-run \
          --non-interactive \
          --agree-tos \
          --email "$CERTBOT_EMAIL_VAL" \
          -d "$DOMAIN_RESOLVED"
        DRY_EXIT=$?
        set -e
        if [ "$DRY_EXIT" -ne 0 ]; then
          echo "⚠ certbot dry-run 失败（$DRY_EXIT），保持 HTTP。可稍后: certbot certonly --nginx -d $DOMAIN_RESOLVED"
        else
          echo "▸ dry-run 成功，正式申请证书（certonly，不修改 Nginx 配置）..."
          set +e
          certbot certonly --nginx \
            --non-interactive \
            --agree-tos \
            --email "$CERTBOT_EMAIL_VAL" \
            -d "$DOMAIN_RESOLVED"
          CERTBOT_EXIT=$?
          set -e
          if [ "$CERTBOT_EXIT" -eq 0 ]; then
            write_main_server_block_https "$DOMAIN_RESOLVED" "$MAIN_NGINX_CONF"
            if nginx -t; then
              systemctl reload nginx
              HTTPS_ENABLED=1
              echo "✓ HTTPS 已启用（Let's Encrypt；Nginx 80→301 + 443；含 locations）"
            else
              echo "⚠ 写入 HTTPS 配置后 nginx -t 失败，回退为 HTTP-only 主配置"
              ensure_main_server_block
              nginx -t && systemctl reload nginx || echo "⚠ 回退后 nginx -t 仍失败，请手动检查: nginx -t"
            fi
          else
            echo "⚠ certbot certonly 失败（$CERTBOT_EXIT），保持 HTTP"
          fi
        fi
      else
        echo "⚠ certbot 安装失败，保持 HTTP"
      fi
    fi
  fi
fi

# ── 防火墙 ────────────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
  if [ "$NGINX_ENABLED" = "1" ]; then
    echo "▸ 开放 HTTP 80..."
    ufw allow 80/tcp
    if [ "$HTTPS_ENABLED" = "1" ]; then
      echo "▸ 开放 HTTPS 443..."
      ufw allow 443/tcp
    fi
  fi
fi

# ── 完成 ──────────────────────────────────────────────────────────────────────
SERVER_IP="$PUBLIC_IP"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ 部署完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  数据目录: $INSTALL_DIR/data/"
echo "  配置文件: $INSTALL_DIR/.env"
echo ""
if [ "${SYSTEMD_OK:-0}" -eq 1 ]; then
  echo "  ✓ systemd：「$SERVICE_NAME」已运行（监听 127.0.0.1:${PORT}，不对公网暴露）"
else
  echo "  ❌ systemd：服务未 active，请执行: systemctl status $SERVICE_NAME"
fi

if [ "$HTTPS_ENABLED" = "1" ] && [ -n "$DOMAIN_RESOLVED" ]; then
  echo "  ✓ 首页（HTTPS）: https://${DOMAIN_RESOLVED}/"
  echo "  ✓ 管理后台:      https://${DOMAIN_RESOLVED}/#admin"
  echo "  ✓ Release Hub:   https://${DOMAIN_RESOLVED}/releasehub/"
  echo "  直连 Node（排障用）: http://$SERVER_IP:$PORT"
elif [ "$NGINX_ENABLED" = "1" ]; then
  if [ -n "$DOMAIN_RESOLVED" ]; then
    echo "  ✓ 首页（HTTP）: http://${DOMAIN_RESOLVED}/"
    echo "  ✓ 管理后台:     http://${DOMAIN_RESOLVED}/#admin"
    echo "  ✓ Release Hub:  http://${DOMAIN_RESOLVED}/releasehub/"
    echo "  直连 Node（排障用）: http://$SERVER_IP:$PORT"
    echo "  启用 HTTPS：确保 DNS 已解析后重新运行: sudo bash deploy.sh"
    echo "           或: certbot certonly --nginx -d $DOMAIN_RESOLVED（成功后再次运行 deploy.sh）"
  else
    echo "  ✓ 首页（HTTP）: http://$SERVER_IP/"
    echo "  ✓ 管理后台:     http://$SERVER_IP/#admin"
    echo "  ✓ Release Hub:  http://$SERVER_IP/releasehub/"
    echo "  启用 HTTPS：sudo env DOMAIN=你的域名 bash deploy.sh（或写入 .deploy-domain 后仅 sudo bash deploy.sh）"
  fi
else
  echo "  ⚠ Nginx 未安装/跳过；直连: http://127.0.0.1:${PORT}/"
fi

echo ""
echo "  与 Release Hub 共存说明："
echo "    HomePortal  → ${DOMAIN_RESOLVED:-$SERVER_IP}/ （根路径，直接域名访问）"
echo "    Release Hub → ${DOMAIN_RESOLVED:-$SERVER_IP}/releasehub/ （子路径）"
echo "    共用 Nginx server 块: $MAIN_NGINX_CONF"
echo "    各自 location 片段:   /etc/nginx/conf.d/locations/"
echo ""
echo "  常用命令:"
echo "    systemctl status $SERVICE_NAME"
echo "    journalctl -u $SERVICE_NAME -f"
echo "    systemctl restart $SERVICE_NAME"
echo "  ⚠ 防火墙：脚本已自动放行 80/443（若有 ufw）；勿将 ${PORT} 端口映射到公网。"
echo ""

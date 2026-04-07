#!/usr/bin/env bash
# ============================================
# HomePortal — Linux 一键部署
# 用法：在 HomePortal 目录执行
#   sudo bash deploy.sh
#
# 首次运行：交互设置管理员密码（默认 rainy）、生成 JWT、写 .env
# 非首次：跳过密码向导，更新依赖并刷新 systemd / Nginx
# 依赖：Node.js；脚本内 ensure_pnpm（corepack / npm -g）
# Nginx：多站并存 — 不使用 default_server；须配置明确的 server_name（HOMEPORTAL_SERVER_NAME / 交互）
#   UNIFIED_NGINX=1  与 Release Hub 等同域名不同路径：片段 unified.d/20-home-portal.conf，共用 unified-apps.conf
#   UNIFIED_SERVER_NAME、HOMEPORTAL_NGINX_PREFIX（默认 home）→ 对外 https://域名/home/
#   可选：HOMEPORTAL_FORCE_DEFAULT_SERVER=1 时仍尝试接管 default（不推荐多站环境）
# 域名：部署前（pnpm 之前）交互询问是否有公网域名；HOMEPORTAL_SERVER_NAME 写入 .env；HTTPS 若存在 Let's Encrypt 则写 :443
# 开头：停同名 systemd/PM2；结尾 ✅/❌；不自动 ufw；LISTEN_HOST=127.0.0.1
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"
MARKER="$INSTALL_DIR/.homeportal-deploy-init"
SERVICE_NAME="home-portal"
NGINX_SITE="/etc/nginx/sites-available/home-portal"
UNIFIED_NGINX="${UNIFIED_NGINX:-0}"
UNIFIED_SNIPPET_DIR="${UNIFIED_SNIPPET_DIR:-/etc/nginx/snippets/unified.d}"
UNIFIED_SITE_AVAILABLE="${UNIFIED_SITE_FILE:-/etc/nginx/sites-available/unified-apps.conf}"
UNIFIED_SITE_LINK="${UNIFIED_SITE_ENABLED_NAME:-unified-apps}"
NODE_BIN="$(command -v node || true)"

if [ "$(id -u)" -ne 0 ]; then
  echo "本脚本需要 root 以安装 systemd 与 Nginx 配置，请执行:" >&2
  echo "  sudo bash $0" >&2
  exit 1
fi

if [ -z "${NODE_BIN}" ]; then
  echo "错误: 未找到 node，请先安装 Node.js 20 LTS（如 NodeSource 或发行版仓库）。" >&2
  exit 1
fi

# 确保存在 pnpm：优先 corepack，其次 npm 全局安装
ensure_pnpm() {
  if command -v pnpm &>/dev/null; then
    return 0
  fi
  if command -v corepack &>/dev/null; then
    echo "▸ 未检测到 pnpm，通过 corepack 启用..."
    corepack enable
    corepack prepare pnpm@latest --activate
  fi
  if command -v pnpm &>/dev/null; then
    return 0
  fi
  _npm="$(command -v npm || true)"
  if [ -n "$_npm" ]; then
    echo "▸ 通过 npm 全局安装 pnpm..."
    "$_npm" install -g pnpm
  fi
  if command -v pnpm &>/dev/null; then
    return 0
  fi
  echo "错误: 无法安装 pnpm。请安装 Node 18+ 并执行: corepack enable && corepack prepare pnpm@latest --activate" >&2
  echo "  或: npm install -g pnpm" >&2
  exit 1
}
ensure_pnpm
PNPM_BIN="$(command -v pnpm)"

# 服务运行用户：来自 sudo 的调用者；无 SUDO_USER 时回退 www-data（此时会整目录 chown 给该用户）
if [ -n "${SUDO_USER:-}" ]; then
  RUN_USER="$SUDO_USER"
else
  echo "提示: 未检测到 SUDO_USER（例如用 root su 直接执行）。将使用用户 www-data 运行服务；" >&2
  echo "      建议改为: ssh 普通用户登录后执行 sudo bash $0，以便目录属主为该用户。" >&2
  RUN_USER=www-data
fi

cd "$INSTALL_DIR"

# 若已有 systemd 单元或 PM2 同名进程，先停止/移除，避免更新依赖时旧进程占用端口
homeportal_runtime_teardown() {
  if systemctl cat "${SERVICE_NAME}.service" &>/dev/null; then
    echo "▸ 检测到已有 systemd 服务「${SERVICE_NAME}」，先停止以便重新部署..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  fi
  if command -v pm2 &>/dev/null && pm2 describe "$SERVICE_NAME" &>/dev/null; then
    echo "▸ 检测到 PM2 中有同名应用「${SERVICE_NAME}」，先停止并删除（本脚本使用 systemd 托管）..."
    pm2 stop "$SERVICE_NAME" 2>/dev/null || true
    pm2 delete "$SERVICE_NAME" 2>/dev/null || true
  fi
}
homeportal_runtime_teardown

if ! id "$RUN_USER" &>/dev/null; then
  echo "错误: 系统用户 $RUN_USER 不存在" >&2
  exit 1
fi

# 安装目录必须对 RUN_USER 可写（pnpm 建 node_modules）；仅当属主为 root 时自动 chown，避免误改普通用户家目录
_cur_u="$(stat -c '%U' "$INSTALL_DIR" 2>/dev/null || echo '')"
if ! sudo -u "$RUN_USER" test -w "$INSTALL_DIR" 2>/dev/null; then
  if [ "$_cur_u" = "root" ]; then
    echo "▸ 目录属主为 root，调整为 $RUN_USER 以便安装依赖..."
    chown -R "$RUN_USER:$RUN_USER" "$INSTALL_DIR"
  else
    echo "错误: 用户 $RUN_USER 对 $INSTALL_DIR 无写权限（当前属主: ${_cur_u:-?}）。" >&2
    echo "  请执行: sudo chown -R $RUN_USER:$RUN_USER $INSTALL_DIR" >&2
    echo "  或使用: sudo -u $_cur_u bash $0（从仓库属主用户执行 sudo）" >&2
    exit 1
  fi
fi

echo "HomePortal 安装目录: $INSTALL_DIR"

# ---------- 部署前：是否公网域名（在 pnpm 等耗时步骤之前；HTTPS 须与浏览器域名一致）----------
HP_EARLY_SRV=""
_hp_sn_preview=""
_hp_sn_preview_norm=""
if [ -f "$INSTALL_DIR/.env" ]; then
  _l="$(grep -E '^[[:space:]]*HOMEPORTAL_SERVER_NAME=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 || true)"
  _hp_sn_preview="${_l#*=}"
  _hp_sn_preview="${_hp_sn_preview//\"/}"
  _hp_sn_preview="${_hp_sn_preview//\'/}"
  _hp_sn_preview="${_hp_sn_preview//$'\r'/}"
  _hp_sn_preview_norm="$(echo "${_hp_sn_preview:-}" | tr -cd '-a-zA-Z0-9._ ' | xargs)"
fi

if [ -n "${HOMEPORTAL_SERVER_NAME:-}" ]; then
  HP_EARLY_SRV=""
elif [ -n "$_hp_sn_preview_norm" ] && [ "$_hp_sn_preview_norm" != "home-portal.local" ]; then
  HP_EARLY_SRV="$_hp_sn_preview_norm"
  echo "▸ 沿用 .env 中的域名（server_name）: $HP_EARLY_SRV"
  echo "  若要修改：编辑 $INSTALL_DIR/.env 中的 HOMEPORTAL_SERVER_NAME，或执行 HOMEPORTAL_SERVER_NAME=新域名 sudo bash deploy.sh"
elif [ -t 0 ]; then
  echo ""
  echo "──────── Nginx / 公网访问 ────────"
  echo "若仅本机或内网调试，选「否」即可；若公网用域名访问（含 https），选「是」并填写域名。"
  read -r -p "是否有公网域名用于本站（与浏览器地址栏一致）？[y/N] " _hp_has_pub
  case "${_hp_has_pub}" in
    [yY][eE][sS]|[yY])
      read -r -p "请输入域名（空格分隔多个，如 www.example.com example.com）: " _hp_dom_in
      HP_EARLY_SRV="$(echo "${_hp_dom_in:-}" | tr -cd '-a-zA-Z0-9._ ' | xargs)"
      [ -z "$HP_EARLY_SRV" ] && HP_EARLY_SRV="home-portal.local"
      ;;
    *)
      HP_EARLY_SRV="home-portal.local"
      ;;
  esac
  echo "▸ 将使用 server_name: $HP_EARLY_SRV"
else
  HP_EARLY_SRV="${_hp_sn_preview_norm:-home-portal.local}"
  [ -z "$HP_EARLY_SRV" ] && HP_EARLY_SRV="home-portal.local"
fi

echo "▸ 依赖安装: pnpm install --prod（用户: $RUN_USER，Node $($NODE_BIN -v)，$($PNPM_BIN -v)）"

# HOME 指向项目目录，避免 www-data 等用户因 /var/www 不可写导致 npm/pnpm 缓存失败
LOCK_EXTRA=""
[ -f "$INSTALL_DIR/pnpm-lock.yaml" ] && LOCK_EXTRA="--frozen-lockfile"
sudo -u "$RUN_USER" \
  env HOME="$INSTALL_DIR" \
  NPM_CONFIG_CACHE="$INSTALL_DIR/.npm-cache" \
  XDG_CONFIG_HOME="$INSTALL_DIR/.config" \
  bash -c "cd '$INSTALL_DIR' && exec '$PNPM_BIN' install --prod $LOCK_EXTRA"

# ---------- 首次向导 ----------
if [ ! -f "$MARKER" ]; then
  echo ""
  echo "========== 首次部署向导 =========="
  echo "默认管理员密码为 rainy；可直接回车使用默认密码。"
  echo "建议首次改为强密码。"
  echo ""
  read -rsp "请输入管理员密码（留空则使用 rainy）: " HPWD
  echo ""
  [ -z "${HPWD:-}" ] && HPWD=rainy

  # 域名已在 pnpm 之前问过（HP_EARLY_SRV）；无则占位
  WIZ_SRV="${HP_EARLY_SRV:-home-portal.local}"
  [ -z "$WIZ_SRV" ] && WIZ_SRV="home-portal.local"

  JWT_SECRET_VALUE="$(openssl rand -hex 32)"
  PORT_VALUE="${PORT:-3000}"

  {
    echo "PORT=$PORT_VALUE"
    echo "LISTEN_HOST=127.0.0.1"
    printf 'ADMIN_PASSWORD=%q\n' "$HPWD"
    echo "JWT_SECRET=$JWT_SECRET_VALUE"
    echo "PORTAL_TITLE=指引页"
    printf 'HOMEPORTAL_SERVER_NAME=%q\n' "$WIZ_SRV"
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
  echo "已写入: $INSTALL_DIR/.env"
  echo "二次修改密码或 JWT：编辑该文件后执行:"
  echo "  sudo systemctl restart $SERVICE_NAME"
  echo ""
elif [ ! -f "$INSTALL_DIR/.env" ]; then
  echo "错误: 缺少 $INSTALL_DIR/.env，且已存在首次部署标记 $MARKER" >&2
  echo "请恢复 .env 或删除标记文件后重新运行: rm -f $MARKER" >&2
  exit 1
fi

# 从 .env 读取 PORT（不解 source，避免密码中的特殊字符破坏 shell）
_port_line="$(grep -E '^[[:space:]]*PORT=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 || true)"
APP_PORT="${_port_line#*=}"
APP_PORT="${APP_PORT//\"/}"
APP_PORT="${APP_PORT//\'/}"
APP_PORT="${APP_PORT//$'\r'/}"
APP_PORT="${APP_PORT:-3000}"

# ---------- Nginx server_name（持久化 .env 的 HOMEPORTAL_SERVER_NAME；公网/HTTPS 必须与域名一致）----------
_hp_sn_file=""
if [ -f "$INSTALL_DIR/.env" ]; then
  _l="$(grep -E '^[[:space:]]*HOMEPORTAL_SERVER_NAME=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 || true)"
  _hp_sn_file="${_l#*=}"
  _hp_sn_file="${_hp_sn_file//\"/}"
  _hp_sn_file="${_hp_sn_file//\'/}"
  _hp_sn_file="${_hp_sn_file//$'\r'/}"
fi
if [ -n "${HOMEPORTAL_SERVER_NAME:-}" ]; then
  HOMEPORTAL_SRV_NAME="$HOMEPORTAL_SERVER_NAME"
elif [ -n "${HP_EARLY_SRV:-}" ]; then
  HOMEPORTAL_SRV_NAME="$HP_EARLY_SRV"
elif [ -n "$_hp_sn_file" ]; then
  HOMEPORTAL_SRV_NAME="$_hp_sn_file"
elif [ -t 0 ]; then
  echo ""
  read -r -p "Nginx server_name（域名，空格分隔；须与浏览器访问域名一致；回车=home-portal.local）: " _hp_sn_read
  HOMEPORTAL_SRV_NAME="${_hp_sn_read:-}"
else
  HOMEPORTAL_SRV_NAME="home-portal.local"
fi
HOMEPORTAL_SRV_NAME="$(echo "${HOMEPORTAL_SRV_NAME:-home-portal.local}" | tr -cd '-a-zA-Z0-9._ ' | xargs)"
[ -z "$HOMEPORTAL_SRV_NAME" ] && HOMEPORTAL_SRV_NAME="home-portal.local"

HOMEPORTAL_PATH_SLUG=""
if [ "$UNIFIED_NGINX" = "1" ]; then
  _uun="$(echo "${UNIFIED_SERVER_NAME:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$_uun" ]; then
    echo "错误: UNIFIED_NGINX=1 时必须设置 UNIFIED_SERVER_NAME（与 Release Hub 共用，如 www.example.com）" >&2
    exit 1
  fi
  HOMEPORTAL_SRV_NAME="$_uun"
  HOMEPORTAL_PATH_SLUG="$(echo "${HOMEPORTAL_NGINX_PREFIX:-home}" | sed 's/^\/\+//;s/\/\+$//')"
  HOMEPORTAL_PATH_SLUG="$(echo "$HOMEPORTAL_PATH_SLUG" | tr -cd 'a-zA-Z0-9_-')"
  [ -z "$HOMEPORTAL_PATH_SLUG" ] && HOMEPORTAL_PATH_SLUG="home"
  echo "▸ 统一 Nginx：server_name=$HOMEPORTAL_SRV_NAME · 对外路径 /${HOMEPORTAL_PATH_SLUG}/ · HOMEPORTAL_BASE_PATH 将写入 .env"
fi

homeportal_env_sync_server_name() {
  [ ! -f "$INSTALL_DIR/.env" ] && return 0
  _tmp="$(mktemp)"
  grep -vE '^[[:space:]]*HOMEPORTAL_SERVER_NAME=' "$INSTALL_DIR/.env" > "$_tmp" 2>/dev/null || true
  printf 'HOMEPORTAL_SERVER_NAME=%q\n' "$HOMEPORTAL_SRV_NAME" >> "$_tmp"
  mv "$_tmp" "$INSTALL_DIR/.env"
  chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/.env" 2>/dev/null || true
  chmod 600 "$INSTALL_DIR/.env" 2>/dev/null || true
}
homeportal_env_sync_server_name

homeportal_env_sync_base_path() {
  [ ! -f "$INSTALL_DIR/.env" ] && return 0
  _tmp="$(mktemp)"
  if [ "$UNIFIED_NGINX" = "1" ] && [ -n "${HOMEPORTAL_PATH_SLUG:-}" ]; then
    grep -vE '^[[:space:]]*HOMEPORTAL_BASE_PATH=' "$INSTALL_DIR/.env" > "$_tmp" 2>/dev/null || true
    printf 'HOMEPORTAL_BASE_PATH=/%s\n' "$HOMEPORTAL_PATH_SLUG" >> "$_tmp"
  else
    grep -vE '^[[:space:]]*HOMEPORTAL_BASE_PATH=' "$INSTALL_DIR/.env" > "$_tmp" 2>/dev/null || true
  fi
  mv "$_tmp" "$INSTALL_DIR/.env"
  chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/.env" 2>/dev/null || true
  chmod 600 "$INSTALL_DIR/.env" 2>/dev/null || true
}
homeportal_env_sync_base_path

# 旧 .env 无 LISTEN_HOST 时补全，与 server 默认仅监听本机一致
if [ -f "$INSTALL_DIR/.env" ] && ! grep -qE '^[[:space:]]*LISTEN_HOST=' "$INSTALL_DIR/.env" 2>/dev/null; then
  echo "LISTEN_HOST=127.0.0.1" >> "$INSTALL_DIR/.env"
  chown "$RUN_USER:$RUN_USER" "$INSTALL_DIR/.env" 2>/dev/null || true
  chmod 600 "$INSTALL_DIR/.env" 2>/dev/null || true
fi

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

echo "▸ systemd：已启用并启动 $SERVICE_NAME（监听 127.0.0.1:${APP_PORT}，开机自启）"

ensure_unified_nginx_umbrella_http() {
  local sn="$1"
  mkdir -p "$UNIFIED_SNIPPET_DIR"
  if [ ! -f "$UNIFIED_SITE_AVAILABLE" ]; then
    tee "$UNIFIED_SITE_AVAILABLE" > /dev/null <<UMB
# 统一多应用 — 首次生成；子应用在 ${UNIFIED_SNIPPET_DIR} 下维护片段
server {
    listen 80;
    listen [::]:80;
    server_name ${sn};

    client_max_body_size 500M;
    client_body_timeout 300s;

    include ${UNIFIED_SNIPPET_DIR}/*.conf;
}
UMB
  fi
  ln -sf "$UNIFIED_SITE_AVAILABLE" "/etc/nginx/sites-enabled/${UNIFIED_SITE_LINK}.conf"
}

write_homeportal_unified_snippet() {
  mkdir -p "$UNIFIED_SNIPPET_DIR"
  tee "${UNIFIED_SNIPPET_DIR}/20-home-portal.conf" > /dev/null <<HPS
# HomePortal — 片段（deploy.sh）
location /${HOMEPORTAL_PATH_SLUG}/ {
    proxy_pass http://127.0.0.1:${APP_PORT}/;
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
HPS
}

# ---------- Nginx ----------
NGINX_RELOAD_OK=0
NGINX_NOT_INSTALLED=0
# 多站并存：默认仅 listen 80（无 default_server）；仅当 HOMEPORTAL_FORCE_DEFAULT_SERVER=1 时尝试接管 default
HP_HOMEPORTAL_DEFAULT=0
LISTEN_BLOCK="    listen 80;
    listen [::]:80;"
if [ "$UNIFIED_NGINX" != "1" ] && [ "${HOMEPORTAL_FORCE_DEFAULT_SERVER:-0}" = "1" ]; then
  DEFAULT_SERVER_OTHERS=()
  if [ -d /etc/nginx/sites-enabled ]; then
    for _nf in /etc/nginx/sites-enabled/*; do
      [ -e "$_nf" ] || continue
      case "$(basename "$_nf" 2>/dev/null || echo "")" in
        home-portal) continue ;;
      esac
      if grep -qE 'listen[[:space:]]+[^;]*default_server' "$_nf" 2>/dev/null; then
        DEFAULT_SERVER_OTHERS+=("$_nf")
      fi
    done
  fi
  if [ "${#DEFAULT_SERVER_OTHERS[@]}" -eq 0 ]; then
    HP_HOMEPORTAL_DEFAULT=1
    LISTEN_BLOCK="    listen 80 default_server;
    listen [::]:80 default_server;"
  else
    echo ""
    echo "▸ HOMEPORTAL_FORCE_DEFAULT_SERVER=1：下列配置含 default_server，需移除后本站点才能设为 default："
    for _nf in "${DEFAULT_SERVER_OTHERS[@]}"; do
      echo "    - $_nf"
    done
    if [ -t 0 ] && [ -z "${HOMEPORTAL_DEFAULT_SERVER+x}" ]; then
      read -r -p "是否从上述文件中移除 default_server，并将 HomePortal 设为 80 的 default？[y/N] " _hpds
      case "${_hpds}" in
        [yY][eE][sS]|[yY]) HP_HOMEPORTAL_DEFAULT=1 ;;
        *) HP_HOMEPORTAL_DEFAULT=0 ;;
      esac
    else
      case "${HOMEPORTAL_DEFAULT_SERVER:-keep}" in
        replace|yes|1|true|Y|y) HP_HOMEPORTAL_DEFAULT=1 ;;
        *) HP_HOMEPORTAL_DEFAULT=0 ;;
      esac
      if [ -z "${HOMEPORTAL_DEFAULT_SERVER+x}" ]; then
        echo "  （非交互：等同 HOMEPORTAL_DEFAULT_SERVER=keep；若需接管请设 replace）"
      fi
    fi
    if [ "$HP_HOMEPORTAL_DEFAULT" -eq 1 ]; then
      for _nf in "${DEFAULT_SERVER_OTHERS[@]}"; do
        echo "▸ 正在从 $(basename "$_nf") 移除 default_server（备份: ${_nf}.bak.homeportal）..."
        cp -a "$_nf" "${_nf}.bak.homeportal"
        sed -i '/^[[:space:]]*listen\>/s/[[:space:]]*default_server//g' "$_nf"
      done
      LISTEN_BLOCK="    listen 80 default_server;
    listen [::]:80 default_server;"
    fi
  fi
fi

# HTTPS：在 /etc/letsencrypt/live/ 下查找与 server_name 匹配的证书并生成 :443 反代（浏览器默认走 https）
HP_LE_CERT=""
HP_LE_KEY=""
_hp_sn_array=()
read -r -a _hp_sn_array <<< "$HOMEPORTAL_SRV_NAME"
for _sn in "${_hp_sn_array[@]}"; do
  [ -z "$_sn" ] && continue
  if [ -f "/etc/letsencrypt/live/${_sn}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${_sn}/privkey.pem" ]; then
    HP_LE_CERT="/etc/letsencrypt/live/${_sn}/fullchain.pem"
    HP_LE_KEY="/etc/letsencrypt/live/${_sn}/privkey.pem"
    break
  fi
done
if [ -z "$HP_LE_CERT" ] && [ -d /etc/letsencrypt/live ] && [ "$HOMEPORTAL_SRV_NAME" != "home-portal.local" ] && command -v openssl >/dev/null 2>&1; then
  for _d in /etc/letsencrypt/live/*; do
    [ -d "$_d" ] || continue
    [ "$(basename "$_d")" = "README" ] && continue
    [ -f "$_d/fullchain.pem" ] && [ -f "$_d/privkey.pem" ] || continue
    _ok=0
    for _sn in "${_hp_sn_array[@]}"; do
      [ -z "$_sn" ] && continue
      if openssl x509 -in "$_d/fullchain.pem" -noout -text 2>/dev/null | grep -Fq "DNS:$_sn"; then
        _ok=1
        break
      fi
    done
    if [ "$_ok" -eq 1 ]; then
      HP_LE_CERT="$_d/fullchain.pem"
      HP_LE_KEY="$_d/privkey.pem"
      break
    fi
  done
fi

HP_SSL_EXTRA=""
[ -f /etc/letsencrypt/options-ssl-nginx.conf ] && HP_SSL_EXTRA="    include /etc/letsencrypt/options-ssl-nginx.conf;
"
[ -f /etc/letsencrypt/ssl-dhparams.pem ] && HP_SSL_EXTRA+="    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
"

HP_SSL_SERVER_BLOCK=""
if [ "$UNIFIED_NGINX" != "1" ] && [ -n "$HP_LE_CERT" ]; then
  HP_SSL_SERVER_BLOCK="$(cat <<SSLBLK

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${HOMEPORTAL_SRV_NAME};

    ssl_certificate ${HP_LE_CERT};
    ssl_certificate_key ${HP_LE_KEY};
${HP_SSL_EXTRA}
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
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
}
SSLBLK
)"
fi

if command -v nginx >/dev/null 2>&1; then
  if [ "$UNIFIED_NGINX" = "1" ]; then
    ensure_unified_nginx_umbrella_http "$HOMEPORTAL_SRV_NAME"
    write_homeportal_unified_snippet
    rm -f /etc/nginx/sites-enabled/home-portal
    if nginx -t; then
      systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true
      NGINX_RELOAD_OK=1
      echo "▸ 统一 Nginx：已写入 ${UNIFIED_SNIPPET_DIR}/20-home-portal.conf · 主配置 $UNIFIED_SITE_AVAILABLE"
      echo "  访问: http://${HOMEPORTAL_SRV_NAME}/${HOMEPORTAL_PATH_SLUG}/ （HTTPS 请对 ${UNIFIED_SITE_AVAILABLE##*/} 执行 certbot）"
    else
      echo "警告: nginx -t 失败，请检查片段与 $UNIFIED_SITE_AVAILABLE" >&2
    fi
  else
    tee "$NGINX_SITE" > /dev/null <<NGINX
# HomePortal — 由 deploy.sh 生成（多站默认无 default_server；见 HOMEPORTAL_FORCE_DEFAULT_SERVER）
# HTTPS：若存在 Let's Encrypt 证书则自动生成下方 :443 块
server {
${LISTEN_BLOCK}
    server_name ${HOMEPORTAL_SRV_NAME};

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
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
}
${HP_SSL_SERVER_BLOCK}
NGINX

    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/home-portal

    if nginx -t; then
      systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true
      NGINX_RELOAD_OK=1
      _hp_ssl_note=""
      [ -n "$HP_LE_CERT" ] && _hp_ssl_note=" · HTTPS:443 已用证书反代（${HP_LE_CERT}）"
      if [ "$HP_HOMEPORTAL_DEFAULT" -eq 1 ]; then
        echo "▸ Nginx：本站点为 80 的 default_server · server_name ${HOMEPORTAL_SRV_NAME} · → 127.0.0.1:${APP_PORT}${_hp_ssl_note}（已 reload）"
      else
        echo "▸ Nginx：未使用 default_server · server_name ${HOMEPORTAL_SRV_NAME} · → 127.0.0.1:${APP_PORT}${_hp_ssl_note}（已 reload）"
        echo ""
        echo "  提示：请用与 server_name 一致的域名访问；单机多站勿复用域名。"
        if [ -z "$HP_LE_CERT" ]; then
          echo "  HTTPS：未检测到 Let's Encrypt 证书路径时未写 :443；需要 HTTPS 时请 certbot 签发后重跑本脚本。"
        fi
      fi
      if [ -z "$HP_LE_CERT" ] && [ "$HOMEPORTAL_SRV_NAME" != "home-portal.local" ]; then
        echo ""
        echo "▸ 未找到与 server_name 匹配的 /etc/letsencrypt/live/ 证书，HTTPS 可能仍由其他站点处理。"
        echo "  可先: sudo certbot certonly --nginx -d www.你的域名.com   然后再次执行: sudo bash deploy.sh"
      fi
    else
      echo "警告: nginx -t 失败，请检查: $NGINX_SITE" >&2
      if grep -q "443" "$NGINX_SITE" 2>/dev/null; then
        echo "  若提示 conflicting server name 或 duplicate listen，请检查 sites-enabled 是否已有同名域名的其它 SSL 配置，可暂时禁用冲突文件后重试。" >&2
      fi
    fi
  fi
else
  NGINX_NOT_INSTALLED=1
  echo ""
  echo "未检测到 Nginx。若需从 80 端口访问，可安装后重新执行:"
  echo "  sudo apt-get update && sudo apt-get install -y nginx"
  echo "  sudo bash $(basename "$0")"
fi

echo ""
echo "──────── 部署结果 ────────"
if [ "${SYSTEMD_OK:-0}" -eq 1 ]; then
  echo "✅ systemd：「$SERVICE_NAME」已运行（监听 127.0.0.1:${APP_PORT}，不对公网暴露）"
else
  echo "❌ systemd：服务未 active，请执行: systemctl status $SERVICE_NAME"
fi

if [ "${NGINX_NOT_INSTALLED:-0}" -eq 1 ]; then
  echo "❌ Nginx：未安装；仅能通过 127.0.0.1:${APP_PORT} 本机访问，公网请装 Nginx 后再放行 80"
elif [ "${NGINX_RELOAD_OK:-0}" -eq 1 ]; then
  echo "✅ Nginx：反代已 reload（server_name ${HOMEPORTAL_SRV_NAME}）"
else
  if command -v nginx &>/dev/null; then
    echo "❌ Nginx：nginx -t 失败或未 reload，请检查: $NGINX_SITE"
  else
    echo "❌ Nginx：状态异常"
  fi
fi

[ -f "$INSTALL_DIR/.env" ] && echo "✅ 配置：$INSTALL_DIR/.env（含 LISTEN_HOST）" || echo "❌ 配置：缺少 $INSTALL_DIR/.env"

echo "⚠ 防火墙：脚本不执行 ufw；公网一般只放行 80，勿映射 ${APP_PORT} 到公网。"

echo ""
echo "访问与路径"
echo "────────────────────────────────────────"
printf "  %-16s %s\n" "本机首页" "http://127.0.0.1:${APP_PORT}/"
printf "  %-16s %s\n" "本机后台" "http://127.0.0.1:${APP_PORT}/admin.html"
if [ "${NGINX_RELOAD_OK:-0}" -eq 1 ]; then
  if [ "${HP_HOMEPORTAL_DEFAULT:-0}" -eq 1 ]; then
    printf "  %-16s %s\n" "公网:80" "未匹配其他 server 时落到本站（已启用 default_server）"
  else
    printf "  %-16s %s\n" "公网:80" "请使用与 HOMEPORTAL_SERVER_NAME 一致的域名访问"
  fi
fi
printf "  %-16s %s\n" "本机排障" "SSH 后: curl -sI http://127.0.0.1:${APP_PORT}/"

echo ""
echo "💡 温馨提醒"
echo "  · 默认密码 rainy，登录后请改为强密码；JWT/密码见 $INSTALL_DIR/.env"
echo "  · 勿将 LISTEN_HOST 改为 0.0.0.0 除非清楚风险；生产环境应仅 127.0.0.1 + Nginx。"
echo "  · 多站点：请设 HOMEPORTAL_SERVER_NAME=你的域名；勿与其它 vhost 冲突。统一域名多路径：UNIFIED_NGINX=1 + UNIFIED_SERVER_NAME + HOMEPORTAL_NGINX_PREFIX（默认 home）。"
echo "  · 若单机只要一站且需接管 IP 访问可设 HOMEPORTAL_FORCE_DEFAULT_SERVER=1。"
echo "  · 常用：systemctl status $SERVICE_NAME · journalctl -u $SERVICE_NAME -f · sudo systemctl restart $SERVICE_NAME"
echo ""

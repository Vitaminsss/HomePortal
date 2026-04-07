#!/usr/bin/env bash
# ============================================
# HomePortal — Linux 一键部署
# 用法：在 HomePortal 目录执行
#   sudo bash deploy.sh
#
# 首次运行：交互设置管理员密码（默认 rainy）、生成 JWT、写 .env
# 非首次：跳过密码向导，更新依赖并刷新 systemd / Nginx
# 依赖：Node.js；脚本内 ensure_pnpm（corepack / npm -g）
# Nginx：检测其他站点是否占用 default_server；可交互是否移除并让本站点成为 default
#   非交互：HOMEPORTAL_DEFAULT_SERVER=replace|keep（默认 keep，不改动他站）
# 开头：停同名 systemd/PM2；结尾 ✅/❌；不自动 ufw；LISTEN_HOST=127.0.0.1
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"
MARKER="$INSTALL_DIR/.homeportal-deploy-init"
SERVICE_NAME="home-portal"
NGINX_SITE="/etc/nginx/sites-available/home-portal"
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

  JWT_SECRET_VALUE="$(openssl rand -hex 32)"
  PORT_VALUE="${PORT:-3000}"

  {
    echo "PORT=$PORT_VALUE"
    echo "LISTEN_HOST=127.0.0.1"
    printf 'ADMIN_PASSWORD=%q\n' "$HPWD"
    echo "JWT_SECRET=$JWT_SECRET_VALUE"
    echo "PORTAL_TITLE=指引页"
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

# ---------- Nginx ----------
NGINX_RELOAD_OK=0
NGINX_NOT_INSTALLED=0
# server_name 使用唯一占位名（默认 home-portal.local）；公网域名请设 HOMEPORTAL_SERVER_NAME
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

HP_HOMEPORTAL_DEFAULT=0
if [ "${#DEFAULT_SERVER_OTHERS[@]}" -eq 0 ]; then
  HP_HOMEPORTAL_DEFAULT=1
else
  echo ""
  echo "▸ Nginx：下列已启用配置中含有 default_server（未匹配的 Host / 直连 IP:80 时会落到该站点，易表现为「仍是 Nginx 默认页」或错站）："
  for _nf in "${DEFAULT_SERVER_OTHERS[@]}"; do
    echo "    - $_nf"
  done
  if [ -t 0 ] && [ -z "${HOMEPORTAL_DEFAULT_SERVER+x}" ]; then
    read -r -p "是否从上述文件中移除 default_server，并将 HomePortal 设为 80 的 default 站点？[y/N] " _hpds
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
      echo "  （非交互：默认不改动他站，等同 HOMEPORTAL_DEFAULT_SERVER=keep；若需接管请设 replace）"
    fi
  fi
  if [ "$HP_HOMEPORTAL_DEFAULT" -eq 1 ]; then
    for _nf in "${DEFAULT_SERVER_OTHERS[@]}"; do
      echo "▸ 正在从 $(basename "$_nf") 移除 default_server（备份: ${_nf}.bak.homeportal）..."
      cp -a "$_nf" "${_nf}.bak.homeportal"
      sed -i '/^[[:space:]]*listen\>/s/[[:space:]]*default_server//g' "$_nf"
    done
  fi
fi

if [ "$HP_HOMEPORTAL_DEFAULT" -eq 1 ]; then
  LISTEN_BLOCK="    listen 80 default_server;
    listen [::]:80 default_server;"
else
  LISTEN_BLOCK="    listen 80;
    listen [::]:80;"
fi

HOMEPORTAL_SRV_NAME="${HOMEPORTAL_SERVER_NAME:-home-portal.local}"
HOMEPORTAL_SRV_NAME="$(echo "$HOMEPORTAL_SRV_NAME" | tr -cd 'a-zA-Z0-9._-')"
[ -z "$HOMEPORTAL_SRV_NAME" ] && HOMEPORTAL_SRV_NAME="home-portal.local"

if command -v nginx >/dev/null 2>&1; then
  tee "$NGINX_SITE" > /dev/null <<NGINX
# HomePortal — 由 deploy.sh 生成
# default_server：见本脚本对「他站 default」的检测与交互；HTTPS/443 请单独检查 ssl 站点中的 server_name
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
NGINX

  if [ -L /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/home-portal

  if nginx -t; then
    systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true
    NGINX_RELOAD_OK=1
    if [ "$HP_HOMEPORTAL_DEFAULT" -eq 1 ]; then
      echo "▸ Nginx：本站点为 80 的 default_server · server_name ${HOMEPORTAL_SRV_NAME} · → 127.0.0.1:${APP_PORT}（已 reload）"
    else
      echo "▸ Nginx：未使用 default_server · server_name ${HOMEPORTAL_SRV_NAME} · → 127.0.0.1:${APP_PORT}（已 reload）"
      echo ""
      echo "  提示：用域名访问时请保证浏览器 Host 与 server_name 一致，或执行本脚本时选择接管 default。"
      echo "  HTTPS 若仍异常，请检查 sites-enabled 里 :443 的 server_name / ssl 是否与证书域名一致（本脚本只写 HTTP:80）。"
    fi
  else
    echo "警告: nginx -t 失败，请检查: $NGINX_SITE" >&2
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
    printf "  %-16s %s\n" "公网:80" "未匹配其他 server 时将到本站（default_server）"
  else
    printf "  %-16s %s\n" "公网:80" "请使用与 server_name 一致的域名访问，或重跑脚本并选择接管 default"
  fi
fi
printf "  %-16s %s\n" "本机排障" "SSH 后: curl -sI http://127.0.0.1:${APP_PORT}/"

echo ""
echo "💡 温馨提醒"
echo "  · 默认密码 rainy，登录后请改为强密码；JWT/密码见 $INSTALL_DIR/.env"
echo "  · 勿将 LISTEN_HOST 改为 0.0.0.0 除非清楚风险；生产环境应仅 127.0.0.1 + Nginx。"
echo "  · 多站点：请设 HOMEPORTAL_SERVER_NAME=你的域名，或部署时选择是否将 HomePortal 设为 default_server。"
echo "  · 常用：systemctl status $SERVICE_NAME · journalctl -u $SERVICE_NAME -f · sudo systemctl restart $SERVICE_NAME"
echo ""

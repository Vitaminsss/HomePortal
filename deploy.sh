#!/usr/bin/env bash
# ============================================
# HomePortal — Linux 一键部署
# 用法：在 HomePortal 目录执行
#   sudo bash deploy.sh
#
# 首次运行：交互设置管理员密码（默认 rainy）、生成 JWT、写 .env
# 非首次：跳过密码向导，更新依赖并刷新 systemd / Nginx
# 开头：若已有同名 systemd / PM2 则先停止；结尾：✅/❌ 汇总；不自动 ufw；Node 默认 LISTEN_HOST=127.0.0.1
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"
MARKER="$INSTALL_DIR/.homeportal-deploy-init"
SERVICE_NAME="home-portal"
NGINX_SITE="/etc/nginx/sites-available/home-portal"
NODE_BIN="$(command -v node || true)"
NPM_BIN="$(command -v npm || true)"

if [ "$(id -u)" -ne 0 ]; then
  echo "本脚本需要 root 以安装 systemd 与 Nginx 配置，请执行:" >&2
  echo "  sudo bash $0" >&2
  exit 1
fi

if [ -z "${NODE_BIN}" ] || [ -z "${NPM_BIN}" ]; then
  echo "错误: 未找到 node 或 npm，请先安装 Node.js (建议 LTS)。" >&2
  exit 1
fi

# 服务运行用户：来自 sudo 的调用者；纯 root su 时回退 www-data
if [ -n "${SUDO_USER:-}" ]; then
  RUN_USER="$SUDO_USER"
else
  echo "提示: 未检测到 SUDO_USER，服务将以 www-data 用户运行；建议用「普通用户 sudo」执行本脚本。" >&2
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

# 若目录属主为 root 且通过「用户 sudo」调用，整目录交给该用户以便 npm 写入
if [ "$(stat -c '%U' "$INSTALL_DIR" 2>/dev/null || echo root)" = root ] && [ -n "${SUDO_USER:-}" ]; then
  chown -R "$RUN_USER:$RUN_USER" "$INSTALL_DIR"
fi

echo "HomePortal 安装目录: $INSTALL_DIR"
echo "依赖安装 (npm install --production)，用户: $RUN_USER ..."
if id "$RUN_USER" &>/dev/null; then
  sudo -u "$RUN_USER" bash -c "cd '$INSTALL_DIR' && npm install --production"
else
  echo "错误: 系统用户 $RUN_USER 不存在" >&2
  exit 1
fi

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
# server_name 使用唯一占位名（默认 home-portal.local），勿用 _，避免与同机 release-hub 等冲突
# 可通过环境变量覆盖：HOMEPORTAL_SERVER_NAME=portal.example.com sudo bash deploy.sh
# 与同机其他站点不能同时声明 default_server，否则 nginx -t 报错 duplicate default server
OTHER_HAS_DEFAULT=0
if [ -d /etc/nginx/sites-enabled ]; then
  for f in /etc/nginx/sites-enabled/*; do
    [ -e "$f" ] || continue
    case "$(basename "$f" 2>/dev/null || echo "")" in
      home-portal) continue ;;
    esac
    if grep -qE 'listen[[:space:]]+.*default_server' "$f" 2>/dev/null; then
      OTHER_HAS_DEFAULT=1
      break
    fi
  done
fi

if [ "$OTHER_HAS_DEFAULT" -eq 1 ]; then
  LISTEN_BLOCK="    # no default_server here: another site (e.g. release-hub) already has it
    listen 80;
    listen [::]:80;"
else
  LISTEN_BLOCK="    listen 80 default_server;
    listen [::]:80 default_server;"
fi

HOMEPORTAL_SRV_NAME="${HOMEPORTAL_SERVER_NAME:-home-portal.local}"
HOMEPORTAL_SRV_NAME="$(echo "$HOMEPORTAL_SRV_NAME" | tr -cd 'a-zA-Z0-9._-')"
[ -z "$HOMEPORTAL_SRV_NAME" ] && HOMEPORTAL_SRV_NAME="home-portal.local"

if command -v nginx >/dev/null 2>&1; then
  tee "$NGINX_SITE" > /dev/null <<NGINX
# HomePortal — 由 deploy.sh 生成
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
    echo "▸ Nginx：server_name ${HOMEPORTAL_SRV_NAME} · 80 → 127.0.0.1:${APP_PORT}（已 reload）"
    if [ "$OTHER_HAS_DEFAULT" -eq 1 ]; then
      echo ""
      echo "提示: 检测到本机已有站点使用 default_server（例如 release-hub）。"
      echo "      本配置未声明 default_server，避免 nginx 冲突；访问 IP:80 时仍由该站点响应。"
      echo "      访问 HomePortal 请使用: http://127.0.0.1:${APP_PORT}/ 或合并两服务的 location 到同一 server。"
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
  printf "  %-16s %s\n" "经 Nginx:80" "视 default_server 而定；同机多站时可能非本站"
fi
printf "  %-16s %s\n" "本机排障" "SSH 后: curl -sI http://127.0.0.1:${APP_PORT}/"

echo ""
echo "💡 温馨提醒"
echo "  · 默认密码 rainy，登录后请改为强密码；JWT/密码见 $INSTALL_DIR/.env"
echo "  · 勿将 LISTEN_HOST 改为 0.0.0.0 除非清楚风险；生产环境应仅 127.0.0.1 + Nginx。"
echo "  · 与同机 Release Hub 并存且未占 default_server 时，公网 IP:80 可能先到其他站点。"
echo "  · 常用：systemctl status $SERVICE_NAME · journalctl -u $SERVICE_NAME -f · sudo systemctl restart $SERVICE_NAME"
echo ""

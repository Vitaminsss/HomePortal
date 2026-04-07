#!/usr/bin/env bash
# ============================================
# HomePortal — Linux 一键部署
# 用法：在 HomePortal 目录执行
#   sudo bash deploy.sh
#
# 首次运行：交互设置管理员密码（默认 rainy）、生成 JWT、写 .env
# 非首次：跳过密码向导，更新依赖并刷新 systemd / Nginx
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

echo "systemd: 已启用并启动 $SERVICE_NAME（开机自启）"

# ---------- Nginx ----------
if command -v nginx >/dev/null 2>&1; then
  tee "$NGINX_SITE" > /dev/null <<NGINX
# HomePortal — 由 deploy.sh 生成
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

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
    echo "Nginx: 已配置反代 80 -> 127.0.0.1:${APP_PORT}，并已 reload"
  else
    echo "警告: nginx -t 失败，请检查: $NGINX_SITE" >&2
  fi
else
  echo ""
  echo "未检测到 Nginx。若需从 80 端口访问，可安装后重新执行:"
  echo "  sudo apt-get update && sudo apt-get install -y nginx"
  echo "  sudo bash $(basename "$0")"
fi

echo ""
echo "完成。直连 Node: http://127.0.0.1:${APP_PORT}/  管理后台: /admin.html"
echo "修改密码: sudo nano $INSTALL_DIR/.env  然后: sudo systemctl restart $SERVICE_NAME"

# HomePortal

替代 Nginx 默认页的精美导航首页，支持管理员自由添加、编辑、排序服务入口。

## 快速开始（本地）

```bash
cd HomePortal

# 安装依赖
npm install

# 复制并配置环境变量
cp .env.example .env
# 修改 .env 中的 ADMIN_PASSWORD 和 JWT_SECRET

# 启动
npm start
```

访问 `http://localhost:3000` 查看首页，`/admin.html` 进入管理后台。

## Linux 一键部署（systemd + Nginx）

在服务器上将本仓库置于任意目录（例如 `/home/你的用户/HomePortal`），**使用普通用户通过 sudo 执行**（以便服务以你的用户运行、npm 可写 `node_modules`）：

```bash
cd HomePortal
sudo bash deploy.sh
```

脚本会：

1. **首次运行**：提示设置管理员密码；**默认密码为 `rainy`**，直接回车即采用；并自动生成 `JWT_SECRET`、写入 `.env`、创建标记文件 `.homeportal-deploy-init`（仅首次出现向导）。
2. **非首次**：跳过密码向导，执行 `npm install --production`、刷新 systemd 与 Nginx。
3. 注册并启用 `**home-portal`** systemd 服务（**开机自启**）。
4. 若已安装 **Nginx**：写入 `sites-available/home-portal`，将 **80 端口**反代到本服务监听端口（默认 `3000`），并禁用默认 `default` 站点（若存在）以避免与 `default_server` 冲突。

**二次修改密码或 JWT**：编辑安装目录下的 `.env`，然后执行：

```bash
sudo systemctl restart home-portal
```

**注意**：写入 `/etc/systemd/system/`、`/etc/nginx/` 需要 root；不要在无 `SUDO_USER` 的纯 `root` shell 下运行（脚本会回退为 `www-data` 用户，可能导致目录权限不符合预期）。推荐：`ssh user@server` 后 `sudo bash deploy.sh`。

若未安装 Nginx，脚本会提示安装命令；安装后再次执行 `sudo bash deploy.sh` 即可生成反代配置。

## 与 Nginx 集成（手动示例）

在已有 Nginx、未使用本脚本时，可将根路径反代到本服务：

```nginx
server {
    listen 80;
    server_name example.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /release/ {
        proxy_pass http://127.0.0.1:3721/;
    }
}
```

## 环境变量


| 变量               | 说明       | 默认值              |
| ---------------- | -------- | ---------------- |
| `PORT`           | 服务监听端口   | `3000`           |
| `ADMIN_PASSWORD` | 管理员登录密码  | `rainy`（生产环境请修改） |
| `JWT_SECRET`     | JWT 签名密钥 | 内置（需修改）          |
| `PORTAL_TITLE`   | 首页标题     | `指引页`            |


## 功能

- **首页**：展示所有服务卡片，支持实时搜索，每个卡片有独立主题色；可在后台填写「对外显示地址」，避免展示内网端口
- **管理后台**：密码保护，添加/编辑/删除/排序服务，七天 Token 免登录
- **数据存储**：JSON 文件，零外部依赖


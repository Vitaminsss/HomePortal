require('dotenv').config();

const express = require('express');
const fs      = require('fs');
const path    = require('path');
const jwt     = require('jsonwebtoken');
const cors    = require('cors');

const app  = express();
const PORT = parseInt(process.env.PORT, 10) || 3000;
// 生产环境建议 127.0.0.1 + Nginx 反代；局域网调试可设 LISTEN_HOST=0.0.0.0
const LISTEN_HOST = process.env.LISTEN_HOST || '127.0.0.1';

const DATA_FILE      = path.join(__dirname, 'data', 'services.json');
const JWT_SECRET     = process.env.JWT_SECRET     || 'homeportal-secret-change-me';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'rainy';
const PORTAL_TITLE   = process.env.PORTAL_TITLE   || '指引页';

app.use(cors());
app.use(express.json());

// 管理后台对外地址用 /#admin；iframe 内嵌需 ?embed=1 否则重定向会与嵌套冲突
app.get('/admin.html', (req, res) => {
  if (req.query.embed === '1') {
    return res.sendFile(path.join(__dirname, 'public', 'admin.html'));
  }
  res.redirect(302, '/#admin');
});
app.get('/admin', (_req, res) => {
  res.redirect(302, '/#admin');
});

app.use(express.static(path.join(__dirname, 'public')));

// ── Data helpers ──────────────────────────────────────────────────────────────

function ensureData() {
  const dir = path.dirname(DATA_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  if (!fs.existsSync(DATA_FILE)) fs.writeFileSync(DATA_FILE, '[]', 'utf-8');
}

function load() {
  ensureData();
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf-8')); }
  catch { return []; }
}

function save(services) {
  ensureData();
  fs.writeFileSync(DATA_FILE, JSON.stringify(services, null, 2), 'utf-8');
}

// ── Auth middleware ───────────────────────────────────────────────────────────

function auth(req, res, next) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Bearer ')) return res.status(401).json({ error: '未授权' });
  try {
    jwt.verify(header.slice(7), JWT_SECRET);
    next();
  } catch {
    res.status(401).json({ error: 'Token 无效或已过期' });
  }
}

// ── Routes ────────────────────────────────────────────────────────────────────

// Portal config (public)
app.get('/api/config', (_req, res) => {
  res.json({ title: PORTAL_TITLE });
});

// Login
app.post('/api/auth', (req, res) => {
  const { password } = req.body || {};
  if (!password || password !== ADMIN_PASSWORD) {
    return res.status(401).json({ error: '密码错误' });
  }
  const token = jwt.sign({ role: 'admin' }, JWT_SECRET, { expiresIn: '7d' });
  res.json({ token });
});

// List services (public)
app.get('/api/services', (_req, res) => {
  const services = load().sort((a, b) => (a.order ?? 9999) - (b.order ?? 9999));
  res.json(services);
});

// Add service
app.post('/api/services', auth, (req, res) => {
  const { name, url, description, displayUrl, icon, color, tags, status } = req.body || {};
  if (!name || !url) return res.status(400).json({ error: 'name 和 url 为必填项' });

  const services = load();
  const service = {
    id:          Date.now().toString(36) + Math.random().toString(36).slice(2, 5),
    name:        name.trim(),
    url:         url.trim(),
    displayUrl:  (displayUrl || '').trim(),
    description: (description || '').trim(),
    icon:        (icon != null && String(icon).trim()) ? String(icon).trim() : '',
    color:       color || '#c8ff00',
    tags:        Array.isArray(tags) ? tags.map(t => t.trim()).filter(Boolean) : [],
    status:      status || 'active',
    order:       services.length,
    createdAt:   new Date().toISOString(),
  };

  services.push(service);
  save(services);
  res.status(201).json(service);
});

// Update service
app.put('/api/services/:id', auth, (req, res) => {
  const services = load();
  const idx = services.findIndex(s => s.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: '服务不存在' });

  const merged = { ...services[idx], ...req.body, id: services[idx].id };
  if (merged.displayUrl !== undefined) merged.displayUrl = String(merged.displayUrl || '').trim();
  if (merged.icon !== undefined) merged.icon = String(merged.icon || '').trim();
  services[idx] = merged;
  save(services);
  res.json(services[idx]);
});

// Delete service
app.delete('/api/services/:id', auth, (req, res) => {
  let services = load();
  const before = services.length;
  services = services.filter(s => s.id !== req.params.id);
  if (services.length === before) return res.status(404).json({ error: '服务不存在' });

  services.forEach((s, i) => { s.order = i; });
  save(services);
  res.json({ ok: true });
});

// Reorder services
app.put('/api/reorder', auth, (req, res) => {
  const { ids } = req.body || {};
  if (!Array.isArray(ids)) return res.status(400).json({ error: 'ids 必须为数组' });

  const services = load();
  const map = Object.fromEntries(services.map(s => [s.id, s]));
  const reordered = ids.map((id, i) => {
    if (!map[id]) return null;
    map[id].order = i;
    return map[id];
  }).filter(Boolean);

  // Append any services not in the id list at the end
  services.forEach(s => {
    if (!ids.includes(s.id)) reordered.push(s);
  });

  save(reordered);
  res.json(reordered);
});

// ── Start ─────────────────────────────────────────────────────────────────────

app.listen(PORT, LISTEN_HOST, () => {
  console.log(`\n  🌐 HomePortal  →  http://${LISTEN_HOST}:${PORT}`);
  console.log(`  🔧 Admin Panel →  http://${LISTEN_HOST}:${PORT}/#admin`);
  console.log(`  📁 Data file   →  ${DATA_FILE}\n`);
});

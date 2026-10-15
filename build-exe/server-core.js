/* ============================================================
 * githup 桌面版 —— 本地服务端（零第三方依赖）
 *
 * 它承担三件事：
 *   1) 托管 web/ 目录（从 Android 版 assets/web 原样搬来的前端）；
 *   2) 充当 GitHub API 的本地代理 —— 浏览器里 file:// 页面没有同源，
 *      直连会被 CORS 挡下，所有请求都从这里转发出去；
 *   3) 提供原本由 Android 原生层实现的能力：加密存储令牌/设置、
 *      文件选择与暂存、上传、下载、日志、keystore 生成。
 *
 * 只监听 127.0.0.1 —— 不对外暴露。
 * ============================================================ */
'use strict';

const http = require('http');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const zlib = require('zlib');
const { execFile } = require('child_process');

/* ---------------- 运行形态 ----------------
 *
 * 两种形态共用这一份代码：
 *   · 打包成 exe（Node 单文件可执行）：前端文件已随包内嵌在
 *     globalThis.__GH_WEB_FILES__ 里，数据目录建在 exe 旁边；
 *   · 开发态（node server.js）：前端从磁盘 web/ 读，数据建在项目下。
 */
const SEA = (function () {
  try { return require('node:sea').isSea(); } catch (e) { return false; }
})();
const EMBED = globalThis.__GH_WEB_FILES__ || null;
const APP_VER = '1.2.15';

/* 数据放哪：先是 exe 旁边，写不进去（比如放在 Program Files 下）
 * 就退回用户目录。直接抛异常的话，用户双击 exe 会看到一个一闪而过的窗口，
 * 什么线索都没有。 */
function pickRoot() {
  const candidates = [];
  if (SEA) candidates.push(path.dirname(process.execPath));
  else candidates.push(__dirname);
  try {
    candidates.push(path.join(os.homedir(), 'githup-desktop'));
    candidates.push(path.join(os.tmpdir(), 'githup-desktop'));
  } catch (e) { /* homedir 取不到就算了 */ }
  for (const c of candidates) {
    try {
      fs.mkdirSync(c, { recursive: true });
      const probe = path.join(c, '.write-test');
      fs.writeFileSync(probe, '1');
      fs.unlinkSync(probe);
      return c;
    } catch (e) { /* 这个位置不行，试下一个 */ }
  }
  return candidates[0];
}

const ROOT = pickRoot();
const WEB = path.join(ROOT, 'web');
const DATA = path.join(ROOT, 'data');
const DOWNLOADS = path.join(ROOT, 'downloads');
const LOGS = path.join(ROOT, 'logs');

/** 从内嵌资源取文件；没打包或没有这个文件就返回 null */
function embedded(rel) {
  if (!EMBED) return null;
  const k = String(rel).replace(/^\/+/, '');
  const v = EMBED[k];
  return v == null ? null : Buffer.from(v, 'base64');
}

/* ---------------- 目录与密钥 ---------------- */

for (const d of [DATA, DOWNLOADS, LOGS]) {
  try { if (!fs.existsSync(d)) fs.mkdirSync(d, { recursive: true }); } catch (e) { /* 建不出来也别崩 */ }
}

/**
 * 本地数据密钥。
 *
 * 令牌、TOTP 账户这些敏感项存在磁盘上时用它加密（AES-256-GCM）。
 * 它本身也只是一台电脑上普通用户可读的文件 —— 这点必须诚实说明：
 * 桌面端没有 Android Keystore 那种硬件背书，它能挡住的是「随手翻开
 * JSON 就看到明文令牌」，挡不住已经能读你用户目录的人。
 */
const KEY_FILE = path.join(DATA, 'key.bin');
let MASTER_KEY;
if (fs.existsSync(KEY_FILE)) {
  MASTER_KEY = fs.readFileSync(KEY_FILE);
} else {
  MASTER_KEY = crypto.randomBytes(32);
  fs.writeFileSync(KEY_FILE, MASTER_KEY, { mode: 0o600 });
}

function encrypt(plain) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', MASTER_KEY, iv);
  const enc = Buffer.concat([c.update(String(plain), 'utf8'), c.final()]);
  const tag = c.getAuthTag();
  return Buffer.concat([iv, tag, enc]).toString('base64');
}

function decrypt(packed) {
  try {
    const buf = Buffer.from(String(packed), 'base64');
    const iv = buf.subarray(0, 12);
    const tag = buf.subarray(12, 28);
    const enc = buf.subarray(28);
    const d = crypto.createDecipheriv('aes-256-gcm', MASTER_KEY, iv);
    d.setAuthTag(tag);
    return Buffer.concat([d.update(enc), d.final()]).toString('utf8');
  } catch (e) {
    return null;
  }
}

/* ---------------- 本地存储（store） ---------------- */

const STORE_FILE = path.join(DATA, 'store.enc');
let store = { token: '', prefs: {}, totp: '', logs: [] };

function loadStore() {
  if (!fs.existsSync(STORE_FILE)) return;
  const raw = decrypt(fs.readFileSync(STORE_FILE, 'utf8'));
  if (!raw) return;
  try {
    const o = JSON.parse(raw);
    if (o && typeof o === 'object') store = Object.assign(store, o);
  } catch (e) { /* 损坏就当没有，不阻塞启动 */ }
}

function saveStore() {
  fs.writeFileSync(STORE_FILE, encrypt(JSON.stringify(store)), { mode: 0o600 });
}

loadStore();

/* ---------------- 工具 ---------------- */

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
  '.map': 'application/json; charset=utf-8'
};

function sendJson(res, code, obj, extraHeaders) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, Object.assign({
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store'
  }, extraHeaders || {}));
  res.end(body);
}

function readBody(req, limitBytes) {
  return new Promise((resolve, reject) => {
    const max = limitBytes || 64 * 1024 * 1024;
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > max) { reject(new Error('请求体过大')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

/**
 * 这个地址值得转发吗？
 *
 * 桌面版本质上是个代理：前端给它什么 URL 它就发什么。恶意页面如果能
 * 调用本地服务，就能拿它去打内网。所以这里挡掉环回地址与私有网段。
 * 注意只挡明文写死的 IP —— 域名解析到内网的情况需要额外 DNS 查询，
 * 这里不做（本地服务，威胁模型以「浏览器里被注入的脚本」为主）。
 */
function hostBlocked(urlStr) {
  try {
    const u = new URL(urlStr);
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return true;
    const h = u.hostname.toLowerCase().replace(/^\[|\]$/g, '');
    if (!h) return true;
    if (h === 'localhost' || h.endsWith('.localhost') || h === '::1') return true;
    if (/^127\./.test(h)) return true;
    if (/^10\./.test(h)) return true;
    if (/^192\.168\./.test(h)) return true;
    if (/^169\.254\./.test(h)) return true;
    if (/^172\.(1[6-9]|2\d|3[01])\./.test(h)) return true;
    if (/^0\./.test(h)) return true;
    return false;
  } catch (e) {
    return true;
  }
}

/** 挑出值得透传的请求头，去掉会干扰转发的那几个 */
function outHeaders(h) {
  const out = {};
  const skip = new Set(['host', 'connection', 'content-length', 'accept-encoding']);
  for (const k of Object.keys(h || {})) {
    if (skip.has(String(k).toLowerCase())) continue;
    const v = h[k];
    if (v === undefined || v === null || v === '') continue;
    out[k] = String(v);
  }
  if (!Object.keys(out).some((k) => k.toLowerCase() === 'user-agent')) {
    out['User-Agent'] = 'githup-desktop/1.0';
  }
  return out;
}

function headersToObject(res) {
  const o = {};
  res.headers.forEach((v, k) => { o[String(k).toLowerCase()] = v; });
  return o;
}

/** 统一的出口请求：自动跟随重定向，逐跳复检目标地址 */
async function proxyFetch(method, url, bodyBuf, headers, maxRedirect) {
  let current = url;
  let methodNow = method;
  for (let i = 0; i <= (maxRedirect || 5); i++) {
    if (hostBlocked(current)) throw new Error('目标地址不允许：' + current);
    const res = await fetch(current, {
      method: methodNow,
      headers: outHeaders(headers),
      body: (methodNow === 'GET' || methodNow === 'HEAD') ? undefined : bodyBuf,
      redirect: 'manual'
    });
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get('location');
      if (!loc) return res;
      current = new URL(loc, current).toString();
      if (res.status === 303) methodNow = 'GET';
      continue;
    }
    return res;
  }
  throw new Error('重定向次数过多');
}

/* ---------------- 暂存文件（上传用） ---------------- */

const blobs = new Map();   // id -> {name, size, mime, buf}
const dirs = new Map();    // id -> {name, files:[]}
let blobSeq = 1;
let dirSeq = 1;

function putBlob(name, mime, buf) {
  const id = 'b' + (blobSeq++) + '-' + Date.now().toString(36);
  blobs.set(id, { name: name || 'file', size: buf.length, mime: mime || 'application/octet-stream', buf });
  return id;
}

function getBlob(uri) {
  if (!uri) return null;
  const id = String(uri).replace(/^blob:/, '');
  return blobs.get(id) || null;
}

/* ---------------- API ---------------- */

async function handleApi(req, res, urlPath) {
  /* --- 启动数据：令牌 + 设置 + TOTP 账户，一次给前端 --- */
  if (urlPath === '/api/bootstrap') {
    return sendJson(res, 200, {
      ok: true,
      token: store.token || '',
      prefs: store.prefs || {},
      totp: store.totp || '',
      version: APP_VER + '-desktop',
      platform: process.platform
    });
  }

  if (urlPath === '/api/prefs' && req.method === 'GET') {
    return sendJson(res, 200, { ok: true, prefs: store.prefs || {} });
  }

  if (urlPath === '/api/prefs' && req.method === 'POST') {
    const o = JSON.parse((await readBody(req)).toString('utf8') || '{}');
    if (o.key === 'gh_totp_accounts' || o.key === 'totp_accounts') {
      store.totp = String(o.value || '');
    } else if (o.key === '__token__') {
      store.token = String(o.value || '');
    } else {
      store.prefs[o.key] = o.value;
    }
    saveStore();
    return sendJson(res, 200, { ok: true });
  }

  /* --- 文本请求（GitHub API 主力通道） --- */
  if (urlPath === '/api/http' && req.method === 'POST') {
    const o = JSON.parse((await readBody(req)).toString('utf8') || '{}');
    try {
      const r = await proxyFetch(String(o.method || 'GET').toUpperCase(), String(o.url),
        o.body ? Buffer.from(String(o.body), 'utf8') : undefined, o.headers || {});
      const text = await r.text();
      return sendJson(res, 200, { ok: true, code: r.status, body: text, headers: headersToObject(r) });
    } catch (e) {
      return sendJson(res, 200, { ok: false, code: 0, body: '', headers: { error: String(e.message || e) } });
    }
  }

  /* --- 二进制请求，按 base64 返回（README 图片等） --- */
  if (urlPath === '/api/b64' && req.method === 'POST') {
    const o = JSON.parse((await readBody(req)).toString('utf8') || '{}');
    try {
      const r = await proxyFetch('GET', String(o.url), undefined, o.headers || {});
      const buf = Buffer.from(await r.arrayBuffer());
      return sendJson(res, 200, { ok: true, code: r.status, body: buf.toString('base64'), headers: headersToObject(r) });
    } catch (e) {
      return sendJson(res, 200, { ok: false, code: 0, body: '', headers: { error: String(e.message || e) } });
    }
  }

  /* --- 暂存待上传的文件 --- */
  if (urlPath === '/api/blob' && req.method === 'POST') {
    const o = JSON.parse((await readBody(req)).toString('utf8') || '{}');
    const buf = Buffer.from(String(o.b64 || ''), 'base64');
    const id = putBlob(o.name, o.mime, buf);
    return sendJson(res, 200, { ok: true, uri: 'blob:' + id, name: o.name, size: buf.length, mime: o.mime });
  }

  if (urlPath.indexOf('/api/blob/') === 0 && req.method === 'GET') {
    const b = getBlob(decodeURIComponent(urlPath.slice('/api/blob/'.length)));
    if (!b) return sendJson(res, 404, { ok: false, error: '文件不存在' });
    return sendJson(res, 200, { ok: true, name: b.name, mime: b.mime, size: b.size, b64: b.buf.toString('base64') });
  }

  /* --- 上传
   *
   * 三种装帧方式，都由前端决定（它才知道 GitHub 那一端要什么）：
   *   raw       整个请求体就是文件本身（Release 附件 / Contents API 的二进制）
   *   multipart 前后两段文本由前端拼好（含 boundary），文件内容夹在中间
   *   b64       前后两段文本 + 文件的 Base64（仓库文件上传走这条）
   */
  if (urlPath === '/api/upload' && req.method === 'POST') {
    const o = JSON.parse((await readBody(req)).toString('utf8') || '{}');
    const b = getBlob(o.uri);
    if (!b) return sendJson(res, 200, { ok: false, code: 0, body: '', headers: { error: '找不到待上传文件' } });
    const mode = String(o.mode || 'raw');
    let bodyBuf;
    if (mode === 'raw') {
      bodyBuf = b.buf;
    } else if (mode === 'multipart') {
      bodyBuf = Buffer.concat([
        Buffer.from(String(o.head || ''), 'utf8'), b.buf, Buffer.from(String(o.tail || ''), 'utf8')
      ]);
    } else {
      bodyBuf = Buffer.concat([
        Buffer.from(String(o.head || ''), 'utf8'),
        Buffer.from(b.buf.toString('base64'), 'utf8'),
        Buffer.from(String(o.tail || ''), 'utf8')
      ]);
    }
    try {
      const r = await proxyFetch(String(o.method || 'PUT').toUpperCase(), String(o.url), bodyBuf, o.headers || {});
      const text = await r.text();
      return sendJson(res, 200, { ok: true, code: r.status, body: text, headers: headersToObject(r) });
    } catch (e) {
      return sendJson(res, 200, { ok: false, code: 0, body: '', headers: { error: String(e.message || e) } });
    }
  }

  /* --- 目录：拖文件夹上传时，先在这里登记整棵树 --- */
  if (urlPath === '/api/dir' && req.method === 'POST') {
    const o = JSON.parse((await readBody(req)).toString('utf8') || '{}');
    const id = 'd' + (dirSeq++) + '-' + Date.now().toString(36);
    dirs.set(id, { name: String(o.name || 'folder'), files: o.files || [] });
    return sendJson(res, 200, { ok: true, uri: 'dir:' + id, name: o.name, count: (o.files || []).length });
  }

  if (urlPath.indexOf('/api/dir/') === 0 && req.method === 'GET') {
    const d = dirs.get(decodeURIComponent(urlPath.slice('/api/dir/'.length)).replace(/^dir:/, ''));
    if (!d) return sendJson(res, 404, { ok: false, error: '目录已失效' });
    return sendJson(res, 200, { ok: true, name: d.name, files: d.files });
  }

  /* --- 清空暂存（设置里的「清除缓存」） --- */
  if (urlPath === '/api/clear-cache' && req.method === 'POST') {
    blobs.clear();
    dirs.clear();
    return sendJson(res, 200, { ok: true });
  }

  /* --- 下载：代理到 downloads/ 目录 --- */
  if (urlPath === '/api/download' && req.method === 'POST') {
    const o = JSON.parse((await readBody(req)).toString('utf8') || '{}');
    try {
      const r = await proxyFetch('GET', String(o.url), undefined, o.headers || {});
      if (!r.ok) {
        const t = await r.text();
        return sendJson(res, 200, { ok: false, error: '下载失败（HTTP ' + r.status + '）', detail: t.slice(0, 500) });
      }
      const buf = Buffer.from(await r.arrayBuffer());
      const name = safeName(o.filename || guessName(o.url));
      const sub = o.category ? safeName(o.category) : '';
      const dir = sub ? path.join(DOWNLOADS, sub) : DOWNLOADS;
      await fsp.mkdir(dir, { recursive: true });
      const file = path.join(dir, name);
      await fsp.writeFile(file, buf);
      return sendJson(res, 200, { ok: true, path: file, size: buf.length, name: name });
    } catch (e) {
      return sendJson(res, 200, { ok: false, error: String(e.message || e) });
    }
  }

  /* --- keystore 生成（云端打包 APK 用） ---
   *
   * 首选纯 Node 实现：不依赖任何外部程序，所以 Windows 上也能出 keystore
   * （Windows 没有 openssl，只有这一条路走得通）。
   * 万一 Node 侧出了岔子，再退回 openssl —— 那条路在 Linux / macOS 上可用。
   */
  if (urlPath === '/api/keystore' && req.method === 'POST') {
    const o = JSON.parse((await readBody(req)).toString('utf8') || '{}');
    const alias = String(o.alias || 'githup');
    const pass = String(o.pass || '');
    const seed = String(o.seed || '');
    if (!pass) return sendJson(res, 200, { ok: false, error: '缺少口令' });
    try {
      const p12 = buildPkcs12(alias, pass);
      return sendJson(res, 200, { ok: true, b64: p12.toString('base64'), engine: 'node' });
    } catch (eNode) {
      /* 落到下面的 openssl 分支 */
    }
    const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'githup-ks-'));
    const p12 = path.join(tmp, 'out.p12');
    const args = ['req', '-x509', '-newkey', 'rsa:2048', '-keyout', path.join(tmp, 'k.pem'),
      '-out', path.join(tmp, 'c.pem'), '-days', '10950', '-nodes',
      '-subj', '/CN=' + (alias || 'githup') + '/O=githup/C=CN',
      '-addext', 'subjectAltName=DNS:githup.local'];
    // 用 seed 做确定性随机源：同一个 seed 一定得到同一把钥匙
    const randFile = path.join(tmp, 'rand.bin');
    fs.writeFileSync(randFile, crypto.createHash('sha512').update(seed || alias).digest());
    args.push('-rand', randFile);
    try {
      await run('openssl', args);
      await run('openssl', ['pkcs12', '-export', '-out', p12,
        '-inkey', path.join(tmp, 'k.pem'), '-in', path.join(tmp, 'c.pem'),
        '-name', alias, '-passout', 'pass:' + pass, '-legacy']);
      const b64 = (await fsp.readFile(p12)).toString('base64');
      await fsp.rm(tmp, { recursive: true, force: true });
      return sendJson(res, 200, { ok: true, b64: b64 });
    } catch (e) {
      try {
        // 新版 OpenSSL 3 默认不带 -legacy，去掉再试一次
        await run('openssl', ['pkcs12', '-export', '-out', p12,
          '-inkey', path.join(tmp, 'k.pem'), '-in', path.join(tmp, 'c.pem'),
          '-name', alias, '-passout', 'pass:' + pass]);
        const b64 = (await fsp.readFile(p12)).toString('base64');
        await fsp.rm(tmp, { recursive: true, force: true });
        return sendJson(res, 200, { ok: true, b64: b64 });
      } catch (e2) {
        await fsp.rm(tmp, { recursive: true, force: true });
        return sendJson(res, 200, { ok: false, error: '生成本地 keystore 失败：' + String(e2.message || e2) });
      }
    }
  }

  /* --- 日志：前端出错 / 关键操作 --- */
  if (urlPath === '/api/log' && req.method === 'POST') {
    const o = JSON.parse((await readBody(req)).toString('utf8') || '{}');
    const line = '[' + new Date().toISOString() + '] ' + String(o.kind || 'note') +
      ' | ' + String(o.what || '') + (o.why ? ' | ' + String(o.why) : '');
    try {
      await fsp.appendFile(path.join(LOGS, 'desktop.log'), line + '\n', 'utf8');
    } catch (e) { /* 日志写不进去也不该影响使用 */ }
    return sendJson(res, 200, { ok: true });
  }

  if (urlPath === '/api/log' && req.method === 'GET') {
    try {
      const txt = await fsp.readFile(path.join(LOGS, 'desktop.log'), 'utf8');
      return sendJson(res, 200, { ok: true, text: txt });
    } catch (e) {
      return sendJson(res, 200, { ok: true, text: '' });
    }
  }

  /* --- 打开下载目录（本机文件管理器） --- */
  if (urlPath === '/api/open-downloads' && req.method === 'POST') {
    const p = DOWNLOADS;
    const cmd = process.platform === 'win32' ? ['explorer', p]
      : process.platform === 'darwin' ? ['open', p] : ['xdg-open', p];
    execFile(cmd[0], cmd.slice(1), () => { });
    return sendJson(res, 200, { ok: true, path: p });
  }

  /* --- 退出服务 --- */
  if (urlPath === '/api/quit' && req.method === 'POST') {
    sendJson(res, 200, { ok: true });
    setTimeout(() => process.exit(0), 120);
    return;
  }

  return sendJson(res, 404, { ok: false, error: 'unknown api' });
}

function run(cmd, args) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) reject(new Error(stderr ? String(stderr).slice(0, 300) : err.message));
      else resolve(stdout);
    });
  });
}

function safeName(n) {
  let s = String(n || 'download').replace(/[\/\\:*?"<>|]/g, '_').trim();
  if (!s || s === '.' || s === '..') s = 'download';
  return s.slice(0, 120);
}

function guessName(url) {
  try {
    const p = new URL(url).pathname;
    const seg = p.split('/').filter(Boolean).pop();
    return seg ? decodeURIComponent(seg) : 'download';
  } catch (e) {
    return 'download';
  }
}

/* ---------------- 静态文件 ---------------- */

/**
 * 注入给前端的三样东西：启动数据、桌面样式、桌面桥。
 *
 * 用服务端注入而不是改 index.html，是为了让 web/ 里的文件与 Android 版
 * 保持逐字节一致 —— 上游一更新，整个目录覆盖过来就能用。
 *
 * 启动数据（令牌 / 设置 / TOTP 账户）直接内联：一来省掉一次同步请求，
 * 二来页面脚本一上来就能同步读到令牌（getToken 是同步接口）。
 * 这些内容只在回环地址上传输，不出本机。
 */
function desktopHead() {
  const boot = JSON.stringify({
    token: store.token || '',
    prefs: store.prefs || {},
    totp: store.totp || '',
    version: APP_VER + '-desktop',
    platform: process.platform,
    desktop: true
  }).replace(/</g, '\\u003c');
  return '  <script>window.__GH_BOOTSTRAP__=' + boot + ';</script>\n' +
    '  <link rel="stylesheet" href="css/desktop.css">\n' +
    '  <script src="js/desktop-bridge.js"></script>\n';
}

function serveStatic(req, res, urlPath) {
  let rel = decodeURIComponent(urlPath.split('?')[0]);
  if (rel === '/' || rel === '') rel = '/index.html';
  const clean = path.normalize(rel).replace(/^([/\\])+/, '').replace(/\\/g, '/');
  // 目录穿越防护
  if (clean.split('/').indexOf('..') >= 0) {
    res.writeHead(403); res.end('forbidden'); return;
  }

  /* 打包成 exe 后，前端文件在内存里 —— 直接发出去，不落磁盘 */
  const mem = embedded(clean);
  if (mem) {
    const ext = path.extname(clean).toLowerCase();
    const type = MIME[ext] || 'application/octet-stream';
    let body = mem;
    if (ext === '.html') body = Buffer.from(String(mem).replace('</head>', desktopHead() + '</head>'), 'utf8');
    res.writeHead(200, {
      'Content-Type': type,
      'Content-Length': body.length,
      'Cache-Control': 'no-cache'
    });
    res.end(body);
    return;
  }

  const file = path.join(WEB, clean);
  // 目录穿越防护：解析后必须仍在 WEB 之内
  if (!file.startsWith(WEB)) {
    res.writeHead(403); res.end('forbidden'); return;
  }
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('404 ' + rel);
      return;
    }
    const ext = path.extname(file).toLowerCase();
    const type = MIME[ext] || 'application/octet-stream';
    const headers = {
      'Content-Type': type,
      'Content-Length': st.size,
      'Cache-Control': 'no-cache'
    };
    if (ext === '.html') {
      // 桌面脚本与样式由服务端注入，前端文件保持与 Android 版逐字节一致
      fs.readFile(file, 'utf8', (e2, html) => {
        if (e2) { res.writeHead(500); res.end('read error'); return; }
        const out = html.replace('</head>', desktopHead() + '</head>');
        const buf = Buffer.from(out, 'utf8');
        headers['Content-Length'] = buf.length;
        res.writeHead(200, headers);
        res.end(buf);
      });
      return;
    }
    res.writeHead(200, headers);
    fs.createReadStream(file).pipe(res);
  });
}

/* ---------------- 主流程 ---------------- */

const server = http.createServer((req, res) => {
  const urlPath = req.url.split('?')[0];
  const origin = req.headers.origin || '';
  // 只接受同源（本机页面）或没有 Origin 的普通导航请求
  if (origin && !/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(origin)) {
    res.writeHead(403); res.end('forbidden origin'); return;
  }
  if (urlPath.indexOf('/api/') === 0) {
    handleApi(req, res, urlPath).catch((e) => {
      sendJson(res, 200, { ok: false, error: String(e.message || e) });
    });
    return;
  }
  serveStatic(req, res, urlPath);
});

const PORT = Number(process.env.GITHUP_PORT || process.argv[2] || 8733);
const HOST = '127.0.0.1';

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.log('端口 ' + PORT + ' 被占用，换一个：' + (PORT + 1));
    server.listen(PORT + 1, HOST);
  } else {
    console.error(e);
    process.exit(1);
  }
});

/**
 * 控制台只输出 ASCII。
 *
 * Windows 控制台默认代码页是 936（GBK），Node 按 UTF-8 写出来的中文会
 * 变成乱码 —— 与其让用户看一堆问号，不如这里只写英文和数字。中文说明
 * 全部放在网页里（浏览器是 UTF-8，显示正常）。
 */
server.listen(PORT, HOST, () => {
  const actual = server.address().port;
  const url = 'http://' + HOST + ':' + actual + '/';
  console.log('');
  console.log('  githup desktop  (v' + APP_VER + ')');
  console.log('  ----------------------------------------');
  console.log('  running : ' + url);
  console.log('  data    : ' + DATA);
  console.log('  downloads: ' + DOWNLOADS);
  console.log('');
  console.log('  The browser should open automatically.');
  console.log('  If not, visit the address above.');
  console.log('  Press Ctrl+C here to stop.');
  console.log('');
  if (process.env.GITHUP_NO_OPEN !== '1') {
    openBrowser(url);
  }
});

function openBrowser(url) {
  try {
    if (process.platform === 'win32') {
      // 用 start 交给系统默认浏览器，且不弹出多余的 cmd 窗口
      execFile('cmd', ['/c', 'start', '', url], { windowsHide: true }, () => { });
    } else if (process.platform === 'darwin') {
      execFile('open', [url], () => { });
    } else {
      execFile('xdg-open', [url], () => { });
    }
  } catch (e) { /* 打不开也无妨，看窗口里的地址手动访问即可 */ }
}

/* 打包成 exe 时，别让窗口一闪而过：按 Ctrl+C 才退出 */
if (SEA) {
  process.on('SIGINT', () => {
    console.log('\n  stopped.');
    process.exit(0);
  });
}

void zlib;

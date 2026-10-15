/* ============================================================
 * desktop-bridge.js —— 桌面版的「原生层」
 *
 * Android 版里，前端通过 window.NativeBridge 调用 java 层的 60 多个方法
 * （网络、文件、上传、下载、存储、TOTP、日志……）。桌面版没有 java，
 * 这里就在浏览器里把同一套接口实现一遍：
 *
 *   · 名字、参数、回调方式全部对齐 Android 版，前端代码一行不用改；
 *   · 能做的照做（网络走本地代理，存储走本地加密文件，文件选择用
 *     浏览器的 <input type=file>，相机用 getUserMedia）；
 *   · 做不到的（安装 APK、通知栏常驻、后台轮询）老实降级，不假装支持。
 *
 * 回调通道沿用前端那套：window.Native._cb / _pick / _read / _list /
 * _ks / _camera，与 Android 版 JsBridge 回调的字面量完全一致。
 * ============================================================ */
(function () {
  'use strict';

  var BOOT = window.__GH_BOOTSTRAP__ || {};
  var VERSION = BOOT.version || '1.2.15-desktop';

  /* 服务器在返回页面时已经把持久化的数据内联进来，页面脚本一上来就能
     同步读到 —— getToken / getPref 都是同步接口，等不得异步往返。 */
  var prefsCache = BOOT.prefs || {};
  var tokenCache = BOOT.token || '';

  /* 哪些键不许落到 localStorage。
     前端的 Store.set 是「原生 + localStorage」双写（Android 版的历史设计），
     两步验证的根密钥一旦抄进 localStorage 就是明文落地，这里拦掉。 */
  var SENSITIVE = /totp|secret|token|otp/i;

  var seq = 1;

  function api(path, obj) {
    return fetch('/api/' + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(obj || {})
    }).then(function (r) { return r.json(); })
      .catch(function (e) { return { ok: false, error: String(e && e.message || e) }; });
  }

  function apiGet(path) {
    return fetch('/api/' + path, { method: 'GET' })
      .then(function (r) { return r.json(); })
      .catch(function (e) { return { ok: false, error: String(e && e.message || e) }; });
  }

  /* ---------------- 回前端的通道 ---------------- */

  function N() { return window.Native; }

  function cb(id, code, body, headers) {
    var n = N();
    if (n && n._cb) n._cb(id, code, body == null ? '' : body, JSON.stringify(headers || {}));
  }

  function cbErr(id, msg) {
    cb(id, 0, '', { error: String(msg || '失败') });
  }

  function pick(id, meta, err) {
    var n = N();
    if (n && n._pick) n._pick(id, meta, err);
  }

  function readCb(id, b64, err) {
    var n = N();
    if (n && n._read) n._read(id, b64, err);
  }

  function listCb(id, files, err) {
    var n = N();
    if (n && n._list) n._list(id, files, err);
  }

  function ksCb(id, b64, err) {
    var n = N();
    if (n && n._ks) n._ks(id, b64, err);
  }

  function camCb(id, granted) {
    var n = N();
    if (n && n._camera) n._camera(id, !!granted);
  }

  /* ---------------- 桌面味儿的提示条 ---------------- */

  var toastTimer = null;
  function toast(msg) {
    var el = document.getElementById('desktop-toast');
    if (!el) {
      el = document.createElement('div');
      el.id = 'desktop-toast';
      document.body.appendChild(el);
    }
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove('show'); }, 2600);
  }

  /* ---------------- 网络 ---------------- */

  function stripLocal(h) {
    var out = {};
    for (var k in h) {
      if (!Object.prototype.hasOwnProperty.call(h, k)) continue;
      // X-Hub-Reuse 是 Android 版连接池的内部标记，桌面不走那套，别外发
      if (/^x-hub-/i.test(k)) continue;
      out[k] = h[k];
    }
    return out;
  }

  function parseHeaders(s) {
    if (!s) return {};
    if (typeof s === 'object') return s;
    try { return JSON.parse(s); } catch (e) { return {}; }
  }

  function doHttp(id, method, url, body, headersJson, binary) {
    api(binary ? 'b64' : 'http', {
      method: method, url: url, body: body || null,
      headers: stripLocal(parseHeaders(headersJson))
    }).then(function (r) {
      if (!r.ok) return cbErr(id, r.error || '请求失败');
      cb(id, r.code, r.body, r.headers);
    });
  }

  /* ---------------- 文件选择 ---------------- */

  function readAsB64(file) {
    return new Promise(function (resolve, reject) {
      var fr = new FileReader();
      fr.onload = function () {
        var s = String(fr.result || '');
        resolve(s.slice(s.indexOf(',') + 1));   // 去掉 data:...;base64, 前缀
      };
      fr.onerror = function () { reject(new Error('读取失败')); };
      fr.readAsDataURL(file);
    });
  }

  function openPicker(accept, multiple, directory) {
    return new Promise(function (resolve) {
      var input = document.createElement('input');
      input.type = 'file';
      input.style.display = 'none';
      if (accept && accept !== '*/*') input.accept = accept;
      if (multiple) input.multiple = true;
      if (directory) {
        input.webkitdirectory = true;
        input.directory = true;
      }
      var done = false;
      input.addEventListener('change', function () {
        if (done) return;
        done = true;
        resolve(Array.prototype.slice.call(input.files || []));
        if (input.parentNode) input.parentNode.removeChild(input);
      });
      document.body.appendChild(input);
      input.click();
    });
  }

  /** 把选中的文件暂存到服务端，换回一个 uri */
  function stage(file, relPath) {
    return readAsB64(file).then(function (b64) {
      return api('blob', { name: relPath || file.name, mime: file.type || 'application/octet-stream', b64: b64 });
    }).then(function (r) {
      if (!r.ok) throw new Error(r.error || '暂存失败');
      return { name: r.name, size: r.size, mime: r.mime, uri: r.uri };
    });
  }

  /* ---------------- 主接口 ---------------- */

  var Bridge = {

    /* ===== 网络 ===== */
    http: function (id, method, url, body, headersJson) {
      doHttp(id, method, url, body, headersJson, false);
    },
    httpB64: function (id, url, headersJson) {
      doHttp(id, 'GET', url, null, headersJson, true);
    },
    /** 桌面版没有 WebView 拦截通道，图片统一走 base64 */
    imageProxyReady: function () { return false; },
    prefetchImages: function (urlsJson) {
      var arr;
      try { arr = JSON.parse(urlsJson || '[]'); } catch (e) { return; }
      (arr || []).slice(0, 12).forEach(function (u) {
        var img = new Image();
        img.decoding = 'async';
        img.src = u;
      });
    },

    /* ===== 存储 ===== */
    getPref: function (key) {
      var v = prefsCache[key];
      return v == null ? null : v;
    },
    setPref: function (key, value) {
      prefsCache[key] = value;
      api('prefs', { key: key, value: value });
    },
    getToken: function () { return tokenCache || ''; },
    setToken: function (t) {
      tokenCache = t || '';
      api('prefs', { key: '__token__', value: tokenCache });
    },

    /* ===== 文件选择 ===== */
    canPick: function () { return true; },
    pickFile: function (id, accept) {
      openPicker(accept, true, false).then(function (files) {
        if (!files.length) return pick(id, [], null);
        return Promise.all(files.map(function (f) { return stage(f); }))
          .then(function (metas) { pick(id, metas, null); })
          .catch(function (e) { pick(id, null, String(e.message || e)); });
      });
    },
    pickFolder: function (id) {
      openPicker(null, false, true).then(function (files) {
        if (!files.length) return pick(id, null, null);
        var root = '';
        var list = [];
        var chain = Promise.resolve();
        files.forEach(function (f) {
          var rel = (f.webkitRelativePath || f.name);
          if (!root) root = rel.split('/')[0];
          chain = chain.then(function () {
            return stage(f, rel).then(function (m) {
              list.push({ name: f.name, path: rel, size: m.size, mime: m.mime, uri: m.uri });
            });
          });
        });
        return chain.then(function () {
          return api('dir', { name: root || 'folder', files: list });
        }).then(function (r) {
          if (!r.ok) throw new Error(r.error || '目录登记失败');
          pick(id, { folder: true, name: r.name, uri: r.uri, count: r.count }, null);
        }).catch(function (e) { pick(id, null, String(e.message || e)); });
      });
    },
    listFolder: function (id, treeUri) {
      var key = String(treeUri || '').replace(/^dir:/, '');
      apiGet('dir/' + encodeURIComponent(key)).then(function (r) {
        if (!r.ok) return listCb(id, [], String(r.error || '读不到目录'));
        listCb(id, r.files || [], null);
      });
    },
    readFileBase64: function (id, uriStr, maxBytes) {
      var key = String(uriStr || '').replace(/^blob:/, '');
      apiGet('blob/' + encodeURIComponent(key)).then(function (r) {
        if (!r.ok) return readCb(id, null, String(r.error || '读不到文件'));
        if (maxBytes && r.size > maxBytes) {
          return readCb(id, null, '文件超过 ' + Math.round(maxBytes / 1048576) + 'MB，太大了');
        }
        readCb(id, r.b64, null);
      });
    },

    /* ===== 上传 ===== */
    uploadBinary: function (id, url, uriStr, headersJson) {
      Bridge._up(id, url, uriStr, headersJson, 'raw', null, null, 'PUT');
    },
    uploadRaw: function (id, url, uriStr, headersJson) {
      Bridge._up(id, url, uriStr, headersJson, 'raw', null, null, 'PUT');
    },
    uploadMultipart: function (id, url, uriStr, headersJson, head, tail) {
      Bridge._up(id, url, uriStr, headersJson, 'multipart', head, tail, 'POST');
    },
    uploadMultipartB64: function (id, url, uriStr, headersJson, head, tail) {
      Bridge._up(id, url, uriStr, headersJson, 'b64', head, tail, 'PUT');
    },
    _up: function (id, url, uriStr, headersJson, mode, head, tail, method) {
      api('upload', {
        url: url, uri: uriStr, mode: mode, head: head, tail: tail,
        method: method, headers: stripLocal(parseHeaders(headersJson))
      }).then(function (r) {
        if (!r.ok) return cbErr(id, r.error || '上传失败');
        cb(id, r.code, r.body, r.headers);
      });
    },

    /** 云端打包 APK 用的 keystore：交给本机 openssl 生成 */
    makeKeystore: function (id, seed, alias, storePass, keyPass) {
      api('keystore', { seed: seed, alias: alias, pass: storePass || keyPass }).then(function (r) {
        if (!r.ok) return ksCb(id, null, r.error || '生成失败');
        ksCb(id, r.b64, null);
      });
    },

    /* ===== 下载 ===== */
    download: function (url, filename) {
      Bridge.downloadWithHeaders(url, filename, '{}');
    },
    downloadWithHeaders: function (url, filename, headersJson, category) {
      api('download', {
        url: url, filename: filename,
        headers: stripLocal(parseHeaders(headersJson)),
        category: category || ''
      }).then(function (r) {
        if (!r.ok) return toast('下载失败：' + (r.error || '未知原因'));
        toast('已保存到 ' + r.path);
      });
    },
    /** 装 APK 是 Android 才有的事；桌面版只负责把包取回来 */
    installApk: function (url, filename, headersJson, category) {
      Bridge.downloadWithHeaders(url, filename, headersJson, category);
    },
    installApkChecked: function (url, filename, headersJson, expectedSha) {
      api('download', {
        url: url, filename: filename,
        headers: stripLocal(parseHeaders(headersJson)), category: 'apk'
      }).then(function (r) {
        if (!r.ok) return toast('下载失败：' + (r.error || '未知原因'));
        toast('桌面版装不了 APK，已保存到：' + r.path);
      });
    },
    saveImage: function (url) {
      api('download', { url: url, filename: '', headers: {}, category: 'images' })
        .then(function (r) {
          toast(r.ok ? '图片已保存到 downloads/images' : '保存失败：' + (r.error || ''));
        });
    },

    /* ===== 系统 ===== */
    appVersion: function () { return VERSION; },
    version: function () { return VERSION; },
    certSha256: function () { return ''; },
    apkSha256: function () { return ''; },
    openExternal: function (url) { window.open(url, '_blank', 'noopener'); },
    openInApp: function (url) { window.open(url, '_blank', 'noopener'); },
    share: function (url, title) {
      Bridge.copy(url || '');
      toast('链接已复制');
    },
    copy: function (text) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(String(text || '')).catch(function () { });
      }
    },
    /** 剪贴板只能异步读，而这个接口是同步的 —— 读不到就给空串 */
    getClipboard: function () { return ''; },
    systemDark: function () {
      return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
    },
    safeInsets: function () { return '{"top":0,"bottom":0,"left":0,"right":0}'; },
    setStatusBar: function () { },
    haptic: function () { },
    dismissSlowAdvice: function () { },
    clearCache: function () {
      api('clear-cache', {}).then(function () { toast('已清理暂存文件'); });
    },
    exit: function () {
      api('quit', {});
      setTimeout(function () { window.close(); }, 300);
    },

    /* 相机：浏览器自己会弹权限框，这里直接放行 */
    requestCamera: function (id) {
      if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
        navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } })
          .then(function (s) {
            s.getTracks().forEach(function (t) { t.stop(); });
            camCb(id, true);
          })
          .catch(function () { camCb(id, false); });
      } else {
        camCb(id, false);
      }
    },

    randomHex: function (n) {
      var b = new Uint8Array(Math.max(1, n | 0));
      (window.crypto || window.msCrypto).getRandomValues(b);
      var s = '';
      for (var i = 0; i < b.length; i++) s += ('0' + b[i].toString(16)).slice(-2);
      return s;
    },
    /* HMAC 不实现：前端 totp.js 自带纯 JS 兜底，缺方法时会自动走它 */

    /* ===== TOTP ===== */
    totpSync: function (accountsJson) {
      api('prefs', { key: 'totp_accounts', value: String(accountsJson || '') });
    },
    totpSetBackground: function () { },
    totpBackgroundEnabled: function () { return false; },
    isAppForeground: function () { return true; },

    /* ===== 通知（桌面版没有后台轮询，老实说没有） ===== */
    notifWatchEnabled: function () { return false; },
    setNotifWatch: function () { },
    checkNotificationsNow: function () { },
    notifWatchLastCheck: function () { return 0; },

    /* ===== 下载通道（桌面只有一条直连，不给假数据） ===== */
    getChannel: function () { return 'direct'; },
    setChannel: function () { },
    startChannelProbe: function () { },
    stopChannelProbe: function () { },
    channelProbe: function () { return '[]'; },
    downloadStatus: function () { return '[]'; },
    downloadHistory: function () { return '[]'; },
    downloadHistoryNow: function () { return '[]'; },
    downloadHistoryDiag: function () { return '{}'; },
    downloadAction: function () { },

    /* ===== 日志 ===== */
    logError: function (what, why) { api('log', { kind: 'error', what: what, why: why }); },
    logNote: function (what) { api('log', { kind: 'note', what: what }); },
    saveLog: function (cbId) {
      apiGet('log').then(function (r) {
        var text = (r && r.text) || '';
        var m = window.Native && window.Native._logSaved;
        if (m && typeof m[cbId] === 'function') m[cbId](text);
        toast(text ? '日志已保存' : '还没有日志');
      });
    },
    shareLog: function () { Bridge.exportLog(); },
    exportLog: function () {
      apiGet('log').then(function (r) {
        var text = (r && r.text) || '';
        var blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
        var a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'githup-desktop.log';
        document.body.appendChild(a);
        a.click();
        setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
      });
    }
  };

  window.NativeBridge = Bridge;

  /* ============================================================
   * 接管 window.Store
   *
   * Android 版的 Store 是「原生 prefs + localStorage」双写。桌面上
   * localStorage 是明文，两步验证的根密钥不能往里落。这里把 set/setJSON
   * 换成只写服务端（服务端加密存盘）的版本，读的那一侧因为 getPref 是
   * 同步的，不用动。
   * ============================================================ */
  var storeRef;
  Object.defineProperty(window, 'Store', {
    configurable: true,
    get: function () { return storeRef; },
    set: function (v) {
      storeRef = v;
      if (!v || v.__desktopPatched) return;
      try {
        v.__desktopPatched = true;
        v.set = function (k, val) {
          var s = v.load();
          s[k] = val;
          var raw = JSON.stringify(s);
          if (!SENSITIVE.test(String(k))) {
            try { localStorage.setItem('gh_settings', raw); } catch (e) { }
          }
          api('prefs', { key: 'gh_settings', value: raw });
          return val;
        };
        v.setJSON = function (k, val) {
          var raw = JSON.stringify(val);
          if (!SENSITIVE.test(String(k))) {
            try { localStorage.setItem(String(k), raw); } catch (e) { }
          }
          api('prefs', { key: String(k), value: raw });
          return val;
        };
      } catch (e) { /* 接管失败也不该让页面挂掉 */ }
    }
  });

  /* ============================================================
   * 桌面增强
   * ============================================================ */

  /** 桌面端侧边栏：复用底栏那几个按钮，靠 CSS 换成左侧竖排 */
  function markDesktop() {
    try {
      document.documentElement.setAttribute('data-desktop', '1');
      document.documentElement.setAttribute('data-platform', BOOT.platform || '');
    } catch (e) { }
  }

  /** 常用快捷键：1-5 切页、Esc 返回、Ctrl+K 搜索 */
  function bindKeys() {
    document.addEventListener('keydown', function (e) {
      var tag = (e.target && e.target.tagName || '').toLowerCase();
      if (tag === 'input' || tag === 'textarea' || (e.target && e.target.isContentEditable)) return;
      var mod = e.ctrlKey || e.metaKey;
      if (mod && (e.key === 'k' || e.key === 'K')) {
        e.preventDefault();
        var tabs = document.querySelectorAll('#tabbar .tab');
        var search = null;
        for (var i = 0; i < tabs.length; i++) {
          if (tabs[i].getAttribute('data-tab') === 'search') search = tabs[i];
        }
        if (search) search.click();
        return;
      }
      if (!mod && e.key === 'Escape') {
        var back = document.getElementById('btn-back');
        if (back && !back.hidden) { e.preventDefault(); back.click(); }
        return;
      }
      if (!mod && /^[1-5]$/.test(e.key)) {
        var list = document.querySelectorAll('#tabbar .tab');
        var idx = parseInt(e.key, 10) - 1;
        if (list[idx]) { e.preventDefault(); list[idx].click(); }
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { markDesktop(); bindKeys(); });
  } else {
    markDesktop(); bindKeys();
  }

  markDesktop();
  void seq;
})();

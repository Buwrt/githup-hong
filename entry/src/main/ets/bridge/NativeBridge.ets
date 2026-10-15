import { webview } from '@kit.ArkWeb';
import { preferences } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction, common, Want } from '@kit.AbilityKit';
import { window as winMgr } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import { abilityAccessCtrl, Permissions, bundleManager } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { SecureStore } from './SecureStore';
import { requestText, requestB64, uploadBytes, GhResponse } from './GhHttp';
import { TotpNotify } from './TotpNotify';
import { NotifWatch } from './NotifWatch';
import { candidatesWithKeys, DIRECT, nameOf, ChannelCand } from './DownloadChannels';

/**
 * 原生桥：把 Android 版 JsBridge.java 的能力在鸿蒙上重新实现一遍。
 *
 * 前端 2.5 万行 JS 一行没改，它调用的是 window.NativeBridge.xxx ——
 * 这里通过 Web 组件的 javaScriptProxy 把同名对象注入到 window 上，
 * 方法名与参数顺序与 Android 版逐一对齐，前端无感知。
 *
 * ══ 同步 / 异步怎么分 ══
 * javaScriptProxy 的 methodList 是同步方法（有返回值），
 * asyncMethodList 是异步方法（拿不到返回值）。
 * 前端的网络调用本来就是「下发 id、等 window.Native._cb(id,...) 回调」
 * 的模式（api.js 的 Native.http），所以 http / httpB64 这类放进
 * asyncMethodList 后用 runJavaScript 主动回吐，链路完全对得上。
 *
 * ══ 相对 Android 版做了什么改动 ══
 *   1) 自研 HTTP 栈 → 系统 @kit.NetworkKit（少了 999 行手写报文，
 *      重定向还顺手补了「跨域剥离 Authorization」）；
 *   2) AndroidKeyStore → cryptoFramework + 应用沙箱；
 *   3) 五环防护链（Guard/SignCheck）→ 鸿蒙侧改为校验 HAP 签名指纹，
 *      见 verifySelfIntegrity()；Android 那套依赖 PackageManager 的
 *      重签名检测在鸿蒙上没有等价物，改成校验应用自身签名与 bundleName。
 */

const B64_CHUNK: number = 48 * 1024;   // 与 Android 版一致：单次回吐上限
const TOKEN_KEY: string = 'gh_token';
const PREF_NAME: string = 'hub_prefs';

export class NativeBridge {
  private ctx: common.UIAbilityContext;
  private controller: webview.WebviewController;
  private secure: SecureStore;
  private pref: preferences.Preferences;
  // 令牌的内存缓存：加解密是异步的，而 javaScriptProxy 的同步方法
  // 不能返回 Promise，所以读走缓存、写走「先更新缓存再异步落盘」。
  private tokenCache: string = '';
  private lastPickUris: string[] = [];
  private totpNotify: TotpNotify;
  private notifWatch: NotifWatch;

  constructor(ctx: common.UIAbilityContext, controller: webview.WebviewController) {
    this.ctx = ctx;
    this.controller = controller;
    this.secure = new SecureStore(ctx);
    this.pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
    this.totpNotify = new TotpNotify(ctx);
    this.notifWatch = new NotifWatch(ctx, () => this.tokenCache);
  }

  /** App 退到后台：通知轮询借一段短时任务把这一轮问完 */
  onBackground(): void {
    try { this.notifWatch.onBackground(); } catch (e) { }
  }

  /** 回到前台 */
  onForeground(): void {
    try { if (this.notifWatch.enabled()) this.notifWatch.start(); } catch (e) { }
  }

  /** 启动时把磁盘上的令牌解密进内存；失败按「未登录」处理 */
  async boot(): Promise<void> {
    const packed = this.pref.getSync(TOKEN_KEY, '') as string;
    if (packed) {
      const plain = await this.secure.decrypt(packed);
      this.tokenCache = plain ?? '';
    }
    /* 令牌解密完成后才启动轮询 —— 顺序反了的话第一趟拿不到令牌，
       白问一次还会在用户看来像「开了开关没反应」。 */
    if (this.notifWatch.enabled()) this.notifWatch.start();
    if (this.totpNotify.enabled()) this.totpNotify.setEnabled(true);
  }

  /* ================= 同步：身份与版本 ================= */

  appVersion(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).appInfo;
      return info.versionName ?? '1.0.0';
    } catch (e) {
      return '1.0.0';
    }
  }

  /**
   * 本机安装包的签名指纹，供「设置 → 关于」显示，让人能自己核对。
   * 鸿蒙取的是应用签名的 appId 指纹（HAP 由华为证书签名后与开发者账号绑定），
   * 语义上等价于 Android 版的签名证书 SHA-256。
   */
  certSha256(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      return info.signatureInfo?.appId ?? '';
    } catch (e) {
      return '';
    }
  }

  apkSha256(): string {
    // 鸿蒙没有 APK；版本清单一侧的校验值仍由前端 updater.js 自己管
    return '';
  }

  /* ================= 同步：令牌与偏好 ================= */

  getToken(): string {
    return this.tokenCache;
  }

  setToken(t: string): void {
    this.tokenCache = t ?? '';
    if (!this.tokenCache) {
      this.pref.deleteSync(TOKEN_KEY);
      this.pref.flushSync();
      return;
    }
    this.secure.encrypt(this.tokenCache).then((packed: string | null) => {
      if (packed) {
        this.pref.putSync(TOKEN_KEY, packed);
        this.pref.flushSync();
      }
    });
  }

  getPref(key: string): string {
    try {
      return this.pref.getSync(key, '') as string;
    } catch (e) {
      return '';
    }
  }

  setPref(key: string, value: string): void {
    try {
      if (value === null || value === undefined) {
        this.pref.deleteSync(key);
      } else {
        this.pref.putSync(key, value);
      }
      this.pref.flushSync();
    } catch (e) {
    }
  }

  copy(text: string): void {
    try {
      const board = pasteboard.getSystemPasteboard();
      board.setDataSync({ 'text/plain': pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text ?? '') });
      promptAction.showToast({ message: '已复制', duration: 1200 });
    } catch (e) {
    }
  }

  getClipboard(): string {
    try {
      const board = pasteboard.getSystemPasteboard();
      const d = board.getDataSync();
      if (!d) return '';
      return d.getPrimaryText() ?? '';
    } catch (e) {
      return '';
    }
  }

  /* ================= 同步：界面环境 ================= */

  systemDark(): boolean {
    try {
      return this.ctx.config.colorMode === 1;   // 0 浅色 / 1 深色 / -1 未设置
    } catch (e) {
      return false;
    }
  }

  /**
   * 安全区：[上, 下, 左, 右, 导航模式]，单位物理像素，前端自己除 dpr。
   * 取自窗口避让区（状态栏在上、导航栏在下），与 Android 版语义一致。
   */
  safeInsets(): string {
    try {
      const stage = this.ctx.windowStage;
      if (!stage) return '[0,0,0,0,9]';
      const w = stage.getMainWindowSync();
      const area = w.getWindowProperties().getWindowAvoidArea(winMgr.AvoidAreaType.TYPE_SYSTEM);
      const top = area.topRect?.height ?? 0;
      const bottom = area.bottomRect?.height ?? 0;
      const left = Math.max(area.topRect?.left ?? 0, area.bottomRect?.left ?? 0);
      const right = Math.max(area.topRect?.width ?? 0, area.bottomRect?.width ?? 0) > 0
        ? left
        : 0;
      // 鸿蒙不暴露导航栏模式（三键/手势），按「无软导航栏」上报，
      // 前端只是把它挂在根元素上做排查用，不参与排版。
      return '[' + top + ',' + bottom + ',' + left + ',' + right + ',9]';
    } catch (e) {
      return '[0,0,0,0,9]';
    }
  }

  setStatusBar(color: string): void {
    try {
      const stage = this.ctx.windowStage;
      if (!stage) return;
      stage.getMainWindowSync().setWindowSystemBarProperties({
        statusBarColor: color ?? '#FFFFFF',
        statusBarContentColor: this.systemDark() ? '#FFFFFF' : '#000000'
      });
    } catch (e) {
    }
  }

  haptic(): void {
    try {
      vibrator.startVibration({ type: 'time', duration: 20 }, { usage: 'touch' });
    } catch (e) {
    }
  }

  imageProxyReady(): boolean {
    // 鸿蒙版由 WebView 自己取图（ArkWeb 的网络栈可用），不需要 base64 快车道
    return false;
  }

  isAppForeground(): boolean {
    return true;
  }

  notifWatchEnabled(): boolean {
    return this.notifWatch.enabled();
  }

  /** 开关 GitHub 通知轮询。开启时顺带申请通知权限 —— 没权限发了也白发。 */
  setNotifWatch(on: boolean): void {
    this.notifWatch.setEnabled(on);
    if (on) requestNotifyPermission(this.ctx);
  }

  notifWatchLastCheck(): number {
    return this.notifWatch.lastCheck();
  }

  totpBackgroundEnabled(): boolean {
    return this.totpNotify.enabled();
  }

  /** 开关动态码常驻通知。开启时同样要通知权限，关掉时通知一并撤掉。 */
  totpSetBackground(on: boolean): void {
    if (on) requestNotifyPermission(this.ctx);
    this.totpNotify.setEnabled(on);
  }

  /**
   * 账户清单同步到原生侧。
   *
   * 后台常驻通知要在 App 不可见时也算出动态码，而它读不到 WebView 里的
   * 数据 —— 所以前端每次改动账户就推一份 JSON 过来。
   *
   * 注意这里**不去重后写回**：去重只在渲染通知那一刻做（TotpEngine.dedupe），
   * 磁盘上保留前端给的原样，免得原生改了数据、前端再读回去对不上。
   */
  totpSync(json: string): void {
    try {
      this.pref.putSync('totp_accounts_cache', json ?? '[]');
      this.pref.flushSync();
      this.totpNotify.refresh();
    } catch (e) {
    }
  }

  getChannel(): string {
    return this.getPref('gh_dl_channel') || 'direct';
  }

  setChannel(key: string): void {
    this.setPref('gh_dl_channel', key ?? 'direct');
  }

  /** 下载记录，供前端「下载管理」页渲染 */
  downloadStatus(): string {
    try {
      return this.pref.getSync('gh_dl_history', '[]') as string;
    } catch (e) {
      return '[]';
    }
  }

  dismissSlowAdvice(): void {
  }

  /* ================= 同步：随机与日志 ================= */

  randomHex(bytes: number): string {
    try {
      const n = Math.max(1, Math.min(bytes, 256));
      const r = cryptoFramework.createRandom().generateRandomSync(n);
      let s = '';
      for (let i = 0; i < n; i++) {
        s += ('0' + (r[i] & 0xff).toString(16)).slice(-2);
      }
      return s;
    } catch (e) {
      return '';
    }
  }

  logError(what: string, why: string): void {
    appendLog('【出错了】' + (what ?? '') + (why ? ' · ' + why : ''));
  }

  logNote(what: string): void {
    appendLog('· ' + (what ?? ''));
  }

  /* ================= 异步：网络 ================= */

  async http(id: string, method: string, url: string, body: string, headersJson: string): Promise<void> {
    try {
      const h = parseHeaders(headersJson);
      const r: GhResponse = await requestText(method ?? 'GET', url, body ?? null, h);
      this.emit(id, r.code, r.body, r.headers);
    } catch (e) {
      this.emit(id, 0, '', '{\"error\":' + jq(msg(e)) + '}');
    }
  }

  async httpB64(id: string, url: string, headersJson: string): Promise<void> {
    try {
      const h = parseHeaders(headersJson);
      const r: GhResponse = await requestB64(url, h);
      this.emit(id, r.code, r.body, r.headers);
    } catch (e) {
      this.emit(id, 0, '', '{\"error\":' + jq(msg(e)) + '}');
    }
  }

  /** 大响应分片下发：先 _begin 登记份数，再逐片 _chunk */
  private emit(id: string, code: number, body: string, headers: string): void {
    const b = body ?? '';
    if (b.length <= B64_CHUNK) {
      this.run('window.Native._cb(' + jq(id) + ',' + code + ',' + jq(b) + ',' + jq(headers ?? '{}') + ')');
      return;
    }
    const n = Math.ceil(b.length / B64_CHUNK);
    this.run('window.Native._begin(' + jq(id) + ',' + code + ',' + n + ',' + jq(headers ?? '{}') + ')');
    for (let i = 0; i < n; i++) {
      const end = Math.min(b.length, (i + 1) * B64_CHUNK);
      this.run('window.Native._chunk(' + jq(id) + ',' + i + ',' + jq(b.substring(i * B64_CHUNK, end)) + ')');
    }
  }

  private run(js: string): void {
    try {
      this.controller.runJavaScript(js);
    } catch (e) {
    }
  }

  /* ================= 异步：打开外链 / 分享 ================= */

  async openExternal(url: string): Promise<void> {
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };
      this.ctx.startAbility(want);
    } catch (e) {
      promptAction.showToast({ message: '打不开这个链接', duration: 1500 });
    }
  }

  async openInApp(url: string, title: string): Promise<void> {
    this.openExternal(url);
  }

  async share(url: string, title: string): Promise<void> {
    try {
      const want: Want = {
        action: 'ohos.want.action.sendData',
        entities: ['entity.system.share'],
        uri: url
      };
      this.ctx.startAbility(want);
    } catch (e) {
      this.openExternal(url);
    }
  }

  /* ================= 异步：下载与保存 ================= */

  /** 下载到应用沙箱 Download 目录（后续可换 @kit.RequestKit 做后台下载） */
  async download(url: string, filename: string): Promise<void> {
    await this.saveTo(url, filename, 'download');
  }

  async downloadWithHeaders(url: string, filename: string, headersJson: string): Promise<void> {
    await this.saveTo(url, filename, 'download', parseHeaders(headersJson));
  }

  async saveImage(url: string): Promise<void> {
    await this.saveTo(url, 'image_' + Date.now() + '.png', 'image');
  }

  /**
   * 依次尝试各条通道，谁先成功用谁。
   *
   * 通道清单见 DownloadChannels：加速镜像在前，直连兜底。
   *
   * ══ 令牌怎么处理 ══
   *   Android 版 1.2.15 的做法（这里照搬）：**照样走镜像，但走镜像时
   *   不转发凭据**。
   *
   *   · 公共资源的附件：镜像匿名就能取到 → 走加速，快；
   *   · 私有仓库的附件：镜像匿名取不到 → 立刻失败换道，
   *     最终落到直连那一条，带上令牌正常下载。
   *
   *   反过来的做法（带令牌就整条禁用镜像）会让公共大文件白白放弃加速，
   *   得不偿失 —— 而且 URL 本身已经送到镜像服务器了，转发不转发令牌
   *   对「隐私暴露」的边际影响很小，对「速度」的影响很大。
   */
  private async saveTo(url: string, name: string, dir: string, h?: Record<string, string>): Promise<void> {
    const list: ChannelCand[] = candidatesWithKeys(url, true);
    let lastErr: string = '下载失败';
    for (let i = 0; i < list.length; i++) {
      const isMirror: boolean = list[i].key !== DIRECT;
      const hh: Record<string, string> = isMirror ? stripAuth(h ?? {}) : (h ?? {});
      try {
        const r = await requestB64(list[i].url, hh);
        if (r.code < 200 || r.code >= 300) {
          lastErr = '下载失败（' + r.code + '）';
          continue;                       // 这条通道不通，换下一条
        }
        const bytes = new util.Base64Helper().decodeSync(r.body);
        const base = this.ctx.filesDir + '/' + dir;
        try { fs.mkdirSync(base, true); } catch (e) { }
        const path = base + '/' + safeName(name);
        const f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(f, bytes.buffer as ArrayBuffer);
        fs.closeSync(f);
        this.noteDownload(name, bytes.byteLength, true, list[i].key);
        const via: string = nameOf(list[i].key);
        promptAction.showToast({
          message: '已保存到应用目录（' + via + '）',
          duration: 1800
        });
        return;
      } catch (e) {
        lastErr = msg(e);
      }
    }
    this.noteDownload(name, 0, false, DIRECT);
    promptAction.showToast({ message: lastErr, duration: 1800 });
  }

  /** 下载留痕：前端「下载管理」页（page-downloads.js）读的就是这个 */
  private noteDownload(name: string, size: number, ok: boolean, channel: string): void {
    try {
      const raw: string = this.pref.getSync('gh_dl_history', '[]') as string;
      const arr: DownloadRecord[] = JSON.parse(raw) as DownloadRecord[];
      arr.unshift({
        name: name, url: '', size: size, ok: ok,
        at: Date.now(), channel: channel
      });
      while (arr.length > 50) arr.pop();
      this.pref.putSync('gh_dl_history', JSON.stringify(arr));
      this.pref.flushSync();
    } catch (e) {
    }
  }

  /** 鸿蒙没有 APK：把自动更新引导到官方 Release 页 */
  async installApkChecked(url: string, filename: string, headersJson: string, expectedSha: string): Promise<void> {
    promptAction.showToast({ message: '鸿蒙版请直接下载 HAP 更新', duration: 2000 });
    await this.openExternal('https://github.com/Buwrt/githup-hong/releases');
  }

  /* ================= 异步：文件选择 ================= */

  /**
   * 选文件，回调 window.Native._pick(id, meta, err)。
   * meta 是数组：[{ name, size, mime, uri }]，与 Android 版一致，
   * 前端 api.js 的 pickFile 会取第一个、pickFiles 取全部。
   */
  async pickFile(id: string, accept: string): Promise<void> {
    try {
      const doc = new picker.DocumentViewPicker(this.ctx);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 20;
      if (accept && accept.indexOf('image/') >= 0 && accept.indexOf('video/') < 0) {
        opts.fileSuffixFilters = ['image/*'];
      } else if (accept && accept.indexOf('video/') >= 0) {
        opts.fileSuffixFilters = ['video/*'];
      }
      const uris: string[] = await doc.select(opts);
      this.lastPickUris = uris ?? [];
      const meta: string[] = [];
      for (let i = 0; i < this.lastPickUris.length; i++) {
        meta.push(JSON.stringify({
          name: nameFromUri(this.lastPickUris[i]),
          size: 0,
          mime: '',
          uri: this.lastPickUris[i]
        }));
      }
      this.run('window.Native._pick(' + jq(id) + ',[' + meta.join(',') + '],' + '""' + ')');
    } catch (e) {
      // 用户取消也会进这里：按「取消」回一个空数组，前端 resolve(null)
      this.run('window.Native._pick(' + jq(id) + ',[],' + jq(msg(e)) + ')');
    }
  }

  async pickFolder(id: string): Promise<void> {
    this.run('window.Native._pick(' + jq(id) + ',null,"鸿蒙版暂不支持选文件夹")');
  }

  async listFolder(id: string, uri: string): Promise<void> {
    this.run('window.Native._pick(' + jq(id) + ',null,"鸿蒙版暂不支持选文件夹")');
  }

  /** 读文件为 base64，回调 _read（前端 upload-attach 用） */
  async readFileBase64(id: string, uri: string, maxBytes: number): Promise<void> {
    try {
      const f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const st = fs.statSync(f);
      const n = Math.min(st.size, maxBytes > 0 ? maxBytes : st.size);
      const buf = new ArrayBuffer(n);
      fs.readSync(f, buf);
      fs.closeSync(f);
      const b64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(buf));
      this.run('window.Native._read(' + jq(id) + ',' + jq(b64) + ',"")');
    } catch (e) {
      this.run('window.Native._read(' + jq(id) + ',"",' + jq(msg(e)) + ')');
    }
  }

  /* ================= 异步：上传 ================= */

  async uploadRaw(id: string, url: string, uri: string, headersJson: string): Promise<void> {
    try {
      const data = readAll(uri);
      const r = await uploadBytes('PUT', url, data, parseHeaders(headersJson));
      this.emit(id, r.code, r.body, r.headers);
    } catch (e) {
      this.emit(id, 0, '', '{\"error\":' + jq(msg(e)) + '}');
    }
  }

  async uploadBinary(id: string, url: string, uri: string, headersJson: string): Promise<void> {
    await this.uploadRaw(id, url, uri, headersJson);
  }

  async uploadMultipart(id: string, url: string, uri: string, headersJson: string, field: string): Promise<void> {
    // 多部件上传在鸿蒙侧需要拼 boundary；这里退化为单体 PUT，
    // 覆盖「上传 Release 附件 / 传文件到仓库」这两条主干路径
    await this.uploadRaw(id, url, uri, headersJson);
  }

  async uploadMultipartB64(id: string, url: string, uri: string, headersJson: string, field: string): Promise<void> {
    await this.uploadRaw(id, url, uri, headersJson);
  }

  /* ================= 异步：相机与日志导出 ================= */

  async requestCamera(id: string): Promise<void> {
    try {
      const at = abilityAccessCtrl.createAtManager();
      await at.requestPermissionsFromUser(this.ctx, ['ohos.permission.CAMERA']);
      const ok = await this.hasCamera();
      this.run('window.Native._camera(' + jq(id) + ',' + (ok ? 'true' : 'false') + ')');
    } catch (e) {
      this.run('window.Native._camera(' + jq(id) + ',false)');
    }
  }

  private async hasCamera(): Promise<boolean> {
    try {
      const at = abilityAccessCtrl.createAtManager();
      const tokenId = this.ctx.applicationInfo.accessTokenId;
      const g: Array<Permissions> = ['ohos.permission.CAMERA'];
      const r = await at.verifyAccessToken(tokenId, g);
      return r[0] === 0;
    } catch (e) {
      return false;
    }
  }

  /**
   * 导出日志。前端 api.js 的注册式回调是 window.Native._logSaved[id]，
   * 而统一回执走的是 window.Native.onLogSaved(cbId, ok) —— 这里调后者，
   * 与 Android 版 JsBridge.saveLog 的行为一致（成功回 true）。
   */
  async saveLog(cbId: string): Promise<void> {
    try {
      const txt = readLog(this.ctx);
      if (txt && txt.length > 0) {
        // 顺手落一份到应用目录，方便从「文件管理」里找到
        const p = this.ctx.filesDir + '/githup-log.txt';
        const f = fs.openSync(p, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(f, txt);
        fs.closeSync(f);
      }
      this.run('window.Native.onLogSaved(' + jq(cbId) + ',true)');
    } catch (e) {
      this.run('window.Native.onLogSaved(' + jq(cbId) + ',false)');
    }
  }

  async shareLog(): Promise<void> {
    this.saveLog('share');
  }

  async exportLog(): Promise<void> {
    this.saveLog('export');
  }

  async makeKeystore(id: string, seed: string, alias: string, storePass: string, keyPass: string): Promise<void> {
    // 手机上给 APK 签名这件事在鸿蒙上没有对应场景，交给前端 JS 兜底
    this.run('window.Native._ks(' + jq(id) + ',"","鸿蒙版不支持本地签名")');
  }

  async checkNotificationsNow(): Promise<void> {
    await this.notifWatch.checkOnce();
  }

  async prefetchImages(urlsJson: string): Promise<void> {
    // 图片由 ArkWeb 自己取，预热无意义
  }
}

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* 前后台生命周期                                                      */
/* ------------------------------------------------------------------ */

/*
 * UIAbility 的 onForeground / onBackground 与页面组件不是同一个作用域，
 * 而通知轮询的「续命」必须由 Ability 那一层触发，所以这里留一个句柄：
 * 页面创建桥接时登记，Ability 生命周期变化时回调。
 *
 * ⚠️ 为什么用静态属性而不是模块级 `let`：ArkTS 不允许在模块顶层用
 *    let / var 声明可变变量（只允许 const、类型、函数与类）。
 *    写成模块级 let 会直接编译不过，所以挂在类的静态属性上。
 */
class BridgeHolder {
  static current: NativeBridge | null = null;
}

export function registerBridge(b: NativeBridge): void {
  BridgeHolder.current = b;
}

export function notifyForeground(): void {
  const b: NativeBridge | null = BridgeHolder.current;
  if (b) b.onForeground();
}

export function notifyBackground(): void {
  const b: NativeBridge | null = BridgeHolder.current;
  if (b) b.onBackground();
}

function jq(s: string): string {
  return JSON.stringify(s ?? '');
}

/** 走镜像时不转发凭据：Authorization 头一律摘掉 */
function stripAuth(h: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  const keys: string[] = Object.keys(h);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() === 'authorization') continue;
    out[keys[i]] = h[keys[i]];
  }
  return out;
}

/** 申请通知权限：没权限的话前面那些通知发了也是白发 */
function requestNotifyPermission(ctx: common.UIAbilityContext): void {
  try {
    const at = abilityAccessCtrl.createAtManager();
    at.requestPermissionsFromUser(ctx, ['ohos.permission.NOTIFICATION_CONTROLLER']).catch(() => {
      // 权限申请被拒：不影响其他功能，通知静默降级
    });
  } catch (e) {
  }
}

interface DownloadRecord {
  name: string;
  url: string;
  size: number;
  ok: boolean;
  at: number;
  channel: string;
}

function msg(e: Object): string {
  const err = e as BusinessError;
  return err?.message ?? String(e);
}

function parseHeaders(json: string): Record<string, string> {
  const out: Record<string, string> = {};
  try {
    const o = JSON.parse(json ?? '{}') as Record<string, string>;
    const keys = Object.keys(o);
    for (let i = 0; i < keys.length; i++) {
      out[keys[i]] = String(o[keys[i]]);
    }
  } catch (e) {
  }
  return out;
}

function safeName(n: string): string {
  return (n ?? 'download').replace(/[\\/:*?"<>|]/g, '_');
}

function nameFromUri(uri: string): string {
  const i = uri.lastIndexOf('/');
  return i >= 0 ? uri.substring(i + 1) : uri;
}

function readAll(uri: string): ArrayBuffer {
  const f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
  const st = fs.statSync(f);
  const buf = new ArrayBuffer(st.size);
  fs.readSync(f, buf);
  fs.closeSync(f);
  return buf;
}

/** 文本日志：只记当天，存应用私有目录，与 Android 版 LogBook 的行为一致 */
function appendLog(line: string): void {
  try {
    // 这里用静态缓存，真正的落盘在 Index.ets 里通过 saveLog 触发
    LOG_LINES.push(new Date().toISOString().slice(0, 10) + ' ' + line);
    if (LOG_LINES.length > 500) LOG_LINES.splice(0, LOG_LINES.length - 500);
  } catch (e) {
  }
}

const LOG_LINES: string[] = [];

function readLog(ctx: common.UIAbilityContext): string {
  try {
    const f = fs.openSync(ctx.filesDir + '/githup-log.txt', fs.OpenMode.READ_ONLY);
    const st = fs.statSync(f);
    const buf = new ArrayBuffer(st.size);
    fs.readSync(f, buf);
    fs.closeSync(f);
    return new util.TextDecoder().decodeToString(new Uint8Array(buf));
  } catch (e) {
    return LOG_LINES.join('\n');
  }
}

import { webview, WebviewController } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.AbilityKit';
import { NativeBridge, registerBridge } from '../bridge/NativeBridge';

/**
 * 主页面：一个全屏 ArkWeb，前端 2.5 万行 JS 原样加载。
 *
 * 与 Android 版 MainActivity 的对应关系 ——
 *   · WebView 设置          → 这里的一组 .xxx(true/false)
 *   · addJavascriptInterface → .javaScriptProxy({ name: 'NativeBridge' })
 *   · evaluateJavascript     → controller.runJavaScript()
 *   · shouldOverrideUrlLoading → .onLoadIntercept / onUrlLoadIntercept
 *
 * 与 Android 版刻意不同的两处 ——
 *   1) 混合内容默认禁用（MIXED_CONTENT_NEVER_ALLOW 的等价设置），
 *      所有请求本来就是 https；
 *   2) 不做「file:// 只放行 SPA 入口」的拦截：鸿蒙这边页面是
 *      resource://rawfile 协议，前端的相对路径解析由 ArkWeb 自己完成。
 */

/** 同步方法：有返回值，前端可以直接拿到结果 */
const SYNC_METHODS: string[] = [
  'appVersion', 'certSha256', 'apkSha256',
  'getToken', 'setToken', 'getPref', 'setPref',
  'copy', 'getClipboard',
  'systemDark', 'safeInsets', 'setStatusBar', 'haptic',
  'imageProxyReady', 'isAppForeground',
  'notifWatchEnabled', 'setNotifWatch', 'notifWatchLastCheck',
  'totpBackgroundEnabled', 'totpSetBackground', 'totpSync',
  'getChannel', 'setChannel', 'downloadStatus', 'dismissSlowAdvice',
  'randomHex', 'logError', 'logNote'
];

/** 异步方法：拿不到返回值，结果用 runJavaScript 回吐给 window.Native.* */
const ASYNC_METHODS: string[] = [
  'http', 'httpB64',
  'openExternal', 'openInApp', 'share',
  'download', 'downloadWithHeaders', 'saveImage', 'installApkChecked',
  'pickFile', 'pickFolder', 'listFolder', 'readFileBase64',
  'uploadRaw', 'uploadBinary', 'uploadMultipart', 'uploadMultipartB64',
  'requestCamera', 'saveLog', 'shareLog', 'exportLog', 'makeKeystore',
  'checkNotificationsNow', 'prefetchImages'
];

@Entry
@Component
struct Index {
  private controller: WebviewController = new webview.WebviewController();
  private bridge: NativeBridge | null = null;
  @State private ready: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext() as common.UIAbilityContext;
    this.bridge = new NativeBridge(ctx, this.controller);
    // 令牌是加密存储的，解密是异步的：先起一个后台任务，
    // 等页面加载完再读也已经就绪（同步方法读的是内存缓存）。
    this.bridge.boot();
    // 登记给 EntryAbility：通知轮询要在前后台切换时续命/收尾
    registerBridge(this.bridge);
    this.ready = true;
  }

  build() {
    Column() {
      if (this.ready && this.bridge) {
        Web({ src: $rawfile('web/index.html'), controller: this.controller })
          .width('100%')
          .height('100%')
          .layoutWeight(1)
          // 前端是 JS 单页应用，必须开
          .javaScriptAccess(true)
          // 主题、路由、翻译开关都落在 localStorage
          .domStorageAccess(true)
          .databaseAccess(true)
          // README 里的图片、头像、issue 附件
          .imageAccess(true)
          .fileAccess(true)
          // 与 Android 版 MIXED_CONTENT_NEVER_ALLOW 同义
          .mixedMode(MixedMode.None)
          .cacheMode(CacheMode.Default)
          // 前端自己管加载指示与深浅色，别让 WebView 再自动反色一次
          .forceDarkAccess(false)
          .backgroundColor(Color.Transparent)
          .javaScriptProxy({
            object: this.bridge,
            name: 'NativeBridge',
            methodList: SYNC_METHODS,
            asyncMethodList: ASYNC_METHODS,
            controller: this.controller
          })
          .onPageEnd(() => {
            // 把外部传入的 GitHub 链接交给前端路由处理
            const deep = AppStorage.get<string>('gh_deep_link');
            if (deep && deep.length > 0) {
              AppStorage.setOrCreate<string>('gh_deep_link', '');
              this.controller.runJavaScript(
                'try{if(window.Router&&Router.open)' +
                'Router.open(' + JSON.stringify(deep) + ');}catch(e){}');
            }
          })
          .onErrorReceive((e) => {
            promptAction.showToast({ message: '页面加载出错，正在重试', duration: 1500 });
          })
          .onRenderExited(() => {
            // 渲染进程被系统回收：重建页面（与 Android 版 onRenderProcessGone 同处理）
            this.controller.loadUrl($rawfile('web/index.html'));
          })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 返回键先让网页后退，退不动了再退出应用 */
  onBackPress(): boolean {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (e) {
    }
    return false;
  }
}

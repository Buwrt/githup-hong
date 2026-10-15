import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notifyForeground, notifyBackground } from '../bridge/NativeBridge';

const TAG: string = 'GithupHong';

/**
 * 入口 Ability。
 *
 * 职责只有两件：加载主页面、接收外部传进来的 GitHub 链接。
 * Android 版在 MainActivity 里做的一大堆事（签名校验、防护链、
 * 权限申请、渲染进程重建）在这里被拆到了各自该去的地方：
 *   · 签名与防篡改 → 鸿蒙由系统在安装时校验 HAP 签名，运行时
 *     只能核对 bundleName 与签名指纹（NativeBridge.certSha256）；
 *   · 权限          → module.json5 声明 + 用时申请；
 *   · 渲染进程      → Index.ets 的 onRenderExited。
 */
export default class EntryAbility extends UIAbility {

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 从浏览器 / 其他应用「分享」或「打开方式」进来的 GitHub 链接
    const uri = want?.uri;
    if (uri && uri.length > 0) {
      AppStorage.setOrCreate<string>('gh_deep_link', uri);
    }
    hilog.info(0x0000, TAG, 'githup 鸿蒙版启动');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 应用已在后台时再次被链接唤起
    const uri = want?.uri;
    if (uri && uri.length > 0) {
      AppStorage.setOrCreate<string>('gh_deep_link', uri);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, '加载页面失败: %{public}s', JSON.stringify(err));
        return;
      }
      // 状态栏透明：让前端的毛玻璃顶栏一直接到屏幕最顶上
      windowStage.getMainWindowSync().setWindowLayoutFullScreen(true);
      windowStage.getMainWindowSync().setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000'
      });
    });
  }

  onForeground(): void {
    // 回到前台：恢复通知轮询
    try { notifyForeground(); } catch (e) { }
  }

  onBackground(): void {
    // 退到后台：给正在进行的通知检查续一段短时任务
    try { notifyBackground(); } catch (e) { }
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'githup 鸿蒙版退出');
  }
}

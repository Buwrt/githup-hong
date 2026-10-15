import { http } from '@kit.NetworkKit';
import { notificationManager } from '@kit.NotificationKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * GitHub 通知的后台轮询。
 *
 * 为什么非得有它 ——
 *   GitHub 不会把通知推给第三方 App，只能 App 自己去问。
 *   App 退后台后 ArkWeb 冻结、JS 停摆，没人问，通知栏就一条都没有。
 *   这里补上那个「问」的人。
 *
 * 与 Android 版 NotifWatchReceiver 的差异 ——
 *   Android 是 AlarmManager 定时发广播 + BroadcastReceiver + goAsync 续命，
 *   15 分钟一轮，系统层面就能保证进程被杀后还会被拉起来。
 *
 *   鸿蒙没有等价的「系统级定时广播」（最接近的是 WorkSchedulerExtensionAbility，
 *   但它有自己的调度约束，且要单独声明 ExtensionAbility）。
 *   首版因此采用两段式：
 *     · 应用在前台 / 存活时：setInterval 每 15 分钟问一次；
 *     · 应用退到后台时：用 backgroundTaskManager.requestSuspendDelay
 *       申请一段短时任务，把当前这一轮问完再让系统挂起。
 *
 *   ⚠️ 这意味着：**进程被彻底杀掉后，鸿蒙首版不会自动恢复轮询**，
 *   下次打开 App 才会继续。要做到和 Android 版一样「杀掉也能被拉起」，
 *   需要补一个 WorkSchedulerExtensionAbility（见文件末尾的实现要点）。
 */

const PREF_NAME: string = 'hub_prefs';
const KEY_ENABLED: string = 'gh_notif_watch';
const KEY_SEEN: string = 'gh_notif_seen';
const KEY_LAST: string = 'gh_notif_last_check';
const INTERVAL_MS: number = 15 * 60 * 1000;   // 与 Android 版一致
const NOTIF_ID: number = 20001;

export class NotifWatch {
  private ctx: common.UIAbilityContext;
  private pref: preferences.Preferences;
  private timer: number = -1;
  // 令牌由持有多条调用链的 NativeBridge 从内存缓存喂进来。
  // 令牌在磁盘上是 Keystore 加密的，这里不自己去解密、更不落盘，
  // 只在这一次请求里用一下，用完即弃。
  private tokenOf: (() => string) | null = null;

  constructor(ctx: common.UIAbilityContext, tokenProvider?: () => string) {
    this.ctx = ctx;
    this.pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
    this.tokenOf = tokenProvider ?? null;
  }

  enabled(): boolean {
    try {
      return this.pref.getSync(KEY_ENABLED, false) as boolean;
    } catch (e) {
      return false;
    }
  }

  setEnabled(on: boolean): void {
    try {
      this.pref.putSync(KEY_ENABLED, on);
      this.pref.flushSync();
    } catch (e) {
    }
    if (on) this.start();
    else this.stop();
  }

  lastCheck(): number {
    try {
      return this.pref.getSync(KEY_LAST, 0) as number;
    } catch (e) {
      return 0;
    }
  }

  /** 启动周期轮询（只在前台/存活期间有效） */
  start(): void {
    if (this.timer >= 0) return;
    this.timer = setInterval(() => {
      this.checkOnce();
    }, INTERVAL_MS);
    // 立刻问一次：刚打开开关的用户不该等 15 分钟才看到第一条
    this.checkOnce();
  }

  stop(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /** App 退到后台：拿一段短时任务把这一轮问完 */
  onBackground(): void {
    if (!this.enabled()) return;
    try {
      const delay = backgroundTaskManager.requestSuspendDelay('githup 通知检查', () => {
        // 到点回调：说明短时任务配额用完了，这里只做收尾
      });
      this.checkOnce().then(() => {
        try { backgroundTaskManager.cancelSuspendDelay(delay.requestId); } catch (e) { }
      });
    } catch (e) {
      this.checkOnce();
    }
  }

  /** 问一次 GitHub：拿到未读就发一条通知 */
  async checkOnce(): Promise<void> {
    if (!this.enabled()) return;
    const token: string = this.tokenOf ? this.tokenOf() : '';
    if (!token) return;   // 未登录：这一轮没得问，但轮询链不断，用户随时可能登录

    try {
      const req = http.createHttp();
      const res = await req.request('https://api.github.com/notifications?per_page=20', {
        method: http.RequestMethod.GET,
        header: {
          'Authorization': 'Bearer ' + token,
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'githup/1.0'
        }
      });
      const code: number = res.responseCode;
      if (code < 200 || code >= 300) {
        req.destroy();
        return;
      }
      const list: Array<NotifItem> = JSON.parse(String(res.result ?? '[]')) as Array<NotifItem>;
      req.destroy();

      const seen: string[] = this.seenIds();
      const fresh: NotifItem[] = [];
      for (let i = 0; i < list.length; i++) {
        const it: NotifItem = list[i];
        if (!it || !it.id) continue;
        if (seen.indexOf(it.id) >= 0) continue;
        if (it.unread === false) continue;
        fresh.push(it);
        seen.push(it.id);
      }
      // 只留最近 300 条 id，别让这个清单无限长
      while (seen.length > 300) seen.shift();
      try {
        this.pref.putSync(KEY_SEEN, JSON.stringify(seen));
        this.pref.putSync(KEY_LAST, Date.now());
        this.pref.flushSync();
      } catch (e) {
      }

      if (fresh.length > 0) this.publish(fresh);
    } catch (e) {
      const err = e as BusinessError;
      // 轮询失败不打扰用户：下一轮再来
    }
  }

  private seenIds(): string[] {
    try {
      const s: string = this.pref.getSync(KEY_SEEN, '[]') as string;
      const a: string[] = JSON.parse(s) as string[];
      return a ?? [];
    } catch (e) {
      return [];
    }
  }

  /** 发一条汇总通知；点它打开 GitHub 通知页 */
  private publish(items: NotifItem[]): void {
    try {
      const top: NotifItem = items[0];
      const title: string = items.length === 1
        ? (top.subject?.title ?? '新的 GitHub 通知')
        : 'GitHub 有 ' + items.length + ' 条新通知';
      const text: string = items.length === 1
        ? repoOf(top)
        : items.slice(0, 3).map((x: NotifItem) => x.subject?.title ?? '').join('\n');

      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.hubmobile.hong',
          abilityName: 'EntryAbility',
          uri: 'https://github.com/notifications'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      wantAgent.getWantAgent(wantAgentInfo).then((agent) => {
        notificationManager.publish({
          id: NOTIF_ID,
          content: {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: { title: title, text: text, additionalText: 'githup' }
          },
          wantAgent: agent
        }).catch(() => {
          // 通知权限没给：静默降级，不打扰
        });
      }).catch(() => {
      });
    } catch (e) {
    }
  }
}

interface NotifItem {
  id?: string;
  unread?: boolean;
  subject?: { title?: string; type?: string };
  repository?: { full_name?: string };
}

function repoOf(it: NotifItem): string {
  const r: string = it.repository?.full_name ?? '';
  const t: string = it.subject?.type ?? '';
  if (r && t) return r + ' · ' + t;
  return r || t || 'GitHub';
}

/*
 * ══ 后续要做的：让轮询在进程被杀后也能恢复 ══
 *
 * 补一个 WorkSchedulerExtensionAbility，要点如下：
 *
 *   1) 新建 entry/src/main/ets/extension/NotifWorkScheduler.ets，
 *      继承 WorkSchedulerExtensionAbility，在 onWorkStart 里
 *      跑一次 checkOnce()（令牌要在这里重新解密一次）；
 *   2) module.json5 的 extensionAbilities 里声明：
 *        { "name": "NotifWorkScheduler",
 *          "srcEntry": "./ets/extension/NotifWorkScheduler.ets",
 *          "type": "workScheduler" }
 *   3) 用 workScheduler.startWork 注册一个 repeatCycle = 15*60*1000 的
 *      循环任务，条件里加上 NetworkType.NETWORK_TYPE_ANY。
 *
 * 注意：鸿蒙的 WorkScheduler 不保证精确时刻（会做对齐与省电合并），
 * 所以即便补上它，行为上也更接近「大约每 15 分钟」而不是 Android
 * AlarmManager 的定点唤醒。这点要在界面文案上如实说明。
 */

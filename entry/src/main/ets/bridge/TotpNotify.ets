import { notificationManager } from '@kit.NotificationKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { compute, remaining, group, labelOf, dedupe, TotpAccount } from './TotpEngine';

/**
 * 两步验证器的后台常驻动态码通知。
 *
 * 移植自 Android 版 TotpService.java：挂一条常驻通知，里面是各账户
 * 当前的动态码，随 30 秒一轮自动刷新。
 *
 * ══ 为什么必须「常驻」而不是普通定时器 ══
 *   Android 8+ 会把后台进程冻结，普通定时器跑不准、码会停在旧值；
 *   只有前台服务能持续刷新，而前台服务按系统规定必须显示一条通知 ——
 *   这跟「用户要能在通知栏看到码」正好是一回事。
 *
 *   鸿蒙的情况类似：App 退到后台后 ArkWeb 冻结、JS 停摆。这里的做法是
 *   申请一个长时任务（KEEP_BACKGROUND_RUNNING），配合每秒一次的刷新。
 *
 * ⚠️ 长时任务在鸿蒙上会持续在通知栏显示「正在运行」的系统提示，
 *    这是系统规定，无法隐藏。用户关掉开关（totpSetBackground(false)）
 *    时这里会同时撤掉长时任务和通知。
 */

const PREF_NAME: string = 'hub_prefs';
const KEY_ACCOUNTS: string = 'totp_accounts_cache';
const KEY_BG: string = 'gh_totp_background';
const NOTIF_ID: number = 20002;

interface TotpRow {
  a: TotpAccount;
  code: string;
}

export class TotpNotify {
  private ctx: common.UIAbilityContext;
  private pref: preferences.Preferences;
  private timer: number = -1;
  private running: boolean = false;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
    this.pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
  }

  enabled(): boolean {
    try {
      return this.pref.getSync(KEY_BG, false) as boolean;
    } catch (e) {
      return false;
    }
  }

  /** 开关。关掉时把通知一并撤掉 —— 否则用户关了开关还看见一条，会以为没关成功。 */
  async setEnabled(on: boolean): Promise<void> {
    try {
      this.pref.putSync(KEY_BG, on);
      this.pref.flushSync();
    } catch (e) {
    }
    if (on) {
      await this.start();
    } else {
      await this.stop();
    }
  }

  /** 账户清单变了（新增/删除/编辑）：立刻重画一次 */
  refresh(): void {
    if (this.enabled() && this.timer >= 0) this.tick();
  }

  private accounts(): TotpAccount[] {
    try {
      const s: string = this.pref.getSync(KEY_ACCOUNTS, '[]') as string;
      const a: TotpAccount[] = JSON.parse(s) as TotpAccount[];
      return dedupe(a ?? []);
    } catch (e) {
      return [];
    }
  }

  private async start(): Promise<void> {
    if (this.timer >= 0) return;
    await this.startLongTask();
    this.tick();
    // 每秒一跳：码本身 30 秒才换，但「还剩几秒」要实时
    this.timer = setInterval(() => {
      this.tick();
    }, 1000);
  }

  private async stop(): Promise<void> {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    await this.stopLongTask();
    try {
      await notificationManager.cancel(NOTIF_ID);
    } catch (e) {
    }
  }

  private async startLongTask(): Promise<void> {
    if (this.running) return;
    try {
      /* 长时任务要一个 WantAgent，告诉系统「点那个常驻提示时回到哪儿」。
         这里指回本应用入口 —— 用户点它就是回到动态码页面。 */
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.hubmobile.hong',
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(this.ctx,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this.running = true;
    } catch (e) {
      // 长时任务没批下来（权限没给 / 系统限制）：通知照样发，
      // 只是 App 进后台后可能停在旧值 —— 降级使用，不打断用户
      this.running = false;
    }
  }

  private async stopLongTask(): Promise<void> {
    if (!this.running) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.ctx);
    } catch (e) {
    }
    this.running = false;
  }

  /** 算一遍所有账户的码，重发通知 */
  private tick(): void {
    const list: TotpAccount[] = this.accounts();
    if (list.length === 0) {
      try { notificationManager.cancel(NOTIF_ID); } catch (e) { }
      return;
    }

    const lines: string[] = [];
    let left: number = 30;
    Promise.all(list.map(async (a: TotpAccount) => {
      const code: string | null = await compute(a);
      const r: TotpRow = { a: a, code: code ?? '------' };
      return r;
    })).then((rows: TotpRow[]) => {
      for (let i = 0; i < rows.length; i++) {
        lines.push(labelOf(rows[i].a) + '  ' + group(rows[i].code));
      }
      left = remaining(list[0]);
      this.publish(lines, left);
    }).catch(() => {
      // 某个账户算不出来（密钥格式不对）：不影响其他账户的通知
      if (lines.length > 0) this.publish(lines, left);
    });
  }

  private publish(lines: string[], left: number): void {
    try {
      notificationManager.publish({
        id: NOTIF_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_MULTILINE,
          multiLine: {
            title: '动态验证码',
            text: lines.join('\n'),
            briefText: lines.length === 1 ? lines[0] : (lines.length + ' 个账户'),
            longText: lines.join('\n'),
            additionalText: left + ' 秒后刷新'
          }
        }
      }).catch(() => {
        // 通知权限没给：静默降级
      });
    } catch (e) {
    }
  }
}

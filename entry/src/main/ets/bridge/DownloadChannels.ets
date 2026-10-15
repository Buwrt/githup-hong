/**
 * 下载地址的候选通道：直连 + 若干第三方加速镜像。
 *
 * 移植自 Android 版 DownloadChannels.java，清单与顺序原样照搬
 * （那份清单是 CI 在真实公网出口下一条条实测出来的，带速度标注）。
 *
 * ══ 为什么鸿蒙版也需要它 ══
 *   国内网络下直连 GitHub 的 Release 附件（会 302 跳到
 *   objects.githubusercontent.com）普遍很慢，Android 版靠这批镜像
 *   把下载速度救回来。这个矛盾跟操作系统无关，是网络链路的问题。
 *
 * ══ 相对 Android 版的两处改动 ══
 *   1) 去掉了「记住上次走通的通道」那套机制。Android 版在 1.2.15 已经
 *      把它整个移除了（注释里写了原因：一次偶然的成功会永久改写全局
 *      顺序，国内用户反而被钉在最慢的直连上十几秒）。这里从一开始
 *      就不引入。
 *   2) 去掉了限速通道（THROTTLED / 劝 Star 那套）。那是 Android 版
 *      为了「没点 Star 就限速」做的产品决策，鸿蒙首版不移植，
 *      所有下载一律全速。
 *
 * ⚠️ 维护提醒：这些都是第三方免费服务，随时可能限速、挂掉或回错误页。
 *    加新镜像时必须真的实测过，别照抄别的项目的清单。
 */

/** 直连通道的 key */
export const DIRECT: string = 'direct';

/**
 * 云速通道：jsDelivr。
 * 它和下面那些「URL 前缀镜像」不是同一种拼法 —— 它只认
 * github.com/{owner}/{repo}@{ref}/{path} 这种仓库文件路径，
 * Release 附件拼不出来（返回 null，调用方跳过）。
 */
const TEMPLATED: string = 'https://fastly.jsdelivr.net/';

/** 加速镜像前缀（拼法：前缀 + 完整原 URL），顺序即尝试顺序 */
export const MIRRORS: string[] = [
  // —— 第一组：CI 实测可用，按速度排序 ——
  'https://cdn.gh-proxy.org/',        // 云析通道，21709 KB/s
  TEMPLATED,                          // 云速通道（jsDelivr），只对仓库文件生效
  'https://gh-proxy.com/',            // 1.2 MB/s
  'https://gh.llkk.cc/',              // 1.2 MB/s，TTFB 94ms 最快
  'https://cors.isteed.cc/',          // 1.2 MB/s
  'https://gh-proxy.at9.net/',        // 1.2 MB/s
  'https://gh.noki.icu/',             // 1.2 MB/s
  'https://ghfile.geekertao.top/',    // 1.2 MB/s（限流，降速复核通过）
  'https://ghproxy.net/',             // 432 KB/s
  'https://ghfast.top/',              // 130 KB/s，TTFB 8.9s 偏慢
  // —— 第二组：CI 的海外 IP 被拒，国内可能正常，保留待观察 ——
  'https://ghproxy.imciel.com/',      // 429 限流
  'https://gh.idayer.com/',           // 429 限流
  'https://gh.ddlc.top/',             // 429 限流
  'https://github.boki.moe/',         // 403
  'https://gh.h233.eu.org/',          // 403
  'https://proxy.vvvv.ee/',           // 403
  'https://ghproxy.homeboyc.cn/',     // 403
  'https://gh.zwy.one/'               // 连接超时
];

/** CI 实测可用的条数（第一组），界面上用来区分标注 */
export const VERIFIED_COUNT: number = 10;

/**
 * 只有这些域名的下载地址才允许走加速镜像。
 * 别把无关链接也送去代理 —— 用户的私有仓库附件 URL 已经够敏感了，
 * 再往第三方服务器上送一份毫无必要。
 */
const MIRRORABLE_HOSTS: string[] = [
  'github.com',
  'objects.githubusercontent.com',
  'raw.githubusercontent.com',
  'codeload.github.com'
];

/** 这个前缀是不是「只拼前缀」的普通镜像（jsDelivr 不是） */
export function isTemplated(m: string): boolean {
  return m === TEMPLATED;
}

function hostOf(url: string): string {
  const i: number = url.indexOf('://');
  if (i < 0) return '';
  let rest: string = url.substring(i + 3);
  const s: number = rest.indexOf('/');
  if (s >= 0) rest = rest.substring(0, s);
  const at: number = rest.indexOf('@');
  if (at >= 0) rest = rest.substring(at + 1);
  const c: number = rest.indexOf(':');
  if (c >= 0) rest = rest.substring(0, c);
  return rest.toLowerCase();
}

/** 这个地址可以走加速镜像吗 */
export function isMirrorable(url: string): boolean {
  if (!url) return false;
  const h: string = hostOf(url);
  return MIRRORABLE_HOSTS.indexOf(h) >= 0;
}

/**
 * 把原地址按某条通道改写成候选地址；这条通道不适用就返回 null。
 *
 * jsDelivr 只认 https://github.com/{owner}/{repo}@{ref}/{path}，
 * 其余（Release 附件、codeload）拼不出来 —— 返回 null 让调用方跳过，
 * 放一条必然 404 的地址进去只会白白浪费一轮换道。
 */
export function buildUrl(m: string, url: string): string | null {
  if (!m || !url) return null;
  if (isTemplated(m)) {
    const m2: RegExpExecArray | null = /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/(?:blob|raw)\/([^/]+)\/(.+)$/.exec(url);
    if (!m2) return null;
    return TEMPLATED + 'gh/' + m2[1] + '/' + m2[2] + '@' + m2[3] + '/' + m2[4];
  }
  return m + url;
}

/**
 * 生成候选下载地址：加速镜像在前，直连兜底。
 *
 * 直连永远放最后 —— Android 版注释里那句「海外用户绕代理会慢一点，
 * 但慢一点远好过先卡十几秒」在鸿蒙上同样成立。
 */
export function candidates(url: string, allowMirror: boolean): string[] {
  const out: string[] = [];
  if (allowMirror && isMirrorable(url)) {
    for (let i = 0; i < MIRRORS.length; i++) {
      const u: string | null = buildUrl(MIRRORS[i], url);
      if (u !== null) out.push(u);
    }
  }
  out.push(url);
  return out;
}

/** 一条候选：通道 key + 拼好的地址 */
export interface ChannelCand {
  key: string;    // DIRECT 或某个镜像前缀
  url: string;
}

/**
 * 与 candidates() 同序，但把「这条地址属于哪条通道」一起带出来。
 * 调用方要报「已保存（云析通道）」这类文案，就得知道走的是哪条，
 * 事后再从地址里反推容易出错（前缀和正文都是 https，切不好就是空的）。
 */
export function candidatesWithKeys(url: string, allowMirror: boolean): ChannelCand[] {
  const out: ChannelCand[] = [];
  if (allowMirror && isMirrorable(url)) {
    for (let i = 0; i < MIRRORS.length; i++) {
      const u: string | null = buildUrl(MIRRORS[i], url);
      if (u !== null) out.push({ key: MIRRORS[i], url: u });
    }
  }
  out.push({ key: DIRECT, url: url });
  return out;
}

/** 界面上给通道起的名字 */
export function nameOf(m: string): string {
  if (!m || m === DIRECT) return '直连';
  if (isTemplated(m)) return '云速';
  return hostOf(m);
}

/** 通道的适用范围说明（云速只对仓库文件生效，要在界面上写清楚） */
export function scopeOf(m: string): string {
  if (isTemplated(m)) return '仅仓库文件';
  return '';
}

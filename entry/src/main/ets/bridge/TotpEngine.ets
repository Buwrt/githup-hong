import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/**
 * TOTP / HOTP 计算（RFC 4226 / RFC 6238）。
 *
 * 移植自 Android 版 Totp.java，算法逐行对齐。
 *
 * 为什么前端已经有一份 JS 实现，原生还要再写一份 ——
 *   鸿蒙上 App 退到后台后 ArkWeb 会被冻结、JS 停摆，算不了码。
 *   要让通知栏里的动态码持续刷新，原生必须自己能算。
 *   三份实现（JS / 这个 / 通知栏）跑的是同一套 RFC 算法，结果必须一致。
 *
 * 与 Android 版的差异只有一处：HMAC 的载体。
 *   Android 是 javax.crypto.Mac（同步），鸿蒙是 cryptoFramework（异步），
 *   所以这里全是 async。调用方（通知刷新）本来就在异步上下文里，无影响。
 */

const B32: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/** 一个账户条目。字段与前端 totp.js 里存的 JSON 一致。 */
export interface TotpAccount {
  secret: string;
  type?: string;      // 'totp' | 'hotp'
  digits?: number;    // 6 或 8
  period?: number;    // 默认 30
  algo?: string;      // SHA1 / SHA256 / SHA512
  counter?: number;   // 仅 hotp
  issuer?: string;
  name?: string;
}

/** Base32 解码：大小写不敏感，忽略空格、连字符、下划线与尾部补位等号 */
export function b32decode(input: string): Uint8Array | null {
  if (!input) return null;
  let s: string = input.toUpperCase().replace(/[\s\-_]/g, '').replace(/=+$/, '');
  if (s.length === 0) return null;
  let bits: number = 0;
  let value: number = 0;
  let n: number = 0;
  const tmp: Uint8Array = new Uint8Array(Math.floor(s.length * 5 / 8) + 1);
  for (let i = 0; i < s.length; i++) {
    const idx: number = B32.indexOf(s.charAt(i));
    if (idx < 0) return null;          // 出现非法字符：整个密钥作废
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      tmp[n++] = (value >>> bits) & 0xff;
    }
  }
  if (n === 0) return null;
  return tmp.slice(0, n);
}

/**
 * 规整密钥：转大写、去分隔符、去尾部等号。
 * 去重时用它做指纹 —— 否则「JBSW Y3DP」和「jbswy3dp」会被当成两个账户，
 * 通知栏里并排出现两行一模一样的码（Android 版踩过，见 JsBridge.totpSync）。
 */
export function normalizeSecret(input: string): string {
  if (!input) return '';
  return input.toUpperCase().replace(/[\s\-_]/g, '').replace(/=+$/, '');
}

/** 8 字节大端计数器。分开写高低两段，避免 32 位移位的坑。 */
function counterBytes(counter: number): Uint8Array {
  const msg: Uint8Array = new Uint8Array(8);
  // JS 位运算是 32 位，counter 可能超过 2^31；用除法取高段更稳
  let high: number = Math.floor(counter / 4294967296);
  let low: number = counter % 4294967296;
  for (let i = 3; i >= 0; i--) {
    msg[i] = high % 256;
    high = Math.floor(high / 256);
  }
  for (let i = 7; i >= 4; i--) {
    msg[i] = low % 256;
    low = Math.floor(low / 256);
  }
  return msg;
}

/** HMAC → 动态截断 → 取模。async 是因为 cryptoFramework 是异步的。 */
async function hotp(key: Uint8Array, counter: number, digits: number, algo: string): Promise<string | null> {
  try {
    const msg: Uint8Array = counterBytes(counter);
    let macAlgo: string = 'SHA1';
    if (algo === 'SHA256') macAlgo = 'SHA256';
    else if (algo === 'SHA512') macAlgo = 'SHA512';

    // HMAC 的密钥必须用 'HMAC' 这个算法名来生成 / 还原；
    // 摘要算法（SHA1/SHA256/SHA512）是 Mac 那一侧的事，不能混用。
    const gen = cryptoFramework.createSymKeyGenerator('HMAC');
    const symKey = await gen.convertKey({ data: key });
    const mac = cryptoFramework.createMac(macAlgo);
    await mac.init(symKey);
    await mac.update({ data: msg });
    const out = await mac.doFinal();
    const hash: Uint8Array = out.data;

    const offset: number = hash[hash.length - 1] & 0x0f;
    const bin: number = ((hash[offset] & 0x7f) << 24)
      | ((hash[offset + 1] & 0xff) << 16)
      | ((hash[offset + 2] & 0xff) << 8)
      | (hash[offset + 3] & 0xff);

    let mod: number = 1;
    for (let i = 0; i < digits; i++) mod *= 10;
    let s: string = String(bin % mod);
    while (s.length < digits) s = '0' + s;
    return s;
  } catch (e) {
    return null;
  }
}

/** 算一个账户当前的动态码；失败返回 null */
export async function compute(a: TotpAccount): Promise<string | null> {
  if (!a) return null;
  const key: Uint8Array | null = b32decode(a.secret ?? '');
  if (!key) return null;

  let period: number = a.period ?? 30;
  if (period <= 0) period = 30;
  let digits: number = a.digits ?? 6;
  if (digits !== 8) digits = 6;
  const algo: string = a.algo ?? 'SHA1';

  if ((a.type ?? 'totp') === 'hotp') {
    return hotp(key, a.counter ?? 0, digits, algo);
  }
  const counter: number = Math.floor(Date.now() / 1000 / period);
  return hotp(key, counter, digits, algo);
}

/** 当前这一轮还剩几秒（通知栏的倒计时用它） */
export function remaining(a: TotpAccount): number {
  const period: number = (a && a.period && a.period > 0) ? a.period : 30;
  const t: number = Math.floor(Date.now() / 1000);
  return period - (t % period);
}

/** 「XXX XXX」分段，跟各家验证器一致，长串不容易看错位 */
export function group(code: string): string {
  if (!code) return '';
  if (code.length === 6) return code.substring(0, 3) + ' ' + code.substring(3);
  if (code.length === 8) return code.substring(0, 4) + ' ' + code.substring(4);
  return code;
}

/** 账户在通知栏里显示的标题：issuer(account) 的惯例写法 */
export function labelOf(a: TotpAccount): string {
  const issuer: string = (a.issuer ?? '').trim();
  const name: string = (a.name ?? '').trim();
  if (issuer && name) return issuer + '（' + name + '）';
  return issuer || name || '未命名账户';
}

/** 按「规整密钥 + 类型 + 参数」去重，与 Android 版 totpSync 的指纹口径一致 */
export function dedupe(list: TotpAccount[]): TotpAccount[] {
  const seen: Set<string> = new Set();
  const out: TotpAccount[] = [];
  for (let i = 0; i < list.length; i++) {
    const a: TotpAccount = list[i];
    if (!a) continue;
    let k: string = normalizeSecret(a.secret ?? '') + '|' + (a.type ?? 'totp')
      + '|' + (a.digits ?? 6) + '|' + (a.period ?? 30) + '|' + (a.algo ?? 'SHA1');
    if ((a.type ?? 'totp') === 'hotp') k += '|' + (a.counter ?? 0);
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(a);
  }
  return out;
}

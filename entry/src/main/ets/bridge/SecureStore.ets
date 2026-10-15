import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/**
 * 敏感数据（GitHub 访问令牌）的加密存储。
 *
 * 对齐 Android 版 githup 的 SecurePrefs.java：
 *   · 算法同为 AES-256-GCM，随机 12 字节 IV；
 *   · 密文同样以 Base64 落盘；
 *   · 分隔同样用 "]"（鸿蒙版多存一段 authTag，因为 GCM 的认证标签
 *     必须由调用方自己保存，解密时要塞回 init 的 params）。
 *
 * 与 Android 版唯一的结构差异：密钥管理。
 *   Android 走 AndroidKeyStore（系统级密钥库，密钥材料不出 TEE）；
 *   鸿蒙这版用 cryptoFramework 生成 AES-256 密钥，材料写到应用私有目录
 *   filesDir 下的 githup.key。鸿蒙的应用沙箱本身就是隔离的
 *   （/data/storage/el2/base，其他应用与 adb backup 均读不到），
 *   且 el2 分区在锁屏状态下是加密的 —— 这是本版能达到的等价强度。
 *   想要系统级密钥库的话可以把这里换成 HUKS（@kit.UniversalKeystoreKit），
 *   接口位置与调用顺序完全一致，见文件末尾的注释。
 */

const KEY_FILE: string = 'githup.key';
const IV_LEN: number = 12;
const TAG_LEN: number = 16;
const SEP: string = ']';

export class SecureStore {
  private ctx: common.UIAbilityContext;
  private keyCache: cryptoFramework.SymKey | null = null;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  private keyPath(): string {
    return this.ctx.getApplicationContext().filesDir + '/' + KEY_FILE;
  }

  /** 取（或首次生成）AES-256 主密钥 */
  private async ensureKey(): Promise<cryptoFramework.SymKey | null> {
    if (this.keyCache) return this.keyCache;
    const gen = cryptoFramework.createSymKeyGenerator('AES256');
    const path = this.keyPath();
    try {
      // 已存在：读回来还原成 SymKey
      const buf = new ArrayBuffer(32);
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const n = fs.readSync(f, buf);
      fs.closeSync(f);
      if (n === 32) {
        const blob: cryptoFramework.DataBlob = { data: new Uint8Array(buf) };
        this.keyCache = await gen.convertKey(blob);
      }
    } catch (e) {
      // 文件不存在或内容不对：下面重新生成
    }
    if (!this.keyCache) {
      try {
        const k = await gen.generateSymKey();
        const raw: Uint8Array = k.getEncoded().data;
        const f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        fs.writeSync(f, raw.buffer as ArrayBuffer);
        fs.closeSync(f);
        this.keyCache = k;
      } catch (e2) {
        return null;
      }
    }
    return this.keyCache;
  }

  /** 用随机 IV 加密，返回 "b64(iv)]b64(密文)]b64(tag)" */
  async encrypt(plain: string): Promise<string | null> {
    try {
      const key = await this.ensureKey();
      if (!key) return null;
      const rand = cryptoFramework.createRandom();
      const iv = rand.generateRandomSync(IV_LEN);
      const gcm: cryptoFramework.GcmParamsSpec = {
        iv: { data: iv },
        aad: { data: new Uint8Array([]) },
        authTag: { data: new Uint8Array(TAG_LEN) },
        algName: 'GcmParamsSpec'
      };
      const enc = cryptoFramework.createCipher('AES256|GCM|PKCS7');
      await enc.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, gcm);
      const out = await enc.doFinal({ data: new Uint8Array(new util.TextEncoder().encodeInto(plain)) });
      // GCM 的 authTag 在 doFinal 之后回填到 params 里，解密时要用同一份
      const tag: Uint8Array = gcm.authTag ? gcm.authTag.data : new Uint8Array(TAG_LEN);
      return b64(iv) + SEP + b64(out.data) + SEP + b64(tag);
    } catch (e) {
      return null;
    }
  }

  /** 解密 encrypt() 的产物；解不开返回 null（不要静默返回明文） */
  async decrypt(packed: string): Promise<string | null> {
    try {
      const parts = packed.split(SEP);
      if (parts.length !== 3) return null;
      const key = await this.ensureKey();
      if (!key) return null;
      const iv = unb64(parts[0]);
      const data = unb64(parts[1]);
      const tag = unb64(parts[2]);
      const gcm: cryptoFramework.GcmParamsSpec = {
        iv: { data: iv },
        aad: { data: new Uint8Array([]) },
        authTag: { data: tag },
        algName: 'GcmParamsSpec'
      };
      const dec = cryptoFramework.createCipher('AES256|GCM|PKCS7');
      await dec.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, gcm);
      const out = await dec.doFinal({ data: data });
      return new util.TextDecoder().decodeWithStream(out.data, { stream: false });
    } catch (e) {
      return null;
    }
  }
}

function b64(u: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(u);
}

function unb64(s: string): Uint8Array {
  return new util.Base64Helper().decodeSync(s);
}

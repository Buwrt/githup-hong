/* ============================================================
 * 纯 Node 实现的 keystore 生成（不依赖 openssl）
 *
 * 为什么要有这一份：
 *   Android 版自带 KeyTool.java（纯 Java 生成 keystore），为的就是
 *   「不用在电脑上装 JDK」。桌面版在 Linux / macOS 上可以直接调 openssl，
 *   但 Windows 没有 openssl —— 而 Windows 恰恰是最需要 exe 的地方。
 *   所以这里用 Node 内置 crypto 自己拼一份 PKCS#12。
 *
 * 产出结构与 openssl pkcs12 -export 一致：
 *   PFX { version 3,
 *         authSafe: [ 私钥袋（PBES2 + AES-256-CBC 加密）, 证书袋（明文） ],
 *         macData: SHA-256 HMAC，密钥按 RFC 7292 附录 B.2 的 PKCS#12 KDF 派生 }
 *
 * 生成的 .p12 已用 keytool（Java 11）实测可读 —— 见 tools/下的验证脚本。
 * ============================================================ */

/* ---------------- 最小 ASN.1 DER 编码 ---------------- */

const T_SEQ = 0x30, T_INT = 0x02, T_OID = 0x06, T_OCT = 0x04,
  T_NULL = 0x05, T_SET = 0x31, T_BIT = 0x03, T_UTF8 = 0x0c, T_PRINT = 0x13;

function derLen(n) {
  if (n < 0x80) return Buffer.from([n]);
  const b = [];
  let v = n;
  while (v > 0) { b.unshift(v & 0xff); v >>= 8; }
  return Buffer.from([0x80 | b.length, ...b]);
}

function tlv(tag, content) {
  return Buffer.concat([Buffer.from([tag]), derLen(content.length), content]);
}

function derInt(v) {
  let hex;
  if (typeof v === 'bigint') {
    const neg = v < 0n;
    let s = (neg ? -v : v).toString(16);
    if (s.length % 2) s = '0' + s;
    let b = Buffer.from(s, 'hex');
    if (b[0] & 0x80) b = Buffer.concat([Buffer.from([0]), b]);
    if (neg) { /* 本文件只用到正整数 */ }
    return tlv(T_INT, b);
  }
  hex = Math.abs(Math.floor(v)).toString(16);
  if (hex.length % 2) hex = '0' + hex;
  if (parseInt(hex[0], 16) & 8) hex = '00' + hex;
  return tlv(T_INT, Buffer.from(hex, 'hex'));
}

function derOid(dotted) {
  const parts = dotted.split('.').map(Number);
  const out = [40 * parts[0] + parts[1]];
  for (let i = 2; i < parts.length; i++) {
    let v = parts[i];
    const stack = [v & 0x7f];
    v >>= 7;
    while (v > 0) { stack.unshift((v & 0x7f) | 0x80); v >>= 7; }
    out.push(...stack);
  }
  return tlv(T_OID, Buffer.from(out));
}

const A_NULL = Buffer.from([T_NULL, 0x00]);

/** AlgorithmIdentifier，带可选参数 */
function alg(oid, params) {
  return tlv(T_SEQ, Buffer.concat([derOid(oid), params ? params : A_NULL]));
}

/* ---------------- RFC 7292 附录 B.2：PKCS#12 KDF ---------------- */

/**
 * @param hash   'sha1' | 'sha256'
 * @param pass   UTF-16BE 编码后的口令（含结尾 2 个零字节）
 * @param salt   盐
 * @param iter   迭代次数
 * @param id     用途标识（1=key, 2=iv, 3=mac）
 * @param n      需要的字节数
 */
function pkcs12Kdf(hash, passBuf, salt, iter, id, n) {
  const u = 64;                                   // SHA-1 / SHA-256 的块长都是 64
  const v = hash === 'sha1' ? 20 : 32;            // 摘要长度
  const H = (b) => crypto.createHash(hash).update(b).digest();

  /*
   * ⚠️ 这里的两个长度是「实现说了算」，不是「标准说了算」。
   *
   * RFC 7292 附录 B.2 写的填充单位是 v（摘要长度，sha256 为 32），
   * 但 OpenSSL 实际用 u（分组长度 64）—— D 也按 u 字节填。
   * 由于 openssl 与 keytool 能互相读取对方生成的 p12，它们必然一致，
   * 所以这里照 OpenSSL 的实现来：D 长 u，S / P 填到 u 的倍数。
   *
   * 这两个值是用「openssl pkcs12 -export 生成的真实 p12 反推 MAC」比对出来的
   * （见 winbuild/verify-keystore.js），不是照抄标准文本 —— 照抄会算出
   * 一个谁都验不过的 MAC。
   */
  const D = Buffer.alloc(u, id);

  const fill = (src, mul) => {
    const want = Math.ceil(src.length / mul) * mul || mul;
    const out = Buffer.alloc(want);
    for (let i = 0; i < want; i++) out[i] = src[i % src.length];
    return out;
  };
  const S = fill(salt, u);
  const P = fill(passBuf, u);
  const I = Buffer.concat([S, P]);

  const A = [];
  let cur = I;
  const c = Math.ceil(n / v);
  for (let i = 1; i <= c; i++) {
    let Ai = Buffer.concat([D, cur]);
    for (let k = 0; k < iter; k++) Ai = H(Ai);
    A.push(Ai);
    if (i === c) break;

    // B = Ai 重复到 v 字节
    const B = Buffer.alloc(v);
    for (let j = 0; j < v; j++) B[j] = Ai[j % v];

    // I 切成 v 字节的块，每块当作大整数做 (I_j + B + 1) mod 2^(v*8)
    const next = Buffer.from(cur);
    for (let j = 0; j < next.length; j += v) {
      let carry = 1;                              // 那个 "+1"
      for (let p = v - 1; p >= 0; p--) {          // 大端：从最低字节往高字节进位
        const sum = next[j + p] + B[p] + carry;
        carry = sum > 255 ? 1 : 0;
        next[j + p] = sum & 0xff;
      }
    }
    cur = next;
  }
  return Buffer.concat(A).subarray(0, n);
}

/** 口令转 UTF-16BE + 结尾 2 个零字节（PKCS#12 的口令编码） */
function p12Password(str) {
  const s = String(str || '');
  const out = Buffer.alloc(s.length * 2 + 2);
  for (let i = 0; i < s.length; i++) {
    out.writeUInt16BE(s.charCodeAt(i), i * 2);
  }
  out.writeUInt16BE(0, s.length * 2);
  return out;
}

/* ---------------- X.509 自签证书 ---------------- */

function derName(cn, o, c) {
  const atv = (oid, str) => tlv(T_SEQ, Buffer.concat([derOid(oid), tlv(T_PRINT, Buffer.from(str, 'ascii'))]));
  const parts = [];
  if (c) parts.push(atv('2.5.4.6', c));
  if (o) parts.push(atv('2.5.4.10', o));
  if (cn) parts.push(atv('2.5.4.3', cn));
  return tlv(T_SEQ, Buffer.concat(parts));       // Name = RDNSequence
}

function derTime(date) {
  // UTCTime: YYMMDDHHMMSSZ（2049 年之前都用它，兼容性最好）
  const y = String(date.getUTCFullYear()).slice(2);
  const p = (n) => String(n).padStart(2, '0');
  const s = y + p(date.getUTCMonth() + 1) + p(date.getUTCDate()) +
    p(date.getUTCHours()) + p(date.getUTCMinutes()) + p(date.getUTCSeconds()) + 'Z';
  return tlv(0x17, Buffer.from(s, 'ascii'));
}

/** 生成自签 X.509 证书（DER） */
function selfSignedCert(privKey, pubKeyDer, cn) {
  const now = new Date();
  const later = new Date(now.getTime() + 10950 * 86400000);   // 30 年

  const serial = derInt(0x1000 + (crypto.randomBytes(4).readUInt32BE(0) % 0x7fffffff));

  /* extensions：basicConstraints / keyUsage / subjectKeyIdentifier */
  const ski = crypto.createHash('sha1').update(pubKeyDer).digest();
  const extSki = tlv(T_SEQ, Buffer.concat([
    derOid('2.5.29.14'), tlv(T_OCT, tlv(T_OCT, ski))
  ]));
  const extBc = tlv(T_SEQ, Buffer.concat([
    derOid('2.5.29.19'), Buffer.from([0x01, 0x01, 0x00]),      // critical = TRUE
    tlv(T_OCT, tlv(T_SEQ, Buffer.alloc(0)))
  ]));
  const kuBits = Buffer.from([0x03, 0x02, 0x05, 0xa0]);        // BIT STRING: digitalSignature|keyEncipherment
  const extKu = tlv(T_SEQ, Buffer.concat([
    derOid('2.5.29.15'), Buffer.from([0x01, 0x01, 0x00]),
    tlv(T_OCT, kuBits)
  ]));
  const exts = tlv(0xa3, tlv(T_SEQ, Buffer.concat([extSki, extBc, extKu])));

  const name = derName(cn || 'githup', 'githup', 'CN');
  const algId = alg('1.2.840.113549.1.1.11');                 // sha256WithRSAEncryption

  const tbs = tlv(T_SEQ, Buffer.concat([
    tlv(0xa0, derInt(2)),                                     // version v3
    serial,
    algId,
    name,
    tlv(T_SEQ, Buffer.concat([derTime(now), derTime(later)])),
    name,
    pubKeyDer,
    exts
  ]));

  const sig = crypto.sign('sha256', tbs, privKey);
  return tlv(T_SEQ, Buffer.concat([
    tbs, algId, tlv(T_BIT, Buffer.concat([Buffer.from([0x00]), sig]))
  ]));
}

/* ---------------- PKCS#12 ---------------- */

const OID_DATA = '1.2.840.113549.1.7.1';
const OID_KEY_BAG = '1.2.840.113549.1.12.10.1.2';             // pkcs8ShroudedKeyBag
const OID_CERT_BAG = '1.2.840.113549.1.9.22.1';
const OID_X509_CERT = '1.2.840.113549.1.9.22.1';
const OID_LOCAL_KEY_ID = '1.2.840.113549.1.9.21';
const OID_FRIENDLY_NAME = '1.2.840.113549.1.9.20';
const OID_PBES2 = '1.2.840.113549.1.5.13';
const OID_PBKDF2 = '1.2.840.113549.1.5.12';
const OID_HMAC_SHA256 = '1.2.840.113549.2.9';
const OID_AES256_CBC = '2.16.840.1.101.3.4.1.42';

function attr(oid, value) {
  return tlv(T_SEQ, Buffer.concat([derOid(oid), tlv(T_SET, value)]));
}

/** 私钥用 PBES2(PBKDF2-HmacSHA256 + AES-256-CBC) 加密 */
function shroudKey(pkcs8der, passStr) {
  const salt = crypto.randomBytes(16);
  const iter = 2048;
  const iv = crypto.randomBytes(16);
  const key = crypto.pbkdf2Sync(Buffer.from(passStr, 'utf8'), salt, iter, 32, 'sha256');

  const c = crypto.createCipheriv('aes-256-cbc', key, iv);
  const enc = Buffer.concat([c.update(pkcs8der), c.final()]);

  const params = tlv(T_SEQ, Buffer.concat([
    tlv(T_SEQ, Buffer.concat([
      derOid(OID_PBKDF2),
      tlv(T_SEQ, Buffer.concat([
        tlv(T_OCT, salt),
        derInt(iter),
        derInt(32),
        alg(OID_HMAC_SHA256)
      ]))
    ])),
    tlv(T_SEQ, Buffer.concat([derOid(OID_AES256_CBC), tlv(T_OCT, iv)]))
  ]));

  return tlv(T_SEQ, Buffer.concat([
    tlv(T_SEQ, Buffer.concat([derOid(OID_PBES2), params])),
    tlv(T_OCT, enc)
  ]));
}

/**
 * 生成一份 PKCS#12（.p12 / .keystore）。
 * @returns Buffer —— 可直接 base64 后当 Android 签名库用
 */
function buildPkcs12(alias, passStr) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicExponent: 65537
  });

  const pkcs8 = privateKey.export({ type: 'pkcs8', format: 'der' });
  const spki = publicKey.export({ type: 'spki', format: 'der' });
  const cert = selfSignedCert(privateKey, spki, alias || 'githup');

  const localKeyId = crypto.createHash('sha1').update(spki).digest();

  const bagAttrs = tlv(T_SET, Buffer.concat([
    attr(OID_LOCAL_KEY_ID, tlv(T_OCT, localKeyId)),
    attr(OID_FRIENDLY_NAME, tlv(0x1e,                          // BMPString（大端，不带终止符）
      Buffer.from(alias || 'githup', 'utf16le').swap16()))
  ]));

  const keyBag = tlv(T_SEQ, Buffer.concat([
    derOid(OID_KEY_BAG),
    tlv(0xa0, shroudKey(pkcs8, passStr)),
    bagAttrs
  ]));

  const certBag = tlv(T_SEQ, Buffer.concat([
    derOid(OID_CERT_BAG),
    tlv(0xa0, tlv(T_SEQ, Buffer.concat([
      derOid(OID_X509_CERT),
      tlv(0xa0, tlv(T_OCT, cert))
    ]))),
    bagAttrs
  ]));

  const wrap = (bags) => tlv(T_SEQ, Buffer.concat([            // ContentInfo
    derOid(OID_DATA),
    tlv(0xa0, tlv(T_OCT, tlv(T_SEQ, Buffer.concat(bags))))     // SafeContents
  ]));

  const safe = tlv(T_SEQ, Buffer.concat([
    wrap([keyBag]),
    wrap([certBag])
  ]));

  const authSafe = tlv(T_SEQ, Buffer.concat([                  // ContentInfo(data)
    derOid(OID_DATA),
    tlv(0xa0, tlv(T_OCT, safe))
  ]));

  /* macData：对 AuthenticatedSafe 的 DER 算 HMAC */
  const macSalt = crypto.randomBytes(8);
  const macIter = 2048;
  const macKey = pkcs12Kdf('sha256', p12Password(passStr), macSalt, macIter, 3, 32);
  const mac = crypto.createHmac('sha256', macKey).update(safe).digest();

  const macData = tlv(T_SEQ, Buffer.concat([
    tlv(T_SEQ, Buffer.concat([                                 // DigestInfo
      alg('2.16.840.1.101.3.4.2.1'),                           // sha256
      tlv(T_OCT, mac)
    ])),
    tlv(T_OCT, macSalt),
    derInt(macIter)
  ]));

  return tlv(T_SEQ, Buffer.concat([derInt(3), authSafe, macData]));
}

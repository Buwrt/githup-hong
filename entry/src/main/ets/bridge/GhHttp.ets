import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

/**
 * 网络层：GitHub 接口与二进制资源的统一出口。
 *
 * Android 版是自己写了一套 HTTP/1.1 协议栈（Http.java，999 行），
 * 因为那边要绕开 WebView 的跨域与连接问题。鸿蒙这边系统 http 模块
 * 已经是可用的原生栈，直接复用即可，不需要再手写报文。
 *
 * 相比 Android 版，这里补了两点：
 *   1) 跟随重定向时，如果跳到了别的域名，主动剥离 Authorization。
 *      Android 版 Http.java:185-191 是「同一套 headers 一路带到底」，
 *      GitHub 的图会 302 跳到私有 CDN 域，令牌就跟着过去了。
 *      鸿蒙版默认按最小暴露处理。
 *   2) 二进制单独走 ARRAY_BUFFER，不再经 String 转一圈（Android 版
 *      为此还专门写了 requestB64，注释里写明了「绝不能过一遍 String」）。
 */

export interface GhResponse {
  code: number;
  body: string;        // 文本响应；二进制模式下是 base64
  headers: string;     // JSON 字符串，交给前端 window.Native._cb 的第四个参数
}

const MAX_REDIRECT: number = 5;
const UA: string = 'githup/1.0';

function hostOf(url: string): string {
  const i = url.indexOf('://');
  if (i < 0) return '';
  let rest = url.substring(i + 3);
  const s = rest.indexOf('/');
  if (s >= 0) rest = rest.substring(0, s);
  const at = rest.indexOf('@');
  if (at >= 0) rest = rest.substring(at + 1);
  const c = rest.indexOf(':');
  if (c >= 0) rest = rest.substring(0, c);
  return rest.toLowerCase();
}

function resolve(base: string, loc: string): string {
  try {
    return new URL(loc, base).toString();
  } catch (e) {
    return loc;
  }
}

/** 文本请求（GitHub REST 接口走这条） */
export async function requestText(
  method: string,
  url: string,
  body: string | null,
  headers: Record<string, string>
): Promise<GhResponse> {
  return doRequest(method, url, body, headers, false);
}

/** 二进制请求，body 以 base64 返回（README 图片、头像、附件走这条） */
export async function requestB64(
  url: string,
  headers: Record<string, string>
): Promise<GhResponse> {
  return doRequest('GET', url, null, headers, true);
}

async function doRequest(
  method: string,
  startUrl: string,
  body: string | null,
  startHeaders: Record<string, string>,
  binary: boolean
): Promise<GhResponse> {
  let current: string = startUrl;
  let methodU: string = method.toUpperCase();
  const hdr: Record<string, string> = Object.assign({}, startHeaders);
  hdr['User-Agent'] = UA;

  for (let i = 0; i <= MAX_REDIRECT; i++) {
    const r = await once(methodU, current, body, hdr, binary);
    const loc = pickHeader(r, 'location');
    if (r.code >= 300 && r.code < 400 && loc && loc.length > 0) {
      const next = resolve(current, loc);
      if (hostOf(next) !== hostOf(current)) {
        // 跨域跳转：令牌不再跟着过去
        delete hdr['Authorization'];
        delete hdr['authorization'];
      }
      if (r.code === 303) methodU = 'GET';
      current = next;
      continue;
    }
    return r;
  }
  throw new Error('重定向次数过多');
}

function pickHeader(r: GhResponse, name: string): string {
  try {
    const o = JSON.parse(r.headers) as Record<string, string>;
    const keys = Object.keys(o);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === name) return String(o[keys[i]]);
    }
  } catch (e) {
  }
  return '';
}

function once(
  method: string,
  url: string,
  body: string | null,
  headers: Record<string, string>,
  binary: boolean
): Promise<GhResponse> {
  return new Promise<GhResponse>((resolve, reject) => {
    const req = http.createHttp();
    const opt: http.HttpRequestOptions = {
      method: toMethod(method),
      header: headers,
      expectDataType: binary ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: binary ? 60000 : 30000
    };
    if (body !== null && body !== undefined && body.length > 0) {
      opt.extraData = body;
    }
    req.request(url, opt).then((resp: http.HttpResponse) => {
      let text = '';
      if (binary) {
        const ab = resp.result as ArrayBuffer;
        text = new util.Base64Helper().encodeToStringSync(new Uint8Array(ab));
      } else {
        text = typeof resp.result === 'string' ? resp.result : String(resp.result ?? '');
      }
      const out: GhResponse = {
        code: resp.responseCode,
        body: text,
        headers: JSON.stringify(resp.header ?? {})
      };
      resolve(out);
    }).catch((e: Error) => {
      reject(e);
    }).finally(() => {
      req.destroy();
    });
  });
}

function toMethod(m: string): http.RequestMethod {
  switch (m) {
    case 'GET': return http.RequestMethod.GET;
    case 'POST': return http.RequestMethod.POST;
    case 'PUT': return http.RequestMethod.PUT;
    case 'PATCH': return http.RequestMethod.PATCH;
    case 'DELETE': return http.RequestMethod.DELETE;
    case 'HEAD': return http.RequestMethod.HEAD;
    case 'OPTIONS': return http.RequestMethod.OPTIONS;
    default: return http.RequestMethod.GET;
  }
}

/**
 * 二进制请求体（上传文件到仓库 / 上传 Release 附件）。
 * body 直接传 ArrayBuffer，不经 String —— 经 String 会让二进制被 UTF-8 搅碎。
 */
export async function uploadBytes(
  method: string,
  url: string,
  data: ArrayBuffer,
  headers: Record<string, string>
): Promise<GhResponse> {
  return new Promise<GhResponse>((resolve, reject) => {
    const req = http.createHttp();
    const h: Record<string, string> = Object.assign({}, headers);
    h['User-Agent'] = UA;
    req.request(url, {
      method: toMethod(method),
      header: h,
      extraData: data,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 20000,
      readTimeout: 120000
    }).then((resp: http.HttpResponse) => {
      resolve({
        code: resp.responseCode,
        body: typeof resp.result === 'string' ? resp.result : String(resp.result ?? ''),
        headers: JSON.stringify(resp.header ?? {})
      });
    }).catch((e: Error) => {
      reject(e);
    }).finally(() => {
      req.destroy();
    });
  });
}

/* ------------------------------------------------------------------
 * 想换成系统级密钥库时看这里（与 SecureStore 二选一）：
 *
 *   import { huks } from '@kit.UniversalKeystoreKit';
 *   const ALIAS = 'hub_aes_key';
 *   // 生成：huks.generateKeyItem(ALIAS, { properties: [算法 AES、密钥长度 256、
 *   //   用途 ENCRYPT|DECRYPT、分组 GCM、填充 NONE] })
 *   // 加解密：huks.initSession(ALIAS, opts) -> updateSession -> finishSession
 *
 * 换成 HUKS 后 SecureStore 的 encrypt/decrypt 签名不用改，
 * 只是密钥材料不再落文件，改由系统密钥库托管。
 * ------------------------------------------------------------------ */

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把本机签好的 HAP 发布到 GitHub Release，并回填仓库根目录的 version.json。

══ 为什么要有这个脚本 ══
HAP 的签名只能用维护者自己的华为开发者证书（p12 / cer / p7b），
这一步无法在 CI 或他人机器上代劳，所以出包必然是本机动作。
出完包还要做三件容易漏的事：算 sha256、回填 version.json、
把包挂到 Release 上 —— 漏一件，App 内的「检查更新」就会给出
错误结论（上游 Android 版踩过「版本号没变、值却是上一个包的」，
用户点「检查更新」看到「你已是最新版本」，其实根本没拿到新包）。

用法：

    python3 tools/publish-hap.py entry/build/default/outputs/default/entry-default-signed.hap

可选参数：
    --tag v1.0.0        发布到哪个 Release（默认按 version.json 的 version 加 v 前缀）
    --notes "一句话"     追加到 Release 说明末尾
    --new               Release 不存在时新建（默认：必须先存在，避免误建）
    --dry-run           只算值、改本地 version.json，不碰远端

令牌从环境变量 GITHUB_TOKEN 读，不写在文件里：

    export GITHUB_TOKEN=ghp_xxx
    python3 tools/publish-hap.py <hap路径>
"""

import argparse
import hashlib
import json
import os
import sys

try:
    import requests
except ImportError:
    sys.stderr.write('需要 requests：pip install requests\n')
    sys.exit(1)

OWNER = 'Buwrt'
REPO = 'githup-hong'
API = 'https://api.github.com'


def repo_root() -> str:
    """从脚本位置往上找带 version.json 的那一层"""
    d = os.path.dirname(os.path.abspath(__file__))
    for _ in range(5):
        if os.path.exists(os.path.join(d, 'version.json')):
            return d
        d = os.path.dirname(d)
    sys.stderr.write('找不到 version.json，请在仓库内运行\n')
    sys.exit(1)


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def human(n: int) -> str:
    if n < 1024:
        return '%d B' % n
    if n < 1024 * 1024:
        return '%.1f KB' % (n / 1024)
    return '%.2f MB' % (n / 1024 / 1024)


def main() -> int:
    ap = argparse.ArgumentParser(description='发布 HAP 到 Release 并回填 version.json')
    ap.add_argument('hap', help='已签名的 HAP 文件路径')
    ap.add_argument('--tag', default='', help='Release tag，默认 v + version.json 的版本号')
    ap.add_argument('--notes', default='', help='追加到 Release 说明末尾的一行')
    ap.add_argument('--new', action='store_true', help='Release 不存在时新建')
    ap.add_argument('--dry-run', action='store_true', help='只改本地 version.json，不动远端')
    args = ap.parse_args()

    root = repo_root()
    hap = args.hap
    if not os.path.isabs(hap):
        hap = os.path.join(os.getcwd(), hap)
    if not os.path.exists(hap):
        sys.stderr.write('HAP 不存在: %s\n' % hap)
        return 1
    if not hap.endswith('.hap'):
        sys.stderr.write('警告：文件后缀不是 .hap，确认一下是不是签过名的产物\n')

    vpath = os.path.join(root, 'version.json')
    ver = json.load(open(vpath, encoding='utf-8'))
    tag = args.tag or ('v' + str(ver.get('version', '1.0.0')))

    size = os.path.getsize(hap)
    digest = sha256_of(hap)
    print('HAP   : %s' % hap)
    print('大小   : %s (%d 字节)' % (human(size), size))
    print('SHA256: %s' % digest)

    # ---- 1) 回填本地 version.json ----
    old = {
        'size': ver.get('size'),
        'sha256': ver.get('sha256'),
    }
    ver['size'] = size
    ver['sha256'] = digest
    ver['name'] = 'githup-hong ' + str(ver.get('version'))
    if not ver.get('published'):
        import time
        ver['published'] = time.strftime('%Y-%m-%d')
    json.dump(ver, open(vpath, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print('\n已回填 version.json：')
    print('  size   %s -> %s' % (old['size'], size))
    print('  sha256 %s -> %s' % ((old['sha256'] or '')[:12] + '…', digest[:12] + '…'))
    if old['sha256'] and old['sha256'] != digest:
        print('  ⚠️ 指纹变了，说明这确实是个新包（正常）')
    elif old['sha256'] == digest:
        print('  ⚠️ 指纹与上一版完全相同 —— 你上传的是不是同一个包？')

    if args.dry_run:
        print('\n--dry-run：到此为止，未访问远端')
        return 0

    token = os.environ.get('GITHUB_TOKEN', '').strip()
    if not token:
        sys.stderr.write('\n缺少 GITHUB_TOKEN 环境变量，无法上传。先改好 version.json 了，\n'
                         '配好令牌再跑一次即可：\n'
                         '  export GITHUB_TOKEN=ghp_xxx\n'
                         '  python3 tools/publish-hap.py <hap路径>\n')
        return 1

    S = requests.Session()
    S.headers.update({
        'Authorization': 'Bearer ' + token,
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'githup-hong-publisher'
    })

    # ---- 2) 找（或建）Release ----
    r = S.get('%s/repos/%s/%s/releases/tags/%s' % (API, OWNER, REPO, tag), timeout=60)
    if r.status_code == 200:
        rel = r.json()
        print('\nRelease 已存在: %s' % rel['html_url'])
    elif r.status_code == 404 and args.new:
        body = '## githup-hong %s\n\n%s' % (ver.get('version'), args.notes or 'HAP 发布')
        rr = S.post('%s/repos/%s/%s/releases' % (API, OWNER, REPO), timeout=60,
                    json={'tag_name': tag, 'name': 'githup-hong %s' % ver.get('version'),
                          'body': body, 'draft': False, 'prerelease': False})
        if rr.status_code >= 300:
            sys.stderr.write('建 Release 失败 %d: %s\n' % (rr.status_code, rr.text[:300]))
            return 1
        rel = rr.json()
        print('\n已新建 Release: %s' % rel['html_url'])
    else:
        sys.stderr.write('\nRelease %s 不存在（%d）。加 --new 会自动新建，'
                         '或先在网页上建好再跑。\n' % (tag, r.status_code))
        return 1

    # ---- 3) 上传附件 ----
    name = 'githup-hong-%s.hap' % ver.get('version')
    for a in rel.get('assets', []):
        if a['name'] == name:
            print('同名附件已存在，先删掉再传: %s' % name)
            S.delete('%s/repos/%s/%s/releases/assets/%d' % (API, OWNER, REPO, a['id']), timeout=60)

    up = rel['upload_url'].split('{')[0]
    with open(hap, 'rb') as f:
        u = S.post(up, params={'name': name},
                   headers={'Content-Type': 'application/octet-stream'},
                   data=f, timeout=600)
    if u.status_code >= 300:
        sys.stderr.write('上传失败 %d: %s\n' % (u.status_code, u.text[:300]))
        return 1
    asset = u.json()
    print('附件已上传: %s' % asset['browser_download_url'])

    # ---- 4) 回填 hap 直链 ----
    ver['hap'] = asset['browser_download_url']
    json.dump(ver, open(vpath, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
    print('version.json 的 hap 字段已指向: %s' % ver['hap'])

    if args.notes:
        S.patch('%s/repos/%s/%s/releases/%d' % (API, OWNER, REPO, rel['id']), timeout=60,
                json={'body': (rel.get('body') or '') + '\n\n' + args.notes})

    print('\n完成。下一步：把改动后的 version.json 提交推送')
    print('  git add version.json && git commit -m "发布 v%s" && git push'
          % ver.get('version'))
    return 0


if __name__ == '__main__':
    sys.exit(main())

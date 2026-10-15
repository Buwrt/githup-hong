/* 打包脚本：web 目录 + keystore 实现 + 服务端 → 单文件 bundle.js */
const fs = require('fs');
const path = require('path');

const SRC = '/data/workspace/githup-desktop';
const WEB = path.join(SRC, 'web');
const OUT = '/data/workspace/winbuild/bundle.js';

const SKIP = new Set(['.DS_Store']);

function walk(dir, base, out) {
  for (const name of fs.readdirSync(dir)) {
    if (SKIP.has(name)) continue;
    const full = path.join(dir, name);
    const rel = base ? base + '/' + name : name;
    if (fs.statSync(full).isDirectory()) walk(full, rel, out);
    else out.push({ rel, full });
  }
  return out;
}

const files = walk(WEB, "", []);
const map = {};
let raw = 0;
for (const f of files) {
  map[f.rel] = fs.readFileSync(f.full).toString('base64');
  raw += fs.statSync(f.full).size;
}

const keystore = fs.readFileSync('/data/workspace/winbuild/keystore-pure.js', 'utf8');
const core = fs.readFileSync('/data/workspace/winbuild/server-core.js', 'utf8');

const bundle = '/* 自动打包，勿手改：内嵌前端资源 + keystore 实现 + 服务端 */\n' +
  'globalThis.__GH_WEB_FILES__ = ' + JSON.stringify(map) + ';\n\n' +
  keystore + '\n\n' + core + '\n';

fs.writeFileSync(OUT, bundle);
console.log('内嵌文件 ' + files.length + ' 个，原始 ' + Math.round(raw / 1024) + ' KB');
console.log('bundle.js ' + Math.round(bundle.length / 1024) + ' KB');

/* 验证纯 Node 生成的 PKCS#12：openssl 与 keytool 都要能读 */
const crypto = require('crypto');
const fs = require('fs');
const { execFileSync } = require('child_process');

const src = fs.readFileSync('/data/workspace/winbuild/keystore-pure.js', 'utf8');
// 去掉注释里的 require 依赖冲突：直接在当前作用域 eval
const fn = new Function('crypto', src + '\nreturn buildPkcs12;');
const buildPkcs12 = fn(crypto);

const p12 = buildPkcs12('githup', 'testpass123');
fs.writeFileSync('/tmp/test.p12', p12);
console.log('生成 .p12：' + p12.length + ' 字节');

function tryCmd(name, args) {
  try {
    const out = execFileSync(name, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    console.log('  ✓ ' + name + ' 读取成功');
    console.log('    ' + out.split('\n').filter(Boolean).slice(0, 6).join('\n    '));
    return true;
  } catch (e) {
    console.log('  ✗ ' + name + ' 失败：' + String(e.stderr || e.message).split('\n').slice(0, 6).join(' | '));
    return false;
  }
}

console.log('\n[openssl]');
tryCmd('openssl', ['pkcs12', '-in', '/tmp/test.p12', '-passin', 'pass:testpass123', '-nokeys', '-info']);
console.log('\n[openssl 取私钥]');
tryCmd('openssl', ['pkcs12', '-in', '/tmp/test.p12', '-passin', 'pass:testpass123', '-nocerts', '-nodes']);

console.log('\n[keytool (Java 11)]');
tryCmd('keytool', ['-list', '-v', '-keystore', '/tmp/test.p12', '-storetype', 'PKCS12', '-storepass', 'testpass123']);

/* 给 exe 换图标 + 写版本信息（纯 JS，用 resedit 改 PE 资源）
 * 注意：必须在 postject 注入 blob 【之前】跑，改完再注入。 */
import fs from 'fs';
import { NtExecutable, NtExecutableResource, Resource, Data } from '/usr/local/lib/node_modules/resedit/dist/index.js';

const EXE = '/data/workspace/winbuild/node.exe';
const OUT = '/data/workspace/winbuild/githup-res.exe';
const ICO = '/data/workspace/winbuild/githup.ico';

const exe = NtExecutable.from(fs.readFileSync(EXE), { ignoreCert: true });
const res = NtExecutableResource.from(exe);

/* --- 图标 --- */
const iconFile = Data.IconFile.from(fs.readFileSync(ICO));
Resource.IconGroupEntry.replaceIconsForResource(
  res.entries,
  1,      // 图标组 ID
  1033,   // 英语（美国）
  iconFile.icons.map((i) => i.data)
);

/* --- 版本信息 --- */
let viList = Resource.VersionInfo.fromEntries(res.entries);
let vi = viList[0];
if (!vi) {
  vi = Resource.VersionInfo.createEmpty();
  vi.setFileVersion(1, 2, 15, 0);
  vi.setProductVersion(1, 2, 15, 0);
}
vi.setFileVersion(1, 2, 15, 0);
vi.setProductVersion(1, 2, 15, 0);
vi.setStringValues({ lang: 1033, codepage: 1200 }, {
  FileDescription: 'githup - GitHub client for desktop',
  FileVersion: '1.2.15',
  ProductName: 'githup',
  ProductVersion: '1.2.15',
  CompanyName: 'Buwrt',
  OriginalFilename: 'githup.exe',
  LegalCopyright: 'githup (third-party GitHub client)'
});
vi.setStringValues({ lang: 2052, codepage: 1200 }, {
  FileDescription: 'githup 桌面版 —— 电脑上的 GitHub 客户端',
  FileVersion: '1.2.15',
  ProductName: 'githup',
  ProductVersion: '1.2.15',
  CompanyName: 'Buwrt',
  OriginalFilename: 'githup.exe'
});
vi.outputToResourceEntries(res.entries);

res.outputResource(exe);
fs.writeFileSync(OUT, Buffer.from(exe.generate()));
console.log('已写入 ' + OUT + '（' + fs.statSync(OUT).size + ' 字节）');

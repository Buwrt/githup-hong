# 把 githup 桌面版打成 Windows exe

`githup.exe` 就是这么来的：**官方 Node 运行时 + 内嵌的前端与服务端代码**，用 Node 官方的单文件可执行（SEA）机制合成。没有 Electron，没有第三方依赖，也不需要在用户电脑上安装 Node。

## 一步一步

前置：Node 18+（构建机用，用户电脑上不需要）。

```bash
# 1. 把前端、keystore 实现、服务端内核拼成一个 JS 文件
node build-bundle.js          # → bundle.js（约 2.8 MB，前端资源已 base64 内嵌）

# 2. 生成 SEA 的 blob
node --experimental-sea-config sea-config.json    # → sea-prep.blob

# 3. 下一个官方 Windows 版 node.exe（版本要与构建机一致）
#    https://nodejs.org/dist/v20.19.5/win-x64/node.exe

# 4. 把 blob 注入进 node.exe
npx postject node.exe NODE_SEA_BLOB sea-prep.blob \
  --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2

# 5. 改名
mv node.exe githup.exe
```

双击 `githup.exe` 即可：起本地服务 → 自动开浏览器 → `http://127.0.0.1:8733/`。关掉那个黑窗口就退出。

## 几个文件分别是干什么的

| 文件 | 作用 |
|---|---|
| `server-core.js` | 服务端内核。与 `../server.js` 是同一份逻辑，区别在于能读内嵌资源、数据目录可回退、控制台只输出 ASCII |
| `keystore-pure.js` | 纯 Node 实现的 PKCS#12 生成（RSA 2048 + 自签 X.509 + RFC 7292 MAC），**不依赖 openssl** —— Windows 上生成签名库全靠它 |
| `build-bundle.js` | 把 `web/` 整个目录 base64 后塞进一个 JS 文件 |
| `sea-config.json` | SEA 配置 |
| `verify-keystore.js` | 验证生成的 .p12：openssl 与 keytool 都要能读 |
| `set-icon.mjs` | 换图标 + 写版本信息（**当前构建没用**，见下） |

## 关于 set-icon.mjs（以及为什么最终没用它）

这个脚本用 resedit 改 PE 资源，能给 exe 换成 githup 的图标并写上版本号。但 resedit 重写 PE 之后，postject 再读这个二进制会报一句 `Relocation corrupted`——exe 是否还能在 Windows 上正常启动无法在本机验证（构建环境是 Linux），所以最终采用了**不改官方 node.exe、只注入 blob** 的方案：体积一样，代价是图标还是 Node 的那个。

如果你在 Windows 上构建，可以放心用它（构建完自己双击试一下就行）：

```bash
npm i -g resedit
node set-icon.mjs      # node.exe → githup-res.exe（已换图标）
# 然后再执行上面的第 4 步注入
```

## 关于体积

exe 约 71 MB —— 它就是一个完整的 Node 运行时，前端与服务端代码加起来才 2.8 MB。这是 SEA 方案的固有代价，换来的是零依赖、不用装 Node、双击就跑。

## 已知提示

- 首次运行时 Windows 防火墙可能询问是否允许监听本地端口，选**允许**（只监听 127.0.0.1，局域网里其它机器连不上）。
- 没有代码签名，SmartScreen 可能提示"未知发布者"，选"仍要运行"。
- 少数杀软对 Node SEA 打出的 exe 有误报，需要加白名单。

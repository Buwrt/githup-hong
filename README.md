# githup 桌面版

把 [githup](https://github.com/Buwrt/githup)（Android 版 GitHub 客户端）原样搬到电脑上用。

**没有重写界面**——`web/` 目录里的每一个文件都与 Android 版 `app/src/main/assets/web/` 逐字节相同。桌面版做的事情只有两件：

1. 起一个只监听 `127.0.0.1` 的本地服务，托管这些前端文件；
2. 在浏览器里把 Android 版 `JsBridge` 那 60 多个原生方法重新实现一遍（`web/js/desktop-bridge.js`），前端代码一行都不用改。

额外补了一份宽屏样式（`web/css/desktop.css`）：底栏变成左侧栏，内容区限宽居中，弹层收成对话框。桌面脚本与样式由服务端在返回页面时注入，所以上游一更新，把 `web/` 覆盖过来就能用。

---

## 怎么跑

**Windows 用户：直接用 `githup.exe`（见 `build-exe/`），双击就跑，不用装 Node。**

其它系统，或者你想直接看源码跑：电脑装 **Node.js 18 或更高版本**（[nodejs.org](https://nodejs.org)）。

- **Windows**：双击 `启动-githup.bat`
- **macOS / Linux**：终端里 `./启动-githup.sh`，或直接 `node server.js`

服务起来后会自动打开浏览器，地址 `http://127.0.0.1:8733/`。端口被占用时会自动换一个，看窗口里的提示。

停止使用：在服务窗口按 `Ctrl+C`。

### exe 版

`build-exe/` 目录里是把这套东西打成单个 `githup.exe` 的全部脚本（Node 官方单文件可执行机制，不含 Electron）。exe 约 71 MB——它本身就是一个完整的 Node 运行时，好处是**用户电脑上什么都不用装**。构建步骤见 `build-exe/README.md`。

---

## 功能支持情况

| 功能 | 桌面版 | 说明 |
|---|---|---|
| 登录 / 令牌、浏览仓库、搜索、通知 | ✅ | 经本地服务转发 GitHub API |
| README / Issue / PR 渲染、图片 | ✅ | 图片走 base64 通道 |
| 阅读 Markdown、代码高亮 | ✅ | 与 Android 版一致 |
| 翻译 | ✅ | 引擎配置同样在本机保存 |
| 两步验证器（TOTP） | ✅ | 密钥加密存在本地，断网可用 |
| 上传文件 / 图片 / 文件夹 | ✅ | 用系统文件选择器 |
| 下载 Release 附件、Actions 产物 | ✅ | 存到 `downloads/` 目录 |
| 云端打包 APK（keystore 生成） | ✅ | 调用本机 openssl |
| 扫一扫二维码 | ✅ | 浏览器摄像头权限（localhost 属安全上下文） |
| 后台通知轮询 | ❌ | 关掉页面就停，桌面版不做常驻 |
| 通知栏常驻动态码 | ❌ | 页面上直接看码 |
| 安装 APK | ❌ | 桌面版只把包取回来存到 `downloads/apk/` |
| 多下载通道测速 | ❌ | 桌面只有直连一条路，不给假数据 |

---

## 目录

```
server.js              本地服务（零第三方依赖，只用 Node 内置模块）
web/                   与 Android 版完全一致的前端
web/js/desktop-bridge.js   ← 桌面版新增：原生层的浏览器实现
web/css/desktop.css        ← 桌面版新增：宽屏适配
启动-githup.bat / .sh  启动脚本
data/                  令牌、设置、两步验证密钥（加密存放）
downloads/             下载目录
logs/                  运行日志
```

---

## 关于安全

- 服务**只监听 `127.0.0.1`**，局域网里的其它机器连不上；非本机的 `Origin` 一律拒绝。
- 令牌与两步验证根密钥存在 `data/store.enc`，用本机生成的随机密钥做 **AES-256-GCM** 加密。它挡得住「随手翻开文件就看到明文」，挡不住已经能读你用户目录的人——桌面端没有 Android Keystore 那种硬件背书，这点如实说明。
- 两步验证的密钥**不会**写进浏览器 localStorage。Android 版的 `Store` 是「原生 + localStorage 双写」，桌面版接管了这一层，敏感键只走加密存储。
- 转发请求时会挡掉环回地址与私有网段，避免本地服务被当成打内网的跳板。
- 重定向逐跳复检目标地址，跨域跳转时不外带 `Authorization`。
- 想彻底退出：关掉服务窗口即可，令牌不会留在浏览器里。

---

## 快捷键

| 键 | 作用 |
|---|---|
| `1`–`5` | 切换首页 / 通知 / 探索 / 搜索 / 我的 |
| `Ctrl`/`Cmd + K` | 跳到搜索 |
| `Esc` | 返回上一页 |

---

## 打包成 exe

见 `build-exe/README.md`。要点：用 Node 官方的 SEA（单文件可执行）把前端与服务端塞进官方 node.exe，产出单个 `githup.exe`，71 MB，双击即用，不需要 Electron，也不需要用户装 Node。

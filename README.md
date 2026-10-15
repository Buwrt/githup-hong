# githup-hong

githup 的**纯血鸿蒙（HarmonyOS NEXT）**版本：ArkTS + ArkWeb 重写原生层，
前端 25,195 行 JS **一行未改**原样复用。

上游 Android 版：[Buwrt/githup](https://github.com/Buwrt/githup)（v1.2.15）

---

## 它是什么

一个把 GitHub 装进手机的第三方客户端。原生层只做四件事：网络、存储、
文件、通知；界面、路由、业务逻辑全在那 2.5 万行前端 JS 里。

鸿蒙版的关键做法是**不重写前端**：用 `Web` 组件加载 rawfile 里的
`web/index.html`，再通过 `javaScriptProxy` 把 `NativeBridge` 注入 `window`，
方法名与参数顺序和 Android 版 `JsBridge.java` 逐一对齐，前端无感知。

| 层 | Android 版 | 鸿蒙版 |
|---|---|---|
| 原生 | Java 15,569 行 / 24 文件 | ArkTS 约 1,800 行 / 8 文件 |
| 前端 | `assets/web` | `rawfile/web`（**逐文件一致**） |
| 第三方依赖 | 0 | 0 |

---

## ⚠️ 当前状态：未经编译验证（重要）

本工程由源码移植生成，**没有经过 DevEco Studio 编译**。原因是构建环境
不可得：HarmonyOS 的 SDK 与 hvigor 都在华为私有源
（`repo.harmonyos.com`，匿名访问返回 403），无法在 CI 或沙盒里获取。

请在 DevEco Studio 里打开后按下面的步骤走一遍，预期需要修少量 ArkTS
类型与 API 细节。所有模块都写了详细注释说明它与 Android 版的对应关系，
改起来有据可依。

---

## 目录结构

```
entry/src/main/ets/
├── entryability/EntryAbility.ets   入口：加载页面、接收外部 GitHub 链接
├── pages/Index.ets                 全屏 ArkWeb + javaScriptProxy 注册
└── bridge/
    ├── NativeBridge.ets            桥接总入口（对齐 JsBridge.java）
    ├── GhHttp.ets                  网络层（对齐 Http.java）
    ├── SecureStore.ets             令牌加密存储（对齐 SecurePrefs.java）
    ├── TotpEngine.ets              动态码算法（对齐 Totp.java）
    ├── TotpNotify.ets              常驻动态码通知（对齐 TotpService.java）
    ├── NotifWatch.ets              GitHub 通知轮询（对齐 NotifWatchReceiver.java）
    └── DownloadChannels.ets        下载加速镜像（对齐 DownloadChannels.java）
```

---

## 已移植 / 未移植

### 已移植

| 能力 | 说明 |
|---|---|
| 网络栈 | 系统 `@kit.NetworkKit`，重定向时**跨域自动剥离 Authorization** |
| 令牌存储 | AES-256-GCM，对齐 `SecurePrefs.java` |
| 文件选择与上传 | `picker` + `@kit.CoreFileKit` |
| 剪贴板、震动、安全区 | 全部对齐 |
| 错误日志 | 只记当天，存应用私有目录 |
| **两步验证器** | TOTP/HOTP 算法 + 常驻通知刷新 |
| **下载加速镜像** | 18 条通道，镜像在前直连兜底 |
| **GitHub 通知轮询** | 15 分钟一轮，未读汇总成一条通知 |
| 深色模式 / 状态栏 | 透明状态栏，前端自己管主题 |

### 未移植（及原因）

| Android 版能力 | 为什么没移植 |
|---|---|
| 五环防护链 / 签名自校验 | 依赖 `PackageManager` 的重签名检测在鸿蒙上没有等价物；鸿蒙由**系统在安装时**校验 HAP 签名，运行时只能核对 bundleName 与签名指纹（`certSha256()`） |
| 断点续传 / 多线程下载 | 首版走 `requestB64` 全量读，够用但大文件体验一般；可换 `@kit.RequestKit` |
| 限速通道 / 劝 Star | 那是 Android 版的产品决策（没点 Star 就限速），鸿蒙版不沿用 |
| APK 安装 / 自动更新 | 鸿蒙没有 APK；`installApkChecked` 改为引导到本仓库 Release 页 |
| 本地生成签名密钥 | 手机上给 APK 签名在鸿蒙上没有对应场景 |
| 选文件夹 | ArkTS 的 `picker` 不提供目录选择 |

### 已知限制

- **通知轮询在进程被杀后不会自动恢复**：Android 靠 AlarmManager 定点唤醒，
  鸿蒙最接近的是 `WorkSchedulerExtensionAbility`，但它不保证精确时刻。
  首版采用「前台 setInterval + 退后台短时任务续命」两段式，
  补 ExtensionAbility 的要点写在 `NotifWatch.ets` 文件末尾。
- **长时任务会在通知栏显示系统级的「正在运行」提示**，这是系统规定，
  无法隐藏；关掉动态码开关会同时撤掉它。
- `uploadMultipart` 退化为单体 PUT（拼 multipart boundary 未实现），
  覆盖「上传 Release 附件 / 传文件到仓库」两条主干路径。

---

## 编译与签名（必须在本机 DevEco Studio 完成）

HAP 签名必须用**你自己的华为开发者账号证书**，这一步别人替不了。

### 1. 准备环境

- DevEco Studio（支持 API 12 / HarmonyOS 5.0）
- 华为开发者账号：AppGallery Connect → 用户与访问 → 证书管理
- 在 AGC 建一个应用，**包名必须是 `com.hubmobile.hong`**（与
  `AppScope/app.json5` 的 `bundleName` 一致，不一致签名会失败）

### 2. 生成签名材料

在 AGC 下载（或本地生成 CSR 后申请）三样东西：

| 文件 | 用途 |
|---|---|
| `.p12` | 密钥库（含私钥） |
| `.cer` | 证书 |
| `.p7b` | Profile 文件（绑定包名与设备） |

### 3. 配置签名

DevEco Studio → **File → Project Structure → Signing Configs**，
勾选 `Automatically generate signature` 走自动签名（需登录华为账号），
或手动填：

```
Store File:      <你的>.p12
Store Password:  <密钥库口令>
Key Alias:       <别名>
Key Password:    <密钥口令>
Sign Alg:        SHA256withECDSA
Profile File:    <你的>.p7b
Certpath File:   <你的>.cer
```

### 4. 出包

```
Build → Build Hap(s)/APP(s) → Build Hap(s)
```

产物路径：

```
entry/build/default/outputs/default/entry-default-signed.hap
```

### 5. 发布

1. 把这个 HAP 作为 Release 附件上传；
2. 回填仓库根目录 `version.json` 的 `hap` / `size` / `sha256` 三个字段；
3. `sha256` 用 `sha256sum entry-default-signed.hap` 取。

> `.gitignore` 已排除 `*.hap` / `*.p12` / `*.cer` / `*.p7b`——
> **签名材料绝不能进仓库**。

---

## 前端怎么保持同步

前端文件在 `entry/src/main/resources/rawfile/web/`，与上游
`app/src/main/assets/web/` 逐文件一致。上游更新时同步方式：

```bash
cp -r <githup>/app/src/main/assets/web/* \
      <githup-hong>/entry/src/main/resources/rawfile/web/
```

同步后如果上游新增了 `NativeBridge.xxx` 调用，需要：
1. 在 `NativeBridge.ets` 实现同名方法；
2. 把方法名加进 `Index.ets` 的 `SYNC_METHODS`（有返回值）
   或 `ASYNC_METHODS`（无返回值、用 `runJavaScript` 回吐）。

---

## 隐私相关

- 令牌：AES-256-GCM 加密后存应用私有目录，鸿蒙应用沙箱本身隔离。
- **翻译功能会把页面正文发给第三方引擎**（有道 / 百度 / DeepL / Google /
  MyMemory / 小牛），默认自动挑最快的那个。私有仓库慎用整页翻译。
- 下载走第三方镜像时**不转发 Authorization**，但 URL 会送到镜像服务器。
- 两步验证密钥：磁盘上明文存（与上游 Android 版一致）。

## License

Apache-2.0（与上游一致）

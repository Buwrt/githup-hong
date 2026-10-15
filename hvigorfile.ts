import { appTasks } from '@ohos/hvigor-ohos-plugin';

/*
 * 工程级 hvigor 配置。
 *
 * 之前这个文件漏了 —— 仓库里只有 entry/hvigorfile.ts（模块级）,
 * 没有工程级这一份，hvigor 一启动就报
 *   "Hvigorfile not found: <工程根>/hvigorfile.ts/js"
 * 本地用 DevEco Studio 打开同样会失败，所以在 CI 第一次构建时就暴露出来了。
 */
export default {
  system: appTasks,
  plugins: []
}

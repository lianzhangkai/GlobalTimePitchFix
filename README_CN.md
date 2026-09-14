# GlobalTimePitchFix 0.2.6 — 注入探针版

这个版本**不修改音质，也不修改倍速算法**。唯一目的：确认 Odyssey/libhooker 是否真的把 tweak 注入到目标进程。

安装 + Respring 后：

1. 打开 B 站：约 2 秒后应弹出“哔哩哔哩主进程已成功加载”。
2. 打开 Safari：约 2 秒后应弹出“Safari 主进程已成功加载”。
3. Safari 点 OK 后打开或刷新任意网页。如果 WebKit WebContent 也被注入，应再弹一次“Safari WebContent 已成功加载”。

## 如何解释结果

- B站、Safari主进程、WebContent 三个提示都有：注入链路没问题，下一步查真正的倍速音频路径。
- B站和Safari主进程有，WebContent没有：libhooker 网页注入仍未生效或 Filter 没命中 WebContent。
- 三个都没有：dylib 没被 libhooker 正常加载，需要查 tweak 架构/ABI/loader。
- 只有其中一个 App 有：继续查对应 Bundle/进程过滤。

这个版本测试完就应换掉，不适合作为日常插件。


## 0.2.6 修正
- 修复 iOS 13.7 SDK + `-Werror` 下 `UIAlertView` 已废弃导致的编译失败。
- 改用 `UIAlertController`，探针逻辑不变。

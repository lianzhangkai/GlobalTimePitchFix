# GlobalTimePitchFix 0.5.0 — B站 Sonic 原型

这是实验版，只注入 `tv.danmaku.bilianime`。

目标：彻底绕开 Apple AudioQueue 的 TimePitch。B站仍然把真实倍速（1.5/2/3x）交给 ijkplayer 上层；但 IJKSDLAudioQueueController 的硬件播放速率被固定为 1.0x。PCM 在送入 AudioQueue 前由 Sonic 处理。

- 1.0x：完全 bypass，原始 PCM 直接输出。
- >1.0x：Sonic `speed = 用户倍速`，`pitch = 1.0`，`rate = 1.0`。
- 切倍速/拖动进度条：清空 Sonic 内部状态，避免旧缓冲拖尾。
- 长按 3x：同一条路径处理。

Sonic 是专门为高速语音设计的算法，官方文档明确强调 2x 以上的语音速度，并支持最高远高于 3x。Sonic 使用 Apache-2.0 许可证；GitHub Actions 在构建时从官方 `waywardgeek/sonic` 仓库获取 `sonic.c` / `sonic.h`。

## 测试顺序

1. 先播放 1x 30 秒：必须声音正常、不卡顿。
2. 切 1.5x：听人声并观察音画同步。
3. 切 2x：和小米 14 Ultra 同一视频对比。
4. 长按 3x 10~20 秒，再松手回 1x：重点看是否爆音、断音、严重不同步。
5. 拖动进度条再测试 2x/3x。

如果出现闪退、无声或严重不同步，请先卸载本 tweak 或降回之前版本；这是 PCM 链路原型，不建议长时间留用，确认表现后再迭代。

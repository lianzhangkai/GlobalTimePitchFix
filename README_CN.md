# GlobalTimePitchFix 0.6.1 - Bilibili SoundTouch Speech Prototype

目的：在 iPadOS 13.7 的旧版 Bilibili iOS 客户端中，彻底绕过 Apple AudioQueue TimePitch，改用 Bilibili 自己曾为 Android ijkplayer 集成的 SoundTouch 1.9.2（WSOLA-like）进行倍速音频处理。

## 设计
- 1.0x：PCM 原样直通，不经过 SoundTouch。
- >1.0x：SoundTouch 只修改 tempo，pitch=1.0、rate=1.0。
- Apple AudioQueue 始终被固定在 1.0x，因此 Apple Spectral/TimeDomain 不参与倍速。
- QuickSeek 关闭。
- 使用 float 内部处理。
- 针对高速人声使用比音乐默认值更短的 sequence / seek window：
  - <1.9x: 35 / 15 / 8 ms
  - 1.9–2.49x: 25 / 12 / 6 ms
  - >=2.5x: 18 / 8 / 5 ms

这些参数是实验性的，后续根据 2x/3x A/B 结果继续调。

## 测试顺序
1. 1x 是否完全正常
2. 2x 与 Xiaomi 14 Ultra 同视频 A/B
3. 长按 3x 10–20 秒
4. 3x 松手回 1x 是否立即恢复
5. 是否有断音、延迟、音画不同步、闪退

## 许可证
SoundTouch 来自 https://github.com/bilibili/soundtouch ，LGPL-2.1-or-later。GitHub Actions 构建时从该仓库获取源码，本项目仅用于个人设备实验。


## 0.6.1 编译修复
- 修复旧 clang 10 + `-Werror` 下 Bilibili SoundTouch `TDStretch.cpp` 的 `_scanOffsets` 未使用常量警告。
- 仅对 `-Wunused-const-variable` 降级，不关闭其它 `-Werror`，避免掩盖真正的编译错误。
- DSP / SoundTouch 参数与 0.6.0 完全相同。

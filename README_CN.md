# GlobalTimePitchFix 0.3.1 — Audio Path Probe

这是 0.3.0 的编译修正版。0.3.0 使用 Logos `%hookf` 探测 C 音频函数，在当前 old-ABI 构建链的 Logos 预处理阶段会报 `missing closing parenthesis`。0.3.1 改为 `MSHookFunction`，探测目标不变。

本版本只做诊断，不修改音质、速度或音高。

# GlobalTimePitchFix 0.3.0 — Audio Path Probe

这是诊断版，不改善音质，也不会强制改播放速度/音高。

目的：在 iPadOS 13.7 + Odyssey/libhooker 上确认 Safari WebContent 和 Bilibili 在切换 1×→2× 时，实际调用了哪条音频倍速路径。

## 测试方法

1. 覆盖安装 0.3.0 deb。
2. Respring。
3. 打开 Bilibili，播放一个人声视频：先 1×，再切 2×，记录所有 GTPF Audio Path Probe 弹窗的“命中”名称。
4. 打开 Safari，播放同类视频：先 1×，再切 2×。WebContent 里的命中会转发到 Safari 主进程弹窗。
5. 把出现过的命中名称告诉 ChatGPT；没出现也要说明“0 个命中”。

重点关注：
- AVPlayer_setRate
- AVPlayerItem_setAudioTimePitchAlgorithm
- AVSampleBufferAudioRenderer_setAudioTimePitchAlgorithm
- AVAudioUnitTimePitch_setRate
- AudioQueue_PlayRate
- AudioUnit_NewTimePitch_Rate / Varispeed

这个版本只做观察，不改变音质。

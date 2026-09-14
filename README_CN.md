# GlobalTimePitchFix 0.4.0 - B站 AudioQueue Spectral 修复版

只注入 `tv.danmaku.bilianime`。

已确认这版旧 B站使用：
- `IJKFFMoviePlayerController`
- `IJKSDLAudioQueueController`
- `setPlaybackRate:`

公开 ijkplayer 的 iOS AudioQueue 实现里，创建 AudioQueue 后正确对局部变量 `audioQueueRef` 开启了 TimePitch，
但随后却在 `_audioQueueRef` 尚未赋值时尝试设置 `TimePitchBypass` 和 `TimePitchAlgorithm=Spectral`。
等到 `_audioQueueRef` 真正赋值后，原实现没有再次设置算法。

本 tweak 在 `_audioQueueRef` 已经有效之后重新设置：
- EnableTimePitch = 1
- TimePitchAlgorithm = Spectral

并在每次 `setPlaybackRate:` 前再次确认 Spectral。

这版不注入 Safari，也没有弹窗探针。

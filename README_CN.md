# GlobalTimePitchFix 0.3.3 - Bilibili IJK Probe

这是 B站专用安全探针，不再 hook AVPlayer / AVPlayerItem / AVSampleBufferAudioRenderer，也不碰 AudioUnit/AudioQueue C 函数。

目的：确认旧版 Bilibili 是否使用 ijkplayer 的 `setPlaybackRate:` 路径。

安装后：
1. Respring。
2. 打开 B站，应先出现启动检测摘要。
3. 打开一个视频，先 1×，再切 2×。
4. 记录弹窗命中的类和 rate。

如果启动检测中 IJKFFMoviePlayerController 或 IJKSDLAudioQueueController 显示“是”，且切倍速时出现对应命中，后续就可以直接针对 ijkplayer 的倍速链路处理。

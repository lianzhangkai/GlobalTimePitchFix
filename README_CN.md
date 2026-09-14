# GlobalTimePitchFix 0.3.2 Safe Audio Path Probe

这是诊断版，不修改音质或音调。

相对 0.3.1：
- 删除 AudioQueueSetParameter / AudioUnitSetParameter 的低层 C 函数 hook。
- 删除 AVAudioUnitTimePitch / AVAudioUnitVarispeed 探针。
- 原因：旧版 Bilibili 可能在实时音频线程调用这些接口，探针在该线程分配 Objective-C 对象可能导致闪退。
- 保留 AVPlayer、AVPlayerItem、AVSampleBufferAudioRenderer 三条更安全的路径。
- Safari WebContent 会把实际设置的算法名编码进弹窗，例如 Spectral / TimeDomain / LowQualityZeroLatency / Varispeed。

测试：
1. 覆盖安装 0.3.1，Respring。
2. Safari 播放视频，1× -> 2×，记录弹窗完整文字。
3. Bilibili 播放视频，1× -> 2×，记录弹窗；确认是否还闪退。

# APlayer Audio Probe 0.8.2

本版修复 iOS 13.7 SDK 链接错误：`ld: framework not found AudioUnit`。

iOS 13.7 这里不应单独链接 `AudioUnit.framework`；探针使用到的 Audio Unit C API 由 `AudioToolbox.framework` 提供/导出，因此 Makefile 保留 `AudioToolbox`，移除 `AudioUnit`。

其余探测逻辑与 0.8.1 相同。

# APlayer Audio Probe 0.8.1

修复 iOS 13.7 SDK 下 `kAudioUnitSubType_TimePitch` 未声明导致的编译失败。探针功能不变；AudioUnit 部分检测 `NewTimePitch` 与 `Varispeed`。

# APlayer Audio Path Probe 0.8.0

用途：**只诊断，不修改声音**。目标是确认 APlayer 在 iPadOS 13.7 上 1x / 2x / 3x 倍速时使用的播放器内核、音频输出 API 和 time-stretch 算法。

目标 Bundle ID：`com.alookbrowser.player`。

会记录：
- AVPlayer / AVPlayerItem / AVSampleBufferAudioRenderer 的倍速与 TimePitch 设置
- AVAudioUnitTimePitch / AVAudioUnitVarispeed
- AudioQueue 的 TimePitch / PlayRate 参数
- AudioUnit NewTimePitch / Varispeed 的参数
- APlayer 加载的非系统 Framework / dylib
- App 内部可疑播放器/音频类（FFmpeg、IJK、VLC、SoundTouch、Sonic 等）
- 主程序与 App Bundle 内 Mach-O/Framework 中的关键字：SoundTouch、TDStretch、Sonic、RubberBand、FFmpeg、libavcodec、libavfilter、atempo、VLC、IJK 等

## 编译

使用仓库内 `.github/workflows/build.yml`，和之前一样通过 GitHub Actions 编译 old-arm64e / iOS 13.7 版本。

## 实机测试

1. 安装 deb，Respring。
2. 后台彻底划掉 APlayer，再重新打开。
3. 打开同一个已确认倍速音质很好的本地视频。
4. 按顺序播放：`1x 5秒 -> 2x 10秒 -> 3x 10秒 -> 1x 5秒`。
5. 完全退出 APlayer。
6. Filza -> 应用管理器 -> APlayer -> Documents -> 找 `APlayerAudioProbe.log`。
7. 把日志文件发回分析。

这个版本不会修改音频参数，不会把 PCM 写盘，也不会在高频 audio callback 里弹窗。

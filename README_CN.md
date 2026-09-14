# GlobalTimePitchFix 0.1 测试版

目标设备：A12X iPad Pro / iPadOS 13.7 / Odyssey(libhooker) / rootful。

第一版只注入：
- Safari：com.apple.mobilesafari
- 哔哩哔哩：tv.danmaku.bilianime

作用：当 AVFoundation 使用 iOS 13 默认的 LowQualityZeroLatency 倍速算法时，改为 Spectral。

## 非常重要：A12X + iOS 13.7 的编译要求

iOS 12.0–13.7 的 arm64e 使用旧 ABI。现代 Clang/Xcode 12+ 编出来的 arm64e dylib不能直接用于这个系统。
必须使用能生成旧 arm64e ABI 的工具链（典型方案：Xcode 11.7，或 clang 10 的旧 arm64e iOS toolchain）。

## 编译

准备好兼容旧 ABI 的 Theos 工具链与 iPhoneOS13.7.sdk 后：

    cd GlobalTimePitchFix
    make clean package FINALPACKAGE=1

生成的 deb 位于 packages/。

## 安装后测试

1. 安装 deb。
2. 彻底划掉 Safari 和 B站后台。
3. 重新打开。
4. 同一段视频对比 1x / 1.5x / 2x。
5. 如果 2x 人声明显更清楚，说明命中正确链路。

如果纯人声出现“机器人/金属感”，把 Tweak.xm 中：

    AVAudioTimePitchAlgorithmSpectral

改为：

    AVAudioTimePitchAlgorithmTimeDomain

重新编译即可。

## 卸载

在 Sileo 中卸载 GlobalTimePitchFix，然后彻底退出 Safari/B站再打开。没有修改任何系统文件。

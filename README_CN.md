# GlobalTimePitchFix 0.2.0 Varispeed 验证版

这是**诊断版，不是日常使用版**。

目的只有一个：确认 tweak 是否真正命中 Safari / WebKit / B站的倍速音频处理路径。

## 预期现象

安装并 Respring 后：

- 1.0x：音高应基本正常。
- 1.5x：人声明显变尖。
- 2.0x：人声会出现非常明显的“松鼠音/升调”，大致接近提高一个八度。

如果 2.0x 仍然保持正常音高，那么当前 AVFoundation hook 并没有控制到最终的 time-stretch 路径。

## 测试范围

- Safari 主进程
- `com.apple.WebKit.WebContent`
- 哔哩哔哩 `tv.danmaku.bilianime`

## 注意

测试结束后不要长期保留此版本。确认结果后应换回 0.1.1 或后续 TimeDomain 版本。

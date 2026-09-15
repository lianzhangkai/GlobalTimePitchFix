# GlobalTimePitchFix 0.8.0 — 日用版

这是基于 **0.7.3** 的收敛版本。核心目标不是继续追求最后一点音质，而是保留已经验证可用的 2x/3x 音质和切换策略，把日常使用中更容易遇到的边界场景补齐。

## 保留不变的核心

- B站 `IJKSDLAudioQueueController` 的原始 PCM callback 仍只在 AudioQueue callback 线程调用。
- VLC-style `scaletempo` 仍在独立 worker 线程执行。
- 两个 SPSC PCM ring 负责 source / processed PCM 解耦。
- **1x 仍是原始 PCM 精确旁路**，不进 DSP。
- 2x/3x 的稳态算法和参数不改：
  - stride: 30 ms
  - overlap: 20%
  - search: 14 ms
- 1x -> 2x/3x 继续使用 0.7.3 的 bridge 预热。
- 2x/3x -> 1x 继续使用短 drain 后再回原始 1x。
- 2x <-> 3x 不 reset DSP。

## 0.8.0 新增的日用稳定性处理

### 1. 快速长按/松开取消
如果刚触发 3x、DSP 还没真正输出到声卡就马上松手，0.8.0 会直接取消这次尚未生效的 DSP 进入，不再强行走 drain。

这主要减少“非常短的 3x 长按”出现一下小顿挫的概率。

### 2. 拖动进度条 / seek / flush 后重新平滑预热
0.7.3 在 `flush` 后虽然会 reset DSP，但如果当时仍保持 2x/3x，下一次 AudioQueue callback 可能面对一个刚清空的 DSP。

0.8.0 将 seek/flush 视为真正的时间线跳变：

1. 先让 ijk 完成自己的 flush；
2. 丢弃旧 source/output ring；
3. 如果目标还是 2x/3x，则重新走一次正常的 bridge 预热；
4. 如果目标是 1x，则直接恢复原始旁路。

因此拖进度条后继续 2x/3x 的稳定性会更好。

### 3. stop + close 双生命周期保护
旧版只 hook `stop`。0.8.0 同时处理 `close`，无论播放器走哪条销毁路径，都会通知 DSP worker 退出。

为了兼容老 ijk / AudioQueue 可能存在的异步回调，本版仍采用保守策略：**不在 close/stop 当场 free callback context**，避免 use-after-free。进程退出后由系统统一回收。

### 4. 轻量 underrun 计数
保留平滑补帧，同时记录连续 underrun callback，为后续诊断保留状态；本版不因为偶发 underrun 自动改变算法或降级，避免日用版引入新的行为变化。

## 推荐验证场景

重点测这些即可：

```
1x -> 2x -> 1x
1x -> 长按3x -> 松手1x
2x -> 长按3x -> 松手2x
连续快速长按/松开3x
2x/3x 播放时拖动进度条
暂停几秒 -> 继续
切换下一个视频
退到后台 -> 回来继续
```

目标是：稳态音质保持 0.7.3 水平，同时没有新的持续噼啪、重复音、明显吞字或音画失步。

## 说明

0.5x / 0.75x 没有专项优化。这个项目当前优先保障 1x / 2x / 3x 的实际使用体验。

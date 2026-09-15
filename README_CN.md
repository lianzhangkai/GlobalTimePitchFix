# GlobalTimePitchFix 0.7.3 — VLC ScaleTempo Smooth Switch

基于 0.7.2 的稳定 Worker DSP 架构，只优化“切换倍速时小卡一下”，不改 2x/3x 的稳态算法和 VLC 默认参数。

## 0.7.3 的切换策略

- **1x -> 2x/3x**：先播放一个正常 1x AudioQueue buffer 作为 bridge，同时预取后续 PCM 给后台 scaletempo；下一 buffer 再进入 DSP。这样不再要求第一次倍速 callback 当场等 DSP 从空状态产出。代价是倍速生效最多延后一帧音频 buffer，但听感应更连续。
- **2x/3x -> 1x**：不再立刻清空已经预取的 DSP 音频。先停止继续预取，最多用 1~3 个 callback 把前置缓存 drain 掉，再切回原始 1x PCM，并做短过渡。这样减少“decoder 已经跑到前面、直接丢缓存造成的小跳”。
- **2x <-> 3x**：仍然不 reset DSP，只更新 speed，保持 0.7.2 的连续性。
- **稳态 2x/3x**：代码路径、scaletempo 参数与 0.7.2 相同。

## 参数

- stride: 30 ms
- overlap: 20%
- search: 14 ms

## 测试重点

建议主要测试你常用的：

```
1x -> 2x -> 1x
1x -> 长按3x -> 松开1x
2x -> 3x -> 2x
```

关注：
1. 进入 2x/3x 时“小卡一下”是否明显减轻；
2. 松开 3x 回 1x 时是否更顺；
3. 2x/3x 稳态音质不能比 0.7.2 下降；
4. 是否出现新的重复音、吞字、明显 A/V 不同步。

如果 0.7.3 引入重复音或回 1x 延迟太明显，请直接回退 0.7.2。

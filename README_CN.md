# GlobalTimePitchFix 0.7.2 — VLC ScaleTempo Worker DSP

这是针对 0.7.0/0.7.1 在 0.5x / 2x / 3x 持续爆音、回到 1x 后仍噼啪的架构修正版。

## 这版和 0.7.1 最大的区别

0.7.1 把 VLC-style `scaletempo` 的相关性搜索直接放在 AudioQueue 实时 callback 内执行。即使算法本身离线输出正常，只要 callback 偶发超时，就可能造成 AudioQueue underrun，表现为连续爆音/噼啪，而且队列一旦被打乱，回 1x 也可能继续异常。

0.7.2 改为：

```
AudioQueue callback
  ├─ 仍然在原线程调用 ijk 原始 PCM callback（保持原有线程语义）
  ├─ 把源 S16 PCM 写入 source ring
  └─ 只从 output ring 取已经处理好的 S16 PCM

worker thread
  ├─ source ring -> Float32
  ├─ VLC-style scaletempo
  ├─ Float32 -> S16
  └─ 写入 output ring
```

因此最耗时的 stride / overlap / correlation search 不再阻塞 AudioQueue callback。

## 参数

仍然保持 VLC 3.0.x 默认 scaletempo 参数：

- stride: 30 ms
- overlap: 20%
- search: 14 ms

1x 仍然完全旁路 DSP。

## 测试重点

安装后 Respring，分别测试：

- 1x -> 0.5x，保持 20 秒 -> 1x
- 1x -> 2x，保持 20 秒 -> 1x
- 1x -> 3x，保持 20 秒 -> 1x

请优先判断：

1. 持续噼啪/爆音是否消失；
2. 回到 1x 后是否立即恢复干净；
3. 是否出现短暂静音、明显跳音或 A/V 不同步；
4. 在声音干净的前提下，再比较 2x/3x 音质和 APlayer。

0.7.2 仍是实验版。若出现持续爆音，请退出 Bilibili 并回退 0.6.2。

# GlobalTimePitchFix 0.7.0 — Bili VLC ScaleTempo Prototype

目标：验证 APlayer / MobileVLCKit 路线里最可疑的 VLC `scaletempo` 算法，是否能让旧版 Bilibili 在 iPadOS 13.7 上的 2× / 3× 人声音质接近 APlayer。

## 为什么换路线

已经实测：

- Apple AudioQueue Spectral / TimeDomain：不够好
- Sonic：同步和稳定性正常，但音质仍差
- SoundTouch 0.6.2：比原版好一些，但仍明显不如 Android / APlayer
- APlayer：Codec 1 / 2 的真正 3×（60 秒视频约 20 秒播完）音质仍很好；Codec 3 被限制到约 2×
- APlayer 包含 MobileVLCKit/VLC 3.0.18，二进制内存在完整 `scaletempo` 模块

所以 0.7.0 不再使用 SoundTouch，改为 standalone VLC-style scaletempo。

## 0.7.0 音频路径

### 1×

原始 Bilibili PCM -> 直接输出

不经过 float 转换、不经过 scaletempo。

### 1.5× / 2× / 3×

Bilibili IJK S16 PCM
-> Float32
-> VLC-style scaletempo
-> S16
-> AudioQueue 固定 1×

IJKFFMoviePlayerController 仍保留真实用户速度，因此视频/时钟仍按真实倍速工作。

## Scaletempo 参数

直接先测试 VLC 3.0.x 默认值，不做主观调参：

- stride = 30 ms
- overlap = 20%
- search = 14 ms

算法会用加权互相关寻找最合适的 overlap 拼接位置。

## 编译

把整个目录上传/覆盖到 GitHub 仓库根目录，然后运行 `.github/workflows/build.yml`。

这版不需要再下载 Sonic 或 SoundTouch，scaletempo 适配源码已经包含在 `vendor/vlc_scaletempo/`。

成功后应该得到：

`com.chatgpt.globaltimepitchfix_0.7.0_iphoneos-arm.deb`

## 安装前

0.7.0 包 ID 仍为：

`com.chatgpt.globaltimepitchfix`

因此会覆盖 0.6.2。

## 测试顺序

建议同一个清晰人声视频：

1. 1× 20 秒：必须完全正常
2. 2× 20 秒：和 0.6.2、Android、APlayer 对比
3. 长按 3× 15 秒：重点听金属感、水下感、颤抖、拖影
4. 松手回 1×：检查恢复速度、爆音、断音、同步
5. 拖动进度条后再测 2× / 3×

请记录四项：音质、断音、音画同步、3×松手回1×表现。

## 已知原型限制

- `stop` 时暂不释放 context，避免 AudioQueue callback 生命周期竞态；退出 Bilibili 后系统会回收。
- 速度切换时会重建 scaletempo 状态，可能有很短的瞬态。
- 当前只处理 ijkplayer 常见的 S16 mono/stereo PCM。
- 回调内部仍可能因首次扩容发生 malloc/realloc；验证音质路线后再做实时线程优化。
- 这是根据 VLC 3.0.x scaletempo 算法做的 standalone 适配，并非直接把 APlayer 私有二进制代码复制出来。

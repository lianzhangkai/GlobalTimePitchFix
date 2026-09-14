# Third-party notice

`vendor/vlc_scaletempo/GTScaleTempo.cpp` is a small standalone adaptation of the algorithm in VLC 3.0.x `modules/audio_filter/scaletempo.c`.

The original VLC scaletempo implementation is Copyright © VLC authors / VideoLAN and is licensed under LGPL-2.1-or-later. This source package includes the LGPL 2.1 license text in `LICENSE-LGPL-2.1.txt`.

The adaptation keeps the core behavior and default tuning used by VLC 3.0.x:

- stride: 30 ms
- overlap: 20%
- search: 14 ms
- weighted cross-correlation to choose the overlap point
- constant output stride with input consumption scaled by playback speed

This is an experimental test build, not a production release.

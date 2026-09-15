# NOTICE

This experimental tweak contains a standalone adaptation of VLC 3.0.x `scaletempo` ideas/code structure.
The adapted component remains under LGPL-2.1-or-later; see `LICENSE-LGPL-2.1.txt`.

0.7.2 moves the standalone scaletempo processing to a worker thread and uses SPSC PCM rings so the expensive correlation search is not executed in the realtime AudioQueue callback.

0.8.0 keeps the same VLC-style scaletempo adaptation and adds integration/state-machine hardening only.

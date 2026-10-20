Synthetic video-only AVC 320x180, 4 seconds; 103282 bytes. Exact concatenation of yl_player example assets/test_media/dash/period0/init-0.m4s then chunk-0-00001.m4s through chunk-0-00004.m4s. No external media. SHA256: a9746f24e997dac3bf466501c71935155f887aa160131b7ecd581f519933613c.


The controlled HLS view reuses these exact bytes: init `[0,826)`, followed by
one-second fragments `[826,14451)`, `[14451,38386)`, `[38386,69548)`, and
`[69548,103282)`. The loopback server publishes an EXT-X-MAP and four fMP4
segments; it does not generate or download additional media.

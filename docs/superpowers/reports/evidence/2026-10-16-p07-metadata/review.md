# P07 metadata increment — final review

Single fresh-context reviewer: `review_p07_final`, gpt-6-astra/high. Verdict **With fixes**: 0 Critical, 1 Important, 0 Minor. Reviewer ran the 18 pre-fix stream/evidence Python tests and checked the Rust 3-test log, binary/source/trace identities; no device/GPU use.

Important: ffprobe returns success with one complete packet from the official MP4 truncated to 454604 bytes, despite moov declaring 6314 samples. File hashes alone do not prove completeness. Accepted and fixed in one local TDD pass: validate finite top-level box extents, require media packet ranges within mdat, reject moof/open-ended boxes, and require positive declared nb_frames to equal returned packet count. Unknown declarations fail closed.

Regression evidence: 19 collector tests now pass; the new cases first produced 9 failing subtests. Both real truncated derivatives were accepted before the fix and rejected after it, including a derivative with corrected mdat size but 6313 missing samples. ffprobe returned 0 with empty stderr for both, proving the fix is independent of stderr. The original unmodified media still yields 6314 declared samples/packets/RPUs and an identical complete presentation trace. See completeness-real-red/green.json, Python/full-scan receipts. No second review was dispatched; post-fix closure is implementer verification.

Review Focus (from approved plan):
- 有效但现管线未知的元数据/CM：明确不支持，不当作损坏或忽略（任务 1/2）。
- NLQ/重采样与显示映射局部通过：不能推出最终画质通过（任务 2/3）。
- 目标峰值/黑位/色域变化、外接断接：映射和输出重新评估（任务 3/4）。
- 解码/映射资源不足：不得丢 FEL 或降基础层假装成功（任务 2/3）。
- 电视出现 Dolby Vision 标识但映射有误：信号与独立画面对照分别验收（任务 4）。

Declined to judge: original FEL/NLQ/trim and complete mapping quality; production display peak/black/gamut or external display changes; decoded-frame/effective metadata/presentation correspondence; native DV signal and mobile execution. This increment changes no production mapping and lacks original FEL, independent target references/frozen tolerance and a physical output chain. No support claims were promoted.

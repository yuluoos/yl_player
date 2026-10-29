# Raw evidence

All 13 complete xcresult bundles are retained, including red assertions, the cross-player item crash, and the zero-execution compile failure. Large bundles are split into ordered 15 MiB chunks with `.parts.json` manifests. Concatenate the manifest paths in their listed order outside the repository, verify each part and the combined SHA-256, then extract the resulting tar.gz. No attachment was removed.

Other `.gz` files decompress to the bytes recorded in `raw-provenance.json`. `SHA256SUMS` covers every archived file, part and manifest. Generated media is bound by the fixture hash and reproducible fixture tooling; media segments and private device inventory are excluded. Six initial media captures and one post-review capture have separately recorded source/binary identities. Capture success does not certify physical continuity or complete ABR acceptance. The unsafe item-transfer crash remains failed; the alternative uses a fresh item.

# Raw evidence

All 8 complete xcresult bundles are retained, including the metadata cancellation red assertion. Large bundles are split into ordered 15 MiB chunks with `.parts.json` manifests. Concatenate the manifest paths in their listed order outside the repository, verify each part and the combined SHA-256, then extract the resulting tar.gz. No attachment was removed.

Other `.gz` files decompress to the bytes recorded in `raw-provenance.json`. `SHA256SUMS` covers every archived file, part and manifest. Generated media is bound by the fixture hash and reproducible fixture tooling; media segments and private device inventory are excluded. Four media captures have source/binary identity records. Capture success does not certify physical continuity or complete ABR acceptance. Prior failures are preserved in their original evidence groups; this experiment does not transfer items between players.

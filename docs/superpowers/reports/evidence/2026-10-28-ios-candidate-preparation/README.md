# Raw evidence

The 16 complete xcresult bundles are retained. The large macOS bundle is split
into ordered 15 MiB chunks; no attachment was removed. Reconstruct it outside
the repository by concatenating the paths in `macos-contracts.xcresult.tar.gz.parts.json`
in their listed order, verify each part and the combined SHA-256, then extract
the resulting tar.gz. The manifest records the exact original compressed bytes.

Other `.gz` files decompress to the source bytes recorded in `raw-provenance.json`.
`SHA256SUMS` covers every archive, chunk, manifest, metadata and guide here.
Setup failures and expected red tests are distinct from the eight completed media
captures. Private device inventory is excluded; selected test environment fields
are saved in `device-environment.json`. Generated media bytes can be recreated
from the captured fixture tooling and are bound by each receipt's fixture hash.

# External TTML text runtime subset

P02 Task 2 extends the existing opt-in text runtime. This is a bounded TTML1
text subset, not a TTML/IMSC conformance claim. Source policy, catalog atomicity,
selection/off/offset, seek and media-clock gates reuse the existing pipeline.

Support: UTF-8 XML 1.0, TTML namespace independent of prefix, body/div/p/span/br;
parallel body/div timing and finite p intervals; media clock hh:mm:ss[.fraction]
and h/m/s/ms offsets at microsecond precision, clipped by ancestors. No timed
spans, sequential containers, frame/tick/smpte/clock time bases or animation.

Inline and referenced/chained styles: fontWeight normal/bold, fontStyle
normal/italic, textDecoration underline/noUnderline, color (named and #RGB,
#RRGGBB/#RRGGBBAA), textAlign start/end/left/right/center. Inline overrides
references, later references override earlier ones, content overrides region.
Cycles/missing/duplicate IDs reject the complete document. Font resources,
font sizing, backgrounds, outline, ruby, vertical writing and unsupported
properties reject explicitly. Text is passed directly as styled runs, never
reinterpreted as SRT/HTML markup. Default xml:space collapses surrounding line
whitespace; preserve retains it; br inserts a line break.

Regions have percentage origin/extent wholly inside the visible video aperture,
with before/center/after displayAlign. Default region is the full aperture,
before-aligned; default textAlign is start and direction is LTR. TTML font size
uses one default vertical cell (1/15 of aperture height); renderer font fallback
is Flutter monospace, not an exact TTML font-metric conformance claim. Paragraphs
in one region flow in document order; overflow clips to that region. The existing
SRT/WebVTT bottom-stack layout remains separate.

XML parsing uses xml 7.x lazy events, validates nesting/namespaces/document,
rejects DTD and processing instructions and never resolves external entities.
Strict lexical checks additionally require quoted attribute values, legal
comments/declaration placement, unique attributes/namespaces, reserved namespace
bindings, and whitespace-only content outside the single root element.
Additional hard bounds: 4MiB input, 50,000 events, depth32, 32 attributes/element,
4096 code units/attribute, 128 styles/regions each, 16 style refs/element and
32 style-chain depth; existing cue/run/catalog limits remain in force. The
parser rejects invalid XML characters and unresolved entities rather than
accepting the XML package's permissive entity fallback.

Validation uses owned parser fixtures, actual loopback file/managed HTTP loads,
public lifecycle tests, and rendered region rectangles/pixels. No native, device,
long-play or weak-network ABR acceptance is implied. Full P02 remains open.

Reference: [W3C TTML1](https://www.w3.org/TR/ttml1/) timing, namespace, styling
and region vocabulary; supported forms above are narrower than the standard.

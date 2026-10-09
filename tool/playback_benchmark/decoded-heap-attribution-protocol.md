# Offline decoded EOF heap type attribution

Input is the committed 4/30/60s six-process matrix archive, not a fresh process or
/tmp capture. Select only its 18 final configured/drained/disposed heaps. Validate
matrix completeness and common measurement identity, gzip bytes and SHA against
both raw manifest and probe record, PID, full table and recorded All zones totals.
Do not rewrite the input, restart playback, run heap or enable stack logging.

Keep CLASS_NAME / TYPE / BINARY labels together. Preserve repeated identical label
rows and aggregate their numeric counts for comparisons; they are legitimate in
heap output (e.g. NSArray and task stacks). Handle blank TYPE on named malloc
allocations and non-object separately. Unparsed rows or mismatched totals fail.
The labels are grouping keys, not runtime object addresses or unique metatypes.
Absent selected types remain null: not separately identified does not mean zero.

For each process report configured -> drained and drained -> disposed listing
deltas. Reconcile every class row's counts and bytes to total changes before
retaining top 20 increases/decreases and explicit remainder totals. Compare 60s
with 4s drained snapshots, and separately subtract each process's configured
baseline. Partition that adjusted difference into four disjoint labels
(LifecycleCompletion, dispatch_source_t, __NSMallocBlock__, Closure context),
non-object, and all other listed entries, preserving signed differences. Missing
labels contribute zero only to arithmetic of listings; endpoint values remain
null and are never claimed as zero runtime objects.

Correlate named application types with frozen production and test source, keeping
source inference distinct from observed counts. LifecycleCompletion is a known
application callback container; generic closures, blocks and dispatch sources
are process-wide and cannot all be assigned to audio or production. IntegrationOutput
adds wrapper closures, so count-only progress recording does not remove all test
allocation overhead. No allocation stack, retainer graph, individual identity,
PCM byte ownership, causal intervention, statistical improvement or asymptotic
bound follows from these tables. Missing AVAudioPCMBuffer rows are not proof of
zero downstream PCM. Preserve existing ledger/mode evidence separately.

Test malformed/partial tables, identity tampering, repeated labels, blank columns,
null semantics, full delta conservation and all 18 real archived tables. Save
input archive hash and analysis-tool hashes with derived results; keep the original
measurement source/binary identity. No new native/iOS/long-run verification claim.
Production behavior and defaultEnabled/productionAdmission/downstreamBoundProven
remain unchanged and false. Precise owners and causal contribution remain follow-up
work if no allocation/retainer evidence is available.

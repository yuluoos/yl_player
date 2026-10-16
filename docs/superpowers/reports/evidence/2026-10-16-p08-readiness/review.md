# P08 single final review

Fresh reviewer `review_p08_final`, gpt-6-astra/high, read-only against c088b39 and P08 uncommitted changes. Verdict **With fixes**, 0 Critical, 1 Important, 0 Minor. Reviewer ran14 directed tests and the inventory/gate, without devices or external network.

Important: acceptance records bound product sourceHash and requirement ID, but not requirements document identity. Expanding conditions under the same ID and updating only manifest.requirements could retain old full passes. Accepted. One implementation fix pass adds required requirementsHash to every acceptance and checks it against the manifest's frozen requirement hash. Regression test_same_requirement_id_with_new_conditions_invalidates_old_acceptance first failed (ValueError not raised), then passed; directed15/15. All other identity/scope/failure checks retained. Final full suite and actual inventory/gate receipts are separate evidence. No second reviewer dispatched; fix closure is implementer verification.

Declined-to-judge rulings:
- Physical/minimum-OS/Intel/DRM/Dolby output and long-term resources remain open. Offline inventory cannot replace those runs; no new claim is made. Cost: release remains blocked on required resources/evidence.
- The semantic truth of human full-scope attestations remains a human evidence-review duty. Checker proves recorded identity/coverage consistency, not physical truth. Cost: incomplete or false attestations cannot be detected merely by hashing; documentation explicitly requires review before recording full pass.
- Concurrent P03 c088b39 is outside this P08 review. It was incorporated as committed baseline and its report preserves strict format failures; no re-certification. Cost: P03 runtime behavior relies on its own evidence and review.
- Complete suite and latest report/source fingerprints are executor verification; reviewer did not run the whole suite. Final receipts and hash manifest close this bookkeeping, not additional review.

Review Focus checked against scope: no change to first-frame/presentation measurement; no deletion of historical failed/skipped trials or mixed-condition performance statistics; no invented improvement percentages or targets; no short-test-to-longplay inference; distinct implementation/verification and102 pending rows prevent missing hardware from being reported green.

# P08 single fresh review and fix pass

Reviewer: fresh gpt-6-astra/high agent, read-only, initial base ab734051 working diff.
No Critical. Two Important and one Minor originally reported.

1. Profile constraints (Important): an arm64 macOS27 candidate could fill the
   macOS12/Intel row. `ProfileCoverageTests.test_exact_profile_constraints_are_enforced`
   failed before fix, passes after; actual temporary Git/evidence registry test
   verifies acceptance on the matching profile and rejection on wrong OS/architecture.
2. Source coverage (Important): extension filtering omitted C/C++ and build inputs.
   `SourceIdentityTests.test_native_c_cpp_and_build_inputs_invalidate_identity`
   failed five cases before fix, passes after. Registry integration changes a real
   native file and observes ready=false, source-changed. All Git-visible package
   and benchmark inputs are now hashed, with bounded JSON and symlink identity.
3. Presentation label (reviewer Minor, executor regraded Important reporting
   correctness): all-timeout candidate previously emitted presentationProven=true.
   `PresentationClaimTests.test_all_timeouts_do_not_claim_presentation_proven`
   failed first; final output uses presentationMetricSelected, a schema description
   rather than a physical proof assertion. No missing value is turned into proof.

The reviewer explicitly declined to call all P08 complete: actual output/seek
stability, business phases and cross-device long-duration capture remain beyond
this increment. Executor accepts that limitation and leaves original A–D open.
The scope ruling costs an incomplete overall P08 delivery; it avoids pretending a
schema or calibration hash is an implemented physical capture system.

Final Python suite: 280/280; final example suite:101/101. Final real profile3/3.
No second reviewer pass. Later validation fixes were the shell entry's example
working directory and existing probe-template/format drift, with direct reruns.

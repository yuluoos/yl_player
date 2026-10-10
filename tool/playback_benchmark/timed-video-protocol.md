# macOS timed native video observation

Internal candidate only; production default remains false. macOS 14.4+ is required for measured system output (candidate implementation itself requires 14+). These measurements do not establish physical screen/speaker sync or system resource bounds.

`YlMacosAudioTests.testActualTimedSurfaceSurvivesMainThreadStall` runs the real local AVC/AAC decoder, managed session, committed owner/lease and attached native window. Default injection enables the candidate; `YL_TIMED_CANDIDATE=0` obtains the old-path control. The same continuous fixture, two-second warmup and fixed 250ms main-thread sleep are used. The worker must submit at least four frames during the sleep. No capacity or lead limits are enlarged.

`YL_TIMED_DIRECTORY` persists rows and the final observation in addition to the XCTest attachment. Raw rows distinguish submitted samples, application drops, worker rejection/gaps, system metrics, activation events, and disposal. System metrics are sampled once at each measurement boundary. Intermediate activation rows deliberately contain null metrics; null at a required boundary is a failure, never zero. Final-minus-initial total/dropped/corrupted/accumulated delay must be monotonic, total must increase, and dropped/corrupted must not increase. The mean delay and maximum worker gap must not exceed 100ms. Mean delay is not a maximum per-frame A/V-sync measurement.

Application drops at `activeEnd` include warmup and active observation. Drops after pause/close are preserved separately and never subtracted from activity. Resource checks require both `disposed` and `disposedLater`, ledger zero and no pending presentation. The test reads a native pixel only after pausing; this intentionally perturbs cleanup and does not measure playing-frame continuity.

`testTimedPausedPixelBelongsToCurrentGeneration` separately submits distinguishable green values at PTS 0 and 2s across endpoint retirement, pauses the timebase, checks the actual displayed pixel, and rejects an old-generation frame. It validates epoch/pixel ownership, not decoded frame-by-frame screen capture.

The collector rejects missing endpoint usage, missing/invalid system metrics, zero system output, counter regression, errors, application or system drops, missing disposal, and missing paused pixels. Playback/activation tests keep raw failures; old-path failure is expected evidence, never silently converted to candidate success.

Activation observations use the same native output with 30s activity, a request at 10s, and exact owned NSWorkspace bundle/PID activation. Debug and Profile/AOT are separate runs with identical media and intervention. Source and bundle identity, native exit status, actual didBecomeActive/key notifications, cleanup, and before/after drop classification are independently checked. A final 20-minute candidate observation is run once on the frozen identity. No Instruments or parallel builds run during formal timing observations.

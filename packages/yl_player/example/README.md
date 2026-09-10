# yl_player example

Runnable v0.2 lifecycle example for the application package. Enter a resolved
HTTP(S) media URL, choose live or on-demand intent, then Load and play. The page
creates one Player outside `build`, renders `YlPlayerView`, observes every
asynchronous command, ignores obsolete completions, preserves a session after a
rejected Stop, clears it after an accepted Stop, and disposes safely.

The example is a small API demonstration, not a support claim for an arbitrary
URL. Check the repository [support matrix](../../../docs/platform-support.md)
and [policy semantics](../../../docs/policies.md) for platform-specific routes.

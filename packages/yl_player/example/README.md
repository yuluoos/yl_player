# yl_player example

Compile-time example of the `yl_player` public API. It accepts a resolved
HTTP(S) media URL and optional Referer header, selects live/VOD and a format
hint, renders `YlPlayerView`, and displays state or structured errors.

The `0.1.0-dev.1` Android Media3 and iOS AVPlayer main paths are functional.
iOS HTTP-FLV still requires the deferred native fallback, and production use
requires physical-device validation.

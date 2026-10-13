# Owned compressed CodecPrivate golden

Original UTF-8 strings are stored alongside independently compressed base64 bytes
in `subtitle-private-owned.json`. Python stdlib zlib version is recorded there:

```python
header = 'WEBVTT\n\nNOTE original Python private header'
body = '<b>hello</b>'
header_bytes = zlib.compress(header.encode())
body_bytes = zlib.compress(body.encode())
```

Tests embed these exact byte arrays into owned Matroska CodecPrivate/Block with
Scope3 and discover/select/render from an actual file. No borrowed media or new
runtime dependency. This establishes independent compression evidence, not an
independent Matroska muxer or native/device acceptance claim.

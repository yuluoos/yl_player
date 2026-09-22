# Playback Kernel

This context defines the language used to describe one cross-platform media
playback kernel and the lifetime of the media it plays.

## Language

**Player**:
A long-lived playback context that can host at most one current Playback
Session.
_Avoid_: Backend, controller instance

**Media Source**:
An immutable description of where media is located and what is required to
request it. It is not the loaded media itself.
_Avoid_: URL, media item

**Scripted Live Source**:
A live source whose playable Media Source and request requirements are
obtained by executing a source-specific script.
_Avoid_: JavaScript media protocol, script decoder

**Source Resolution**:
The process of obtaining a playable Media Source and its validity information
from a Scripted Live Source. Successful resolution does not establish that the
resulting media can be played.
_Avoid_: Playback, decoding

**Clear DASH VOD**:
Unencrypted on-demand media described by a DASH manifest, included in the
playback scope on Android, iOS, and macOS.
_Avoid_: DRM playback, encrypted DASH

**DASH Period**:
A section of a DASH presentation's overall timeline with its own media track
and representation descriptions. A Period boundary is not the end of the
overall presentation.
_Avoid_: Playback Session, media segment

**Automatic Quality**:
A playback quality policy that adapts representation selection to current
playback conditions within the eligible choices.
_Avoid_: Fixed Quality

**Quality Ceiling**:
An upper bound on eligible playback quality that still permits automatic
selection of lower qualities.
_Avoid_: Fixed Quality, guaranteed quality

**Fixed Quality**:
A user-selected playback quality that is not automatically lowered when
network conditions worsen.
_Avoid_: Quality Ceiling, preferred quality

**Platform-Specific Protected Rendition**:
A protected delivery of the same content using the media address and DRM
scheme appropriate to its target platform. Equivalent content does not imply
an identical manifest or license service across platforms.
_Avoid_: Universal encrypted MPD, identical cross-platform DRM

**Source Assessment**:
A pre-load determination of whether a Player can route a Media Source while
honouring its explicit requirements. It is not a playback guarantee.
_Avoid_: Capability check, codec probe

**Managed Network**:
A network requirement under which the Player must control and honour the
declared request, timeout, retry, redirect, and credential rules.
_Avoid_: Custom headers, best-effort networking

**Bounded Buffer**:
A buffering requirement that places explicit limits on Player-managed media
queues and caches. It does not describe system, decoder, or GPU allocations.
The managed payload includes media waiting for submission as well as media
already admitted to playback queues.
_Avoid_: Memory limit, buffer hint

**Hardware Required**:
A decoder requirement that accepts a video session only when hardware decoding
can be positively established.
_Avoid_: Hardware preferred, hardware capable

**App-Managed Audio**:
An audio-ownership policy in which the host application controls shared audio
session and audio-focus behavior.
_Avoid_: Silent playback, unmanaged audio

**Plugin-Managed Media Playback**:
An audio-ownership policy in which the Player explicitly manages media playback
audio behavior on behalf of the host application.
_Avoid_: App-managed audio, background audio

**Load**:
The operation that validates a Media Source and commits a new Playback Session
to a Player, making that session observable and immediately addressable by
session commands.
_Avoid_: Open, initialize

**Playback Session**:
One committed attempt to play one Media Source. It ends when it is replaced,
stopped, or its Player is disposed.
_Avoid_: Source generation, playback instance

**Playback Session ID**:
The unique identity used to correlate commands, state, and events belonging to
one Playback Session.
_Avoid_: Generation, player ID

**Ready**:
The point at which a Playback Session can begin or resume playback. Ready does
not imply that a video frame has been presented; initial buffering alone does
not establish Ready.
_Avoid_: Loaded, opened

**First Frame**:
The first video frame presented on the public video output for a Playback
Session. A frame rendered only while preparing a candidate is not First Frame.
_Avoid_: Ready, decoded frame

**Stop**:
The operation that ends the current Playback Session without destroying its
Player.
_Avoid_: Dispose, pause

**Playback State**:
The latest observable facts about a Player and its current Playback Session.
_Avoid_: Event, status

**Playback Engine**:
The media pipeline selected to execute a Playback Session.
_Avoid_: Player, decoder

**Decoder Mode**:
The known evidence about video decoding for a Playback Session: hardware,
software, or unknown.
_Avoid_: Hardware flag

**Failure**:
A structured, safe description of why a command, Playback Session, or Player
could not continue.
_Avoid_: Raw exception, platform diagnostic

**Video Geometry**:
The display dimensions, pixel shape, and rotation needed to present video with
its intended proportions.
_Avoid_: Encoded size, aspect-ratio guess

**Text Subtitle Track**:
A timed sequence of textual cues, optionally including styling, positioning,
or animation, presented alongside the media.
_Avoid_: Bitmap subtitle track

**Bitmap Subtitle Track**:
A timed sequence of subtitle images and their display placement, presented
alongside the media.
_Avoid_: Text subtitle track, burned-in captions

**Complete Dolby Display Mapping**:
For an agreed supported source, faithful processing of its applicable Dolby
dynamic display metadata for the target display, including full FEL image
reconstruction when present, assessed against independent reference output.
_Avoid_: FEL reconstruction alone, retained metadata alone

**Native External Dolby Vision Output**:
A Dolby Vision signal delivered to an external display through an agreed
device and connection path. Display recognition and picture fidelity are
separate acceptance requirements.
_Avoid_: HDR output, Dolby badge alone

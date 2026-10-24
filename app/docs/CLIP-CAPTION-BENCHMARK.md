# ChatGPT clip captions — 2026-10-24

**The app uses nine numbered frames for clips up to 24 seconds and sixteen for longer clips.**
The comparison below tested both sizes before selecting that policy. All requests used the
connected ChatGPT account's offered `gpt-6.1-sol` model, Native output, low reasoning,
concurrency 1 and no reviewer. No API key or rented GPU was used.

## Inputs and method

Three synthetic H.264 clips, each 768 × 432 at 24 fps, supplied known motion:

- **4 seconds:** a ball moves right, stops short of a post and stays there; fixed camera.
- **12 seconds:** a block moves right, pauses for two seconds, reverses left and stops;
  fixed camera. Its actual 440 Hz audio track stays in the source clip.
- **24 seconds:** a camera pans right over stationary objects, zooms toward a vase, then
  cuts to a second stationary scene.

The motion answer key was fixed before encoding and was never sent to the model. Source media
and the key remained unchanged. No family photos, names or other private media were used.

Both counts used the production native frame extractor and sheet renderer: 768-pixel tiles,
JPEG quality 0.85, 2304 × 2304 or 3072 × 3072 canvases, numbered in time order and labeled with
actual decoded timestamps. The model received the project's `h3-video` profile and a
whole-target style concept. **Train audio was off**, so both H3 audio fields used N/A; this
did not assert that the tone-bearing source clip was silent.

The six initial conditions alternated count order between clips. Each used the production
ChatGPT client, Runner and sidecar sink. Every request completed on its first model attempt.
Reopening each project preserved the original clip ID, H3 profile, caption and response record.

## Initial comparison

Times cover the caption run, including frame preparation, the model request and saved output.
Input tokens include the complete instructions and sheet.

| Clip | Frames | Seconds | Input tokens | Observed result |
| --- | ---: | ---: | ---: | --- |
| 4-second move and stop | 9 | 8.81 | 11,091 | Correct direction, stop, final hold and fixed framing |
| 4-second move and stop | 16 | 7.43 | 15,993 | Same motion observations |
| 12-second pause and reversal | 16 | 9.62 | 16,011 | Correct direction and reversal; middle pause and final hold omitted |
| 12-second pause and reversal | 9 | 6.80 | 11,109 | Same omissions |
| 24-second pan, zoom and cut | 9 | 9.19 | 11,091 | Correct camera movement, order, cut and static second scene |
| 24-second pan, zoom and cut | 16 | 8.63 | 15,993 | Same motion observations |

No caption invented object movement, audio, speech or an exact cut time. The longer clip's
camera movement was distinguished from independent subject movement.

## Targeted pause follow-up

The initial captions omitted two visible holds in the middle clip. One instruction changed:
the sheet now asks explicitly for supported starts, stops, pauses, reversals and holds. The
clip, model, profile, settings, sample times and count order stayed fixed. Only that pair was
repeated; the initial outcomes remain part of the record.

| Frames | Seconds | Input tokens | Observed result |
| --- | ---: | ---: | --- |
| 16 | 9.12 | 16,039 | Rightward move, pause, reversal, final stop and hold all explicit |
| 9 | 6.41 | 11,137 | Same required motion observations |

Both requests completed on the first attempt and preserved the original source audio without
claiming to hear it. Captions were checked against the frozen motion key and the actual sheets.

## Native app acceptance and camera-hold finding

The signed native app completed six more first-attempt outcomes using the then-current
nine-through-12-seconds/sixteen-above-12-seconds defaults:
three written H3 captions, one written LTX caption, one H3 audio-on result explicitly marked
unusable, and a written H3 caption after switching Train audio off. The H3 project preserved
its clips, captions, response records and audio choice across quit and reopen. The UI showed
streaming caption text while other clips waited.

The audio-on case used the tone-bearing clip. It produced no caption text sidecar and explained
that the audio was unavailable. Turning audio off produced N/A in both H3 audio fields while
retaining the source audio. The first unusable outcome remains in the evidence.

Independent motion review found an error in both native captions of the 24-second clip:
they added an opening camera hold and a pause between the pan and zoom. The frozen source and
sampled frames show continuous movement at those points. The earlier instruction emphasizing
holds was too loose about the distinction between stationary objects and a stationary camera.
The first repair required repeated unchanged framing and scale for a camera hold. Its three
preserved first attempts produced:

| Clip/profile | Frames | Seconds | Observed result |
| --- | ---: | ---: | --- |
| 24-second pan/zoom/cut, H3 | 16 | 10.75 | Initial false hold removed; unsupported pan-to-zoom hold remained |
| 24-second pan/zoom/cut, LTX | 16 | 12.24 | Correct sequence; both unsupported holds absent |
| 12-second pause/reversal, H3 | 9 | 20.49 | Real pause, reversal and final hold retained; audio N/A |

The H3 caption echoed the added framing-and-scale wording. The next repair replaced that
hold-focused paragraph with one motion-first sentence: describe the visible sequence, changes
in position and scale, and intervals without movement, without adding unseen intermediate
states. Sampling, source clips, profiles, model and settings stayed fixed.


That second repair still produced an unsupported transition hold in H3 (11.04 seconds) and
opening and transition holds in LTX (9.25 seconds). The 12-second H3 control retained its real
pause, reversal and final hold (7.27 seconds). Each was one request and one attempt. More prompt
wording had not resolved the long-clip error.

## Final count comparison

The next comparison changed only the long clip's sheet count. It used the same motion-first
instruction and compared two new nine-frame first attempts with the preserved sixteen-frame
results above. Within each profile, the assembled instructions and execution job were byte
identical; only the target's frame-sheet evidence changed. Source media, answer key, model,
settings, tile size and JPEG quality stayed fixed.

| Profile | Frames | Seconds | Input tokens | Observed result |
| --- | ---: | ---: | ---: | --- |
| H3 | 16 | 11.04 | 16,013 | Required sequence present; unsupported transition hold |
| H3 | 9 | 7.43 | 11,111 | Rightward pan, closer view, one scene cut and static ending; no invented holds |
| LTX | 16 | 9.25 | 15,350 | Required sequence present; unsupported opening and transition holds |
| LTX | 9 | 8.43 | 10,448 | Rightward pan, closer view, one scene change and static ending; no invented holds |

Both nine-frame outputs kept the objects stationary relative to one another while describing
the camera movement. They saved and reopened under the original clip ID and correct profile.
The current nine-frame 12-second result remains the control for a real pause and reversal.
Independent review checked the complete motion sequence against the original clip, not just
the absence of one disputed phrase.

## Default choice

Nine frames retained the tested shorter actions and described the 24-second sequence without
the invented camera holds in the paired sixteen-frame outputs. The app therefore selects
**nine through 24 seconds, sixteen above 24 seconds**. Sixteen above 24 seconds extends the
coverage policy to longer material; clips beyond 24 seconds were not measured here, and this
report claims no quality advantage for that extension.

This is a bounded choice from three known-motion clips and one final long-clip pair per
profile. It does not establish a general model ranking, a statistically reliable speed
difference or a universally optimal duration threshold. Native app acceptance verified the
actual UI flow, storage, reopening and audio choices; the final default uses the same tested
frame extractor, renderer and transport. The threshold itself has focused boundary coverage.

The original clips, fixed answer key, actual sheets, every initial and follow-up response,
timings, usage, sidecars and reopened-project checks are archived outside Git with the acceptance
evidence. Failed motion observations remain alongside their follow-ups.

# ChatGPT clip captions — 2026-10-24

**The app uses nine numbered frames for clips up to 12 seconds and sixteen for longer clips.**
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

## Default choice

Nine frames retained the tested shorter actions with fewer input tokens. Sixteen frames
provided denser observations for the tested longer sequence and correctly described its pan,
zoom and cut. The app therefore selects **nine through 12 seconds, sixteen above 12 seconds**.

This is a bounded choice from three known-motion clips. The comparison does not establish a
general model ranking, a statistically reliable speed difference or a universally optimal
duration threshold. Native app acceptance checks the selected policy through the actual UI.

The original clips, fixed answer key, actual sheets, all eight raw responses, timings, usage,
sidecars and reopened-project checks are archived outside Git with the acceptance evidence.

# Depth and ground shadows

Proposal for owner review. The decisions are independent.

## Depth guide

Allow an opt-in, frame-aligned `depth` pass from a Metal depth render using the clean camera and evaluated geometry. Record `nearMetres`, `farMetres`, `encoding`, and the manifest file role. Use positive camera-axis depth, near white and far or background black, with a stable range across the shot fitted to selected subjects. Offer linear and inverse encoding, and preserve single-sample edges. Start with a 16-bit grayscale PNG sequence so the values and edges survive export. Establish the format the actual conditioning node accepts with a sample before making that format part of the handoff.

Allow two to three engineering days for the renderer, metadata and known-distance verification. Verify a near occluder against a far plane, valid guide files at all declared frames, and matching pixel coordinates across clean and depth passes.

## Ground contact

Offer soft contact shadows on the visible ground and eligible set surfaces in the viewport and the clean pass. Anchor them to evaluated feet or supporting geometry and fade them with separation. The package change is in clean pixels, including clean guide stills. Matte, layout and pose remain separate passes with their existing file roles.

Allow one to two days for contact rendering, matching the viewport and clean exporter, and checks with a floor, a step and an airborne actor. Full cast shadows would require separate scoping.

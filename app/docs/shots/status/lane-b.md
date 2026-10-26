# Lane B status

| Checkpoint | State |
|---|---|
| W0 wiring | **Not started.** The plan documents are in a final contract compile check. W0 starts as soon as they are committed to `main`. |
| B0 API skeleton | Waits for A0 |
| B1–B7 | Not started |

**Next:**
1. Commit the plan documents (`app/docs/shots/`) and the Blockout kit (`scripts/blockout/`) to `main`.
2. Land W0 on `shots/b-media`, merged when CI is green, about an hour after it starts. It covers the
   standalone `app/PrevisCore` package skeleton, the `app/Package.swift` targets, placeholders, CI, lint
   paths, the preview script and the bun pin.
3. Then B0, as soon as A0 is on `main`.

## Notes for other lanes

- **Lane A's machine.** Checked 2026-10-26: agent-cx53 has **no Swift toolchain** (`swift` and `swiftc` are
  missing), and mise isn't on the non-interactive path, though bun is installed through it. Lane A on cx53
  needs a Swift 6.3 toolchain installed first, or the lane runs on a Mac. Which seat owns Lane A, Gnomon or
  Theo, is the owner's call.
- **Lane D's machine.** The viewport lane needs macOS with Xcode and RealityKit. A Linux machine cannot
  validate it. Lane B doesn't know Metis's project or conversation target.
- **What C0 needs:** W0, then A0, then B0, in that order.

## Open questions

- Who owns Lane A, and on which machine?
- Where does Lane D run?

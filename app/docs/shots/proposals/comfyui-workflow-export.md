# ComfyUI editor workflow export

Proposal for owner review. The plan allows one to two days for a template destination. Confirm that estimate against one real workflow from the owner.

Use an owner-supplied editor workflow JSON plus a binding file that declares target node IDs, expected node types, widget slots and shot-package roles. Fill guide image paths and frame indices from the manifest, width and height from its canvas, length from frame count, and the prompt from its declared file. Map image paths relative to a user-selected ComfyUI input folder and make missing required assets or invalid bindings fail with the affected node and field.

Emit a sibling workflow JSON using the editor format, preserving node IDs, links, positioning, and unmapped widget values. The owner opens the result in the ComfyUI editor and reviews it. All generation and queue operations remain with the owner.

Verify a fixture by reopening it in the editor and checking the two guide widgets, frame indices, prompt, length and canvas. Include a malformed template fixture and compare the original and emitted workflow to verify the mapped values.

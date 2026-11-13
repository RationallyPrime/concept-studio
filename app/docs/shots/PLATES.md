# Blocking a scene over location plates

Open a project, switch to **Shots**, and choose or create a scene. A scene holds one shared location and
one shared performance. Each shot selects a plate view and has its own camera.

1. Expand **Location plate** and choose **Import location plate…**. Import the master, reverse,
   staging view and any additional views of the location. Original images are copied into the project.
2. Choose a plate. In **Match camera to plate**, turn on the floor and set guides. Align the one-metre
   floor grid and 1.8 m height marker using the camera position, lens, pan, tilt and roll. Use the same
   world origin and scale for every view. Mark **Camera match confirmed** when the alignment is right.
3. In **Set occlusion and platforms**, add the photographed table, dais, steps, plinth or walls as
   boxes. Set their position and dimensions in metres. **Hides figures behind it** provides occlusion.
   **People can stand on top** provides a standing surface. These solids are shared by all scene views.
4. Add people from the asset library and name them for the characters. Select a person and click a floor
   or platform in **Shot camera** to place them. **Place selected on plate** offers the same operation
   with keyboard-editable frame percentages. **Stand selected on surface** adjusts their standing height.
5. Set **Required framing** and read the inline diagnostics. The staging text reports actual position,
   visibility and facing. Adjust the camera or staging while watching the photographed set. Add another
   reference view when the planned camera reveals an area the existing images leave unseen.
6. Choose the video **Canvas** and **Key size**. For the current portrait pipeline, 576 × 1024 controls
   and 1440 × 2560 composition guides share exact 9:16. Set the ComfyUI graph to the same control canvas,
   frame count and 24 fps before using the controls.
7. Choose **Export shot package…**. Use `composition.png` as the neutral staging reference alongside the
   source plate in Sunburst. Paste `staging.txt` into the prompt or scene sheet and use `legend.txt` to
   identify the stand-ins. The video graph takes `control/pose.mp4` or `control/layout.mp4` alongside the
   accepted key as its first frame.

Selecting a saved plate view resets that shot camera to the saved match. **Reset shot camera to plate**
restores that view after camera editing. A camera move changes the projected shared geometry through the
shot. The still background represents its photographed view. The displayed viewpoint diagnostic identifies
when the shot camera departs from that view.

## Acceptance checkpoint

The attached November 13 briefing requires three paired Sunburst comparisons on plate C, followed by the
three-way H3 video comparison and Hákon's judgment. A saved calibration and passing software checks are
implementation evidence. The canary result and the fifteen-minute blocking check require the production
comparisons and user walkthrough.

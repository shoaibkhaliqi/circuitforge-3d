# Beginner usability walkthrough — performed checks (October 2026)

The walkthrough below was executed against the running app (windowed build).
Where a step was exercised through the engine/session API or the app's CLI
hooks rather than mouse input, it is marked. Screenshots referenced are kept in
`docs/plan/screenshots/`.

1. Start the application and create a new circuit — **performed** (app boots to
   the workbench; status bar shows "Ready"; empty breadboard visible with the
   default camera framing the whole board).
2. Find a resistor and LED — **performed** through the library: the left panel
   lists components with category filter and a search box filtering by name,
   id, category and part number ("resisto", "led"). Count + hint text is shown
   ("243 components shown. Pick one, then click a breadboard hole.").
3. Place them on the breadboard — **performed**: pick a type, the pointer ghost
   turns green over free holes / red over occupied ones; clicking drops the
   part with its pins in adjacent rows of one column.
4. Connect a power source and wires — **performed**: Wire mode (W) connects two
   terminals; the voltage source spans two holes; rails give power nets. Wire
   colour follows the electrical net (same net = same colour).
5. Run the simulation — **performed**: Run DC solve; LED glows according to the
   solved current; node voltages appear in the Measurements panel.
6. Inspect voltage/current — **performed**: Measurements list per-net
   voltages; hovering a hole now highlights its whole electrical net and the
   status bar names the net and terminal count; selecting a component reveals
   its nets on the board and its properties in the Inspector.
7. Save, close, reopen — **performed** via persistence round-trip and by
   reloading a saved project (also covered by automated save/load tests).
8. Find and fix an introduced error — **performed**: removing a needed wire
   gives "Branch currents" in Measurements with the LED receiving no current;
   the build then reports accidental shorts as a warning line ("Component R1
   pins 1 and 2 share net 'a1' (likely an accidental short)") in the
   Diagnostics panel, and the missing ground supplies a clear solver error in
   red that names the fix ("Connect the Ground component"). Warning count is
   surfaced in the status bar.

## Gaps noted during the walkthrough (accepted for now)

- Hover-highlighting and net names are mouse-only; keyboard-only navigation of
  the 3D board is not provided.
- The component library shows no rendered thumbnails — the category dot and
  name/description carry the identification.
- Drag-and-drop is pick-then-click (two clicks) rather than pointer drag;
  on the 3D board both actions end in the same placement path.

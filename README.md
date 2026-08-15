# PenScribe

Version 1.0.0

Annotate documents with your stylus. Freehand drawing, highlighting, and erasing.

Developer: Umut Sagir  
https://github.com/usag1r

Built upon [pencil.koplugin](https://github.com/mysticknits/pencil.koplugin) by mysticknits.

Pen Annotation & Notebook for Kindle Scribe. Heavily optimized for Kindle Scribe (enable Scribe mode). 

Turn Scribe mode on from the plugin menu. If unchecked Kobo behaviour will remain.

Enable PenScribe from **KOReader menu → Tools → PenScribe → Enabled**. The vertical rail shows while a document is open.

**Important.** If **Kindle Scribe Colorsoft** is on in settings and the device is a mono Scribe, non-black ink can be invisible. Turn that option off, or pick black.

---

## Usage

### Vertical rail

Top to bottom when open. Tap a cell. Collapsed is only the handle (`^` / `v`).

- **^ / v** Collapse or expand the stack.
- **Pen** Round ink. Fast (A2) on Scribe while the nib is down.
- **✒ Nib** Fountain Pen. Width follows stroke heading.
- **HL** Highlighter. Picking it runs a full-page flash so leftover pen ink does not hitch. Live stroke is light gray; translucency settles after lift.
- **Era** Erase ink with the tip. Flip the pen for the physical eraser end (that is not this cell).
- **↺** Undo last stroke.
- **☼** Full-page refresh. Same flash as picking HL. Use it when ghosts linger.
- **☰** Popup for notes and clearing (below).
- **< / >** Move the rail to the other edge.

Thickness lives on the **horizontal bar** (top or bottom). `^` / `v` first, then width steps, `<>` last. Collapsed, the `<>` pill sits on the right. Colorsoft adds a 2×12 colour row when that option is on.

**Scribe barrel (side button).** Hold and drag to highlight. A tap does not swap Pen and Era. Flip the pen to erase. After Fast pen ink, the first barrel highlight stroke flashes the page when you lift.

### ☰ popup

- **New Note** Empty Markdown file in the notes folder, then opens it.
- **New Checklist** Same folder, 20 empty ☐ boxes with space between them.
- **New page** Only while a note or checklist is open. Adds a blank drawing page at the end and jumps there.
- **Clear this page** Strokes on the current page only.
- **Clear all annotations** Every stroke in this document.
- **Show annotation status** Counts, paths, stylus state.

Notes folder and the optional date heading are under Edit in the KOReader menu.

### KOReader menu (Tools → PenScribe)

- **Enabled** Master switch. Rail and ink follow this.
- **Scribe** Kindle digitizer, waveforms, palm rejection, highlighter function, sidebutton highlighter, Fountain Pen, improved eraser algorithm, new note functions, vertical & horizontal menus
- **Kindle Scribe Colorsoft** Colour row on the thickness bar. On mono Scribe, non-black does not paint.
- **Tools** Pen, Fountain (nib stamp), Highlighter, Eraser. 
- **Edit** Notes folder, New Note datestamp, undo, clear page, clear all, annotation images, status.
- **About** Credits and license.

Restart KOReader after copying the plugin. Lua is cached until then.

---

## Scribe Improvements

The items below are the specific Scribe improvements.

### Waveforms and input

- **Live ink waveforms** Pen uses Fast (A2) on a dirty-rect union while the nib is down. Highlighter and lift use UI / GC16. No full-page repaint mid-stroke. Dirty rects were already there; the A2 vs UI split is the Scribe optimization.
- **Highlighter, two stages** Live path is light-gray disks, same feel as pen. On lift, a bbox mask is multiplied so overlaps do not stack darker, then a two-chunk UI settle. Picking HL runs a full GC16 flash so leftover A2 does not hitch when you mark over pen ink. 
- **Palm rejection** Capacitive `ABS_MT` is dropped at the input adjust hook before it can stomp `pen_slot`. A speed-clamped jump filter rejects fingertip teleports. If the digitizer goes quiet with contact still latched, a synthetic lift unlocks touch. Hover packets still count as the pen being there.

### Geometric improvements

- **Fountain nib** Heading drives a hairline-to-chisel stamp.
- **Erase without O(n²) restamp** Live erase paints will work from the last painted tip. Polyline punch (split strokes on dab circles) waits until lift, and is skipped if the trail hit no ink. Written because a long drag froze the pen. (More technical explanation below.)
- **Idle work off the pen** Save, bookmark sync, and JPEG capture will wait until the tip is up. Same rule: do not encode mid-stroke to ensure better user experience.

### UI improvements

Scribe chrome and device wiring. Useful. Not math.

- Vertical tool rail and horizontal thickness bar
- Colorsoft 2x12 shade grid (dark over vivid of the same hue; opaque RGB, not alpha)
- Full-page flash every 3 ink-removing erasures (stock Kindle is about every 6)
- Functional Side button to freehand highlight
- Hamburger menu for annotation and notebook specific operations.

---

### Technical explanations

These might be interesting if you are curious about some of the logic under the hood.


### Fountain pen math

The calligraphy bit.

1. Segment heading from `atan2`.
2. Wrap-safe exponential smooth of the angle (unwrap by 2π so a turn past ±π does not jump).
3. Contrast `|sin(heading - nib_angle)|` raised to a power. 0 is along the nib (hairline), 1 is across it (full chisel).
4. Piecewise map: hairline, then a second-thin band, then full width. The ends ease with `u²`.

### Eraser performance

This is the computer-science piece.

- Point in a dab: `(dx² + dy²) <= r²`.
- Point to segment: project onto the segment, clamp `t` to `[0, 1]`, compare squared distance to `r²`.
- Hits punch the polyline into fragments (same metadata, new point lists).
- Live drag only steps from the last *painted* tip, so cost stays O(path length). Restamping the whole trail every sample was O(n²) and locked the CPU on a long erase without lift.

### Highlighter reinvented

A new two-stage approach to the highlight tool.

- Disks are scanline circles: for each row, `dx = sqrt(r² - dy²)`, then a horizontal run.
- Segments stamp disks along the line, step about `width / 4`.
- Finished stroke: paint a bbox mask, blit with multiply so stacked dabs do not go darker.
- Two-chunk UI settle splits the dirty rect (roughly 80/20). Heuristic solution for now.

Live highlighting stays light gray on purpose so it keeps up with the pen. The multiply pass gives the transparency settle after lift.

### Palm touch prevention

- **Palm jump.** `dist / dt` against a cap of about 22 px/ms, clamped 320 to 560 px. Drops a sample that teleported to a fingertip.
- **On-palm test.** Squared distance to a capacitive contact (about 48 px).
- **Missed lift.** If contact flags are still set and the digitizer has been silent for ~1.2 s, synthetic tip-up will be applied.
- **Dirty-rect ink.** AABB union of dabs, flushed every 10 to 16 ms.

### Misc.

Waveform picks (A2 vs UI vs GC16), Colorsoft grid, GC16 when you pick highlighter. The shade grid is two RGB values per hue, a dark one and a vivid one. The panel cannot show 24 distinct hues; the extra cells are shades.

---

## Installation

Copy this folder to `koreader/plugins/penscribe.koplugin` and restart KOReader. Lua is cached until then.

---

## License

GNU Affero General Public License v3.0 (AGPL-3.0).

Same license as [pencil.koplugin](https://github.com/mysticknits/pencil.koplugin) by mysticknits, which this work is built upon. See [gnu.org/licenses](https://www.gnu.org/licenses/agpl-3.0.html) for the full text.

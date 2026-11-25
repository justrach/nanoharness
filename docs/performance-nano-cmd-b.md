# Cmd+B grouped sidebar preparation

The sidebar already virtualized offscreen session rows and group headers.
However, each animation frame discovered groups with a linear key search and
rescanned all chats to count each group. Project validation also searched all
projects for each chat. With many project groups, preparation was quadratic
even though the rendered UI tree stayed small.

## Change

`sidebar_groups.zig` builds a frame-local ordered membership index in one pass.
Counts and heights are accumulated once; rendering visits only a visible
group's members. Session keyboard navigation uses the same membership and
ordering rules. Project existence checks use a frame-local hash set for larger
project lists. No data is retained across frames, so live updates, filters and
disclosures do not need new invalidation or lifecycle handling.

The existing viewport spacers, motion curve, disclosure animation, clipping,
selection, focus, drag behavior and stable UI keys remain unchanged. Project
order follows first occurrence; device order promotes the current device;
attention groups still come first.

## Reproduction and measurement

`Cmd+B grouped sidebar frame work stays near the viewport` drives the real
shortcut and production shell in both directions at 120 Hz simulated time.
It compares 8 synthetic projects with 1,024 projects, one chat per project.
The original regression failed before the fix and passes afterward. Its
stable contract bounds UI-node growth; the 8-versus-1,024 CPU timings are
reported diagnostically, since even linear indexing legitimately costs more
for a larger input and runner scheduling can skew a narrow ratio.

`Cmd+B group indexing avoids the former repeated full-list scans` separately
compares the former nested scan with the production index on the **same**
4,096-group workload. It verifies identical membership counts and requires at
least a generous 2× speedup, using the best of three trials to avoid treating
a scheduler pause as algorithmic work. Neither check asserts a machine-specific
FPS.

ReleaseSafe, native offscreen tester, 32 sampled frames per fixture:

| Fixture | Before | After | Peak nodes before / after |
| --- | ---: | ---: | ---: |
| 8 projects | 0.07 ms | 0.07 ms | 319 / 319 |
| 1,024 projects | 4.35 ms | 0.19 ms | 363 / 363 |

These are average CPU build/layout measurements, not GPU presentation or
end-to-end 120 FPS measurements. Very large chat, bot and pin lists may still
have other preparation costs; this change removes the measured project/group
cross-products without introducing a persistent sidebar cache.

# Cmd+B in fullscreen

The report was that Cmd+B feels slow in fullscreen. `tests_sidebar_performance.zig`
drives the real shortcut at 120 Hz simulated time over long Markdown chats of
made-up prose, windowed and in fullscreen, with one, two and three panes side by
side, opening and closing. `NANO_CMDB_TABLE=1` prints every configuration:

```bash
cd apps/nano
NANO_CMDB_TABLE=1 ../../scripts/heavy-build.sh zig build test -j2 \
  -Doptimize=ReleaseSafe -Dtest-filter="measurement table" --summary all
```

## What was slow

- **The slide's last frame, in a split.** While the sidebar slides, rows off
  screen are spacers with their old height. Once it ended every one of them had
  the height of another column width, so all of them mounted in one frame: the
  whole history of every pane. A single pane at the 736-point cap keeps its
  width, so it never paid this. It isn't special to fullscreen: a window of the
  same size costs the same.
- **Its place.** That frame also moved a reader who had scrolled up (by 1147
  points in the test), since the rows over the viewport changed height.
- **The column's steps, in a split.** The column moved every 8 points, up to 12
  times a slide, and each new width re-broke the text on screen: 13 ms a step
  with three panes when the text caches didn't have it.
- **Over the hover peek, in fullscreen alone.** Cmd+B closed the peek and then
  docked the sidebar from a width of 0: the sidebar vanished on the press and
  took the 200 ms again to come back.

Not causes: mounting the sidebar (the press frame costs the same in a window and
in fullscreen) and the panes' fullscreen captions (build time is the same too).

## Change

- A row the slide stood in for keeps its spacer when the slide ends, and the
  rows are measured again a few a frame, out of sight, one pane at a time. A
  height that changes over the viewport moves the offset by as much, so what the
  reader sees stays. Rows near the viewport go first; one that scrolls into it
  mounts at once. Measured rows can't be selected, focused or read by VoiceOver.
- A pane's column takes the narrower end's width for the whole slide
  (`slideColumnWidth`, proven in `Nano/Tween.lean`), so text breaks once a
  slide. `tweenColumnWidth` and `shouldCullOffscreen` are unchanged.
- A peek that Cmd+B docks stays where it is, and finishes coming in, while the
  canvas slides out from under it. The sidebar is drawn once throughout.

The curve, the 200 ms and reduced motion are unchanged.

## Measurement

ReleaseSafe, native offscreen tester, 1728×1117, fullscreen, CPU ms (build,
layout and paint) of the first toggle each way. "Slide end" is the frame the
slide ends on; "after" is the worst frame and the number of frames until the
window rests.

| Chats | | Press | Mean frame | Worst frame | Slide end | After | Nodes at slide end |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 60 turns, 1 pane | open | 0.18 → 0.18 | 0.28 → 0.29 | 0.29 → 0.38 | 0.33 → 0.34 | – | 845 → 845 |
| | close | 0.28 → 0.29 | 0.26 → 0.28 | 0.27 → 0.37 | 0.16 → 0.17 | – | 451 → 451 |
| 60 turns, 2 panes | open | 0.34 → 0.37 | 0.45 → 0.45 | 0.47 → 0.58 | 3.28 → 0.55 | 0.52 ×1 → 0.63 ×118 | 6,558 → 1,271 |
| | close | 0.45 → 0.44 | 0.45 → 0.43 | 0.48 → 0.44 | 2.67 → 0.43 | 0.43 ×1 → 2.81 ×118 | 6,163 → 876 |
| 60 turns, 3 panes | open | 0.47 → 0.48 | 2.24 → 0.57 | 13.38 → 0.68 | 384.07 → 0.63 | 1.02 ×1 → 3.23 ×178 | 9,610 → 1,646 |
| | close | 0.59 → 0.57 | 2.24 → 0.55 | 13.35 → 0.57 | 378.93 → 2.81 | 0.76 ×1 → 3.03 ×178 | 9,182 → 1,219 |
| 240 turns, 1 pane | open | 0.31 → 0.30 | 0.41 → 0.41 | 0.42 → 0.60 | 0.41 → 0.40 | – | 1,565 → 1,565 |
| | close | 0.43 → 0.42 | 0.41 → 0.39 | 0.43 → 0.42 | 0.30 → 0.29 | – | 1,171 → 1,171 |
| 240 turns, 2 panes | open | 0.61 → 8.81 | 0.71 → 0.71 | 0.74 → 0.79 | 1,012.44 → 3.21 | 1.46 ×1 → 3.71 ×478 | 24,558 → 2,716 |
| | close | 0.75 → 0.71 | 0.71 → 0.71 | 0.77 → 0.74 | 1,026.52 → 12.29 | 1.32 ×1 → 5.26 ×478 | 24,163 → 2,321 |
| 240 turns, 3 panes | open | 0.86 → 13.82 | 0.96 → 0.99 | 0.99 → 1.31 | 1,527.75 → 3.74 | 2.08 ×1 → 4.55 ×718 | 36,610 → 3,807 |
| | close | 1.01 → 1.00 | 0.96 → 1.04 | 1.01 → 1.40 | 1,531.42 → 16.38 | 1.97 ×1 → 4.28 ×718 | 36,182 → 3,379 |

| Cmd+B over a whole peek | Before | After |
| --- | ---: | ---: |
| Sidebar's right edge on the press frame (224 before it) | 0 | 224 |
| Frames until the sidebar is whole again (24 is the 200 ms tween) | 24 | 0 |

Windowed at the same size is within noise of every row, before and after, so in
splits the gap to a window is the window's size: at 1200×780, 60 turns and three
panes, opening ended in a 5.14 ms frame before (0.48 after), not 384 ms.

What it costs:

- With two or three 240-turn panes, the frame that breaks the visible text at its
  new width (the press when opening, the slide's end when closing) is 9 to 16 ms
  when nothing is cached, more than a 120 Hz frame. The press frame when opening
  is a regression there: 0.61 to 8.81 ms and 0.86 to 13.82 ms. The likely reason,
  not instrumented, is that the remount of the whole history on `main` also left
  the text caches holding these widths, which measuring a few rows a frame
  doesn't. With the measuring but without the single column, the press was
  14.01 ms as well and the mean frame 5.49 ms against 0.99.
- The window draws for 1 to 6 seconds after the slide while it measures, at up to
  5.26 ms a frame, rather than stopping for 1 to 1.5 seconds.

These are CPU figures. GPU presentation at fullscreen resolution, and how it
feels on a display, aren't measured here.

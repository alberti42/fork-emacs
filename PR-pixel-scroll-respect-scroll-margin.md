# Make `pixel-scroll-precision` respect `scroll-margin`

**Branch:** `fix/ensure-scroll-margin`
**Code commit:** `4a752bae69b`
**File touched:** `lisp/pixel-scroll.el`

> This document is a cover letter / PR description. It is committed *separately*
> from the code change so that `git format-patch` of the fix commit does not
> include it. To produce the patch for `bug-gnu-emacs`:
> `git format-patch -1 4a752bae69b`.

---

## Summary

`pixel-scroll-precision-mode` (the wheel/trackpad smooth-scroll engine) does not
honour `scroll-margin`. With any non-zero `scroll-margin`, a slow pixel scroll
visibly *fights the user*: the buffer text advances a little, then snaps back by
`scroll-margin` lines, repeatedly. Fast/momentum scrolling mostly hides the
effect, which is why it is usually reported as "slow scrolling is janky."

This change makes the scroll engine place point on the `scroll-margin` boundary
itself, so redisplay finds the margin already satisfied and leaves the window
start alone. When `scroll-margin` is 0 the behaviour is byte-for-byte the
previous behaviour.

## Symptom / reproduction

1. `emacs -Q`
2. `(setq scroll-margin 4)` (any value > 0)
3. `(pixel-scroll-precision-mode 1)`
4. Open a long file, put point in the middle of the window.
5. Scroll **slowly** with the trackpad/wheel.

Observed: as point drifts toward the window edge, the text jumps back by
`scroll-margin` lines on nearly every event — the view "fights" the scroll.
Expected: the text scrolls smoothly; point comes to rest `scroll-margin` lines
from the edge and stays there.

## Root cause

Both `pixel-scroll-precision-scroll-down-page` and
`pixel-scroll-precision-scroll-up-page` reposition point after moving the window
start, explicitly *"to a location that will not result in recentering."* But
they decide that location using only `pos-visible-in-window-p` — i.e. they park
point on the *very edge line* of the window and never consult `scroll-margin`.

Redisplay, however, **does** honour `scroll-margin`: when point ends up closer
than `scroll-margin` lines to an edge, it recomputes `window-start` to restore
the margin. So the engine puts point on the edge and redisplay immediately
yanks the window start back. The two disagree about where point may sit, and the
disagreement is the "snap back."

This was confirmed by instrumenting a running Emacs (`post-command-hook` +
`pre-redisplay-functions`, logging `window-start` / `point` / `scroll-margin`):
the scroll set `window-start` forward and point to window-top, then the next
redisplay reset `window-start` backward by exactly `scroll-margin` lines.

Two distinct shortcomings:

1. **Wrong target.** Point is parked on the edge line; it must be parked on the
   `scroll-margin` boundary (clamped by `maximum-scroll-margin`, which is what
   redisplay actually enforces).
2. **Wrong trigger.** The reposition only fires when point is *fully
   off-screen* (`unless (pos-visible-in-window-p (point))`). But the snap also
   happens when point is *visible but within the margin* — that case was never
   handled, so redisplay snapped regardless.

## The fix

- New helper `pixel-scroll-precision--point-margin`, returning the enforced
  margin — `scroll-margin` clamped by `maximum-scroll-margin`
  (`(min scroll-margin (truncate (* (window-text-height) maximum-scroll-margin)))`,
  matching redisplay's own clamp so we never overshoot on short windows) —
  **plus one line of slack** when that margin is non-zero (see "Sub-line slack"
  below). Returns 0 when `scroll-margin` is 0.
- In `-scroll-down-page` (scrolling toward the *top* edge): trigger the
  reposition when point is off-screen **or** within that distance of the top,
  and target the line that many rows below `window-start` rather than the first
  visible line. End-of-buffer detection (a single `vertical-motion 1` step) and
  the existing `end-of-buffer` signal are preserved.
- In `-scroll-up-page` (scrolling toward the *bottom* edge): symmetric — trigger
  when point is off-screen or within that distance of the bottom, and move point
  that many rows up from the bottom region instead of one.

### Sub-line slack (the `+1`)

Redisplay enforces `scroll-margin` in **whole screen lines**, but pixel
scrolling offsets the display by sub-line `vscroll` amounts that clip the
boundary line. Parking point exactly on the margin leaves only
`scroll-margin - 1` *fully* visible lines plus a fraction; as `vscroll` grows
toward a full line, the whole-line count redisplay sees drops below
`scroll-margin`, so it recenters — the view jitters by one line near buffer
edges and in buffers that fit the window. Parking one line deeper keeps
`scroll-margin` full lines visible at every `vscroll`, so redisplay never
recenters. This is the same failure mode as the main fix, in its residual
sub-line corner.

## Compatibility / safety

- **`scroll-margin = 0`:** `pixel-scroll-precision--point-margin` returns 0;
  both functions reduce to their previous code paths (down-page targets
  `window-start` / the line just below it; up-page targets one line up). No
  behavioural change for the default.
- **Signals preserved:** the `end-of-buffer` (down) and `beginning-of-buffer`
  (up) signals that `pixel-scroll-precision-interpolate` and
  `pixel-scroll-start-momentum` rely on to stop are unchanged.
- **All entry points covered:** the two `-page` functions are the shared engine
  for slow wheel scrolling, interpolated (fast) scrolling, and kinetic
  momentum, so a single fix covers every path.
- **`maximum-scroll-margin` honoured:** prevents overshoot on small windows
  where `scroll-margin` exceeds the enforceable margin.

## Out of scope

`ultra-scroll` (third-party, jdtsmith) is **not** affected: it replaces the
wheel command with its own `ultra-scroll-down`/`-up`, which never call these
`-page` functions and carry the same `scroll-margin`-ignoring logic
independently. It needs an equivalent fix upstream in that package.

## Testing

Done:
- `byte-compile-file` clean (no errors/warnings); `check-parens` clean.
- The equivalent reposition logic was validated empirically as an `:after`
  advice on a running Emacs (slow scroll no longer snaps; point rests on the
  `scroll-margin` boundary; `scroll-margin = 4` preserved).

To verify on the built patched Emacs before submitting:
- [ ] Slow scroll up and down with `scroll-margin` 0, 1, 4, and a large value.
- [ ] Fast/interpolated scroll and momentum (flick) — no snap, stops cleanly at
      buffer ends.
- [ ] Buffers with images / variable-height lines (org with inline images).
- [ ] `visual-line-mode` / wrapped lines.
- [ ] Small windows (a few lines tall) — confirm `maximum-scroll-margin` clamp.
- [ ] `scroll-margin = 0` regression: behaviour identical to pre-patch.

## Submission notes (Emacs)

- Emacs takes patches via `bug-gnu-emacs@gnu.org` (debbugs), not GitHub PRs.
  Generate with `git format-patch -1 4a752bae69b` and attach, or `M-x
  submit-emacs-patch`.
- The code commit already carries a ChangeLog-style message.
- Consider mentioning that this also removes the need for the common user
  workaround of forcing `scroll-margin` to 0 under smooth scroll.

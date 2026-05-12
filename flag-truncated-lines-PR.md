# Add per-edge truncation predicates `window-truncated-on-{left,right}-p`

## Summary

Adds two new C-level Lisp primitives that report whether the most
recent redisplay of a window emitted a truncation indicator on each
edge:

- `window-truncated-on-left-p` — t when WINDOW is horizontally
  scrolled and at least one visible buffer line is consequently cut
  off on the left.
- `window-truncated-on-right-p` — t when at least one visible buffer
  line is too long for WINDOW's width and is consequently cut off on
  the right (because `truncate-lines` is non-nil, or
  `truncate-partial-width-windows` applies).

Both predicates ignore mode-line, header-line and tab-line rows: a
long mode-line string should not be reported as the buffer being
truncated.

## Motivation

There is currently no cheap way for Lisp to ask "did the user actually
see truncated lines on this edge?". The natural use case is gating
horizontal scrolling on actual need: if nothing is truncated on the
right, `scroll-left` reveals nothing and merely drifts the column
offset away from 0 — a common annoyance with trackpads. VS Code and
Sublime both stop horizontal scrolling at the natural extents of the
visible content (you cannot scroll past column 0, and you cannot
scroll past the rightmost visible content); Emacs cannot implement
this efficiently from Lisp without these primitives.

The data the predicates need is already maintained by the C display
engine per row: `display_line` and `display_string` set
`row->truncated_on_left_p` / `row->truncated_on_right_p` on
`struct glyph_row` (declared in `src/dispextern.h`). The primitives
simply surface this existing state to Lisp.

Other plausible uses include conditional modeline indicators,
contextual help, and per-window UI affordances that should be active
only when content is actually truncated.

## Design

The implementation walks the window's `current_matrix`, OR-ing the
relevant per-row bit over every enabled non-mode-line row, and
returns on the first hit:

```c
static bool
window_has_truncation (Lisp_Object window, bool check_left, bool check_right)
{
  struct window *w = decode_live_window (window);
  struct glyph_matrix *m = w->current_matrix;
  if (m == NULL) return false;
  for (int i = 0; i < m->nrows; ++i) {
    struct glyph_row *row = MATRIX_ROW (m, i);
    if (!row->enabled_p || row->mode_line_p) continue;
    if ((check_left  && row->truncated_on_left_p)
        || (check_right && row->truncated_on_right_p))
      return true;
  }
  return false;
}
```

Two thin DEFUN wrappers (`Fwindow_truncated_on_left_p`,
`Fwindow_truncated_on_right_p`) call this with the appropriate
flags. No `struct window` change, no reset logic, no new invariants
to maintain. The matrix typically has a few dozen rows, so the scan
is well below a microsecond.

### Why two predicates instead of one combined function

An earlier draft had a single `window-truncated-p` that OR'd both
bits, but per-edge predicates are necessary to stop horizontal
scrolling at the natural extents on each side. Callers that want
"either" can write `(or (window-truncated-on-left-p)
(window-truncated-on-right-p))` in one line.

### Why filter out mode-line / header-line / tab-line rows

`display_string`, which renders these rows, also sets the truncation
bits when a long mode-line string is cut off. The earlier draft
naively scanned all rows and reported the *window* as truncated
whenever the mode line was too long for the window (very common —
long path + many minor modes), which was wrong. Filtering on
`row->mode_line_p` (true for mode, header and tab lines) restricts
the answer to buffer-text rows.

### Alternative considered: cached bit on `struct window`

A bit on `struct window`, set at each `display_line` / `display_string`
truncation site, would make the query O(1). Reset is the awkward part:
`redisplay_window` may bail out early via `needs_no_redisplay` and
reuse the existing matrix, so the reset would need to live in each
row-rebuilding entry point (`try_window`,
`try_window_reusing_current_matrix`, `try_cursor_movement`, …),
adding more places where the invariant can be broken. The
matrix-walk approach is simpler and the cost is negligible at
realistic window sizes.

## Changes

- **`src/xdisp.c`** — new static helper `window_has_truncation` plus
  two DEFUNs (`Fwindow_truncated_on_left_p`,
  `Fwindow_truncated_on_right_p`); both `defsubr`'d in
  `syms_of_xdisp`. Placed next to the related
  `display--line-is-continued-p` primitive.

- **`etc/NEWS`** — entry under "Lisp Changes in Emacs 31.1"
  announcing the new functions.

- **`doc/lispref/windows.texi`** — entries in the "Horizontal
  Scrolling" section documenting both predicates and showing the
  directional-gating idiom. Notes that `window-truncated-on-left-p`
  is preferable to `(> (window-hscroll) 0)` because it handles
  right-to-left paragraph direction correctly.

## Caveats / notes

- The primitives report the state of the **most recent redisplay**.
  Querying immediately after `set-window-buffer`, before redisplay
  has run, will reflect the previous buffer's truncation state. In
  practice this is fine for the intended uses (e.g. from
  `post-command-hook` or after an explicit `redisplay` call).
- Returns `nil` for windows that have not yet been displayed
  (`current_matrix` is NULL).

## Example usage

Directional gating of horizontal scrolling (typical use case):

```elisp
(defun my/scroll-left-if-needed (arg)
  (interactive "P")
  (when (window-truncated-on-right-p)
    (scroll-left arg)))

(defun my/scroll-right-if-needed (arg)
  (interactive "P")
  (when (window-truncated-on-left-p)
    (scroll-right arg)))
```

This stops horizontal scrolling at the natural extents on each side,
matching VS Code / Sublime conventions. Using
`window-truncated-on-left-p` instead of `(> (window-hscroll) 0)` is
preferable because it reports the rendered state and therefore
handles right-to-left paragraph direction correctly.

## Testing

A manual interactive demo lives at
`docs/debug-window-truncated-p.el` (in the author's dotfiles, not
proposed for inclusion upstream). Two functions:

- `truncation-flag-test-001` — gates hscroll using only pre-patch
  Elisp (mirror of `truncate-lines` / `truncate-partial-width-windows`),
  demonstrating the false-positive when truncation mode is on but
  every line fits.
- `truncation-flag-test-002` — gates hscroll directionally using the
  two new predicates, demonstrating the natural-extent stopping
  behavior.

ERT-style automated tests still TODO before submission. Likely cases:

- Live window with `truncate-lines` t and a long line → right t,
  left nil.
- Same buffer, no long line, wide window → both nil.
- Horizontally scrolled window → left t.
- Window-not-yet-displayed / `current_matrix == NULL` → both nil.
- Same buffer in two windows of different widths → each window
  reports independently.
- Long mode-line string truncated in a window where buffer lines
  fit → both nil (mode-line row filtered out).
- Argument validation: non-window, dead window, internal window →
  errors as `decode_live_window` does.
- R2L buffer with a long line → right t (the right edge in display
  order, regardless of paragraph direction).

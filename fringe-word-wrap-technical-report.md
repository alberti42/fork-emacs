# Technical report: before-string fringe indicator misplaced at word-wrap boundary

## Status

- Fix committed on branch `fix/word-wrap`, commit `6c1dfeac3b2`.
- Working tree default branch is `emacs-31` (does **not** contain the fix).
- Files touched by the fix: `src/xdisp.c`, `test/src/xdisp-tests.el`.
- All line numbers below refer to `fix/word-wrap:src/xdisp.c`.

This document is written for a future maintainer or agent who needs to
understand, review, or rework the patch. It explains the bug, the
mechanism behind it, why the fix works, and the edge cases considered.

---

## 1. Symptom

With `word-wrap` enabled, when a word is pushed to the next visual line
because it does not fit on the current one, an overlay on that word
whose `before-string` carries a `display (left-fringe BITMAP [FACE])`
property has its fringe indicator drawn on the visual line **before**
the wrap, instead of on the line where the word is actually displayed.

The word wraps correctly; only the fringe indicator is misplaced. The
`wrap-prefix` continuation indicator is unaffected.

### Minimal reproducer (emacs -Q)

```elisp
(progn
  (switch-to-buffer (get-buffer-create "*fringe-test*"))
  (erase-buffer)
  (setq-local word-wrap t)
  (setq-local truncate-lines nil)
  (let* ((width (window-body-width))
         (fill (- width 8))
         (target-pos (+ (point-min) fill 1)))
    (insert (make-string fill ?.) " TARGETWORD end")
    (let ((ov (make-overlay target-pos (+ target-pos 10))))
      (overlay-put ov 'before-string
                   (propertize "x" 'display
                               '(left-fringe right-triangle))))))
```

Verification via `fringe-bitmaps-at-pos` after `(redisplay t)`:

```elisp
(fringe-bitmaps-at-pos (point-min))
;; buggy:  (right-triangle right-curly-arrow nil)  -- triangle on line 1
;; fixed:  (nil right-curly-arrow nil)

(fringe-bitmaps-at-pos (+ (point-min) (- (window-body-width) 8) 1))
;; buggy:  (nil nil nil)                            -- nothing on line 2
;; fixed:  (right-triangle nil nil)
```

Real-world trigger: flymake/flycheck diagnostics. Both place an overlay
with a `before-string` carrying a `left-fringe` display spec, so the
error indicator lands one visual line above the flagged word whenever
word-wrap moves the word down. See `fringe-word-wrap-flymake-demo.el`.

---

## 2. Background: how fringe bitmaps flow through `display_line`

The user fringe bitmap from a `(left-fringe ...)` display spec is **not**
a glyph in the text area. It lives on the iterator as
`it->left_user_fringe_bitmap` (and `it->left_user_fringe_face_id`, plus
the right-side equivalents), and is only copied onto the glyph row once,
at the very end of `display_line`, where the iterator fields are then
zeroed:

```c
/* original code, end of display_line */
row->left_user_fringe_bitmap = it->left_user_fringe_bitmap;
row->left_user_fringe_face_id = it->left_user_fringe_face_id;
row->right_user_fringe_bitmap = it->right_user_fringe_bitmap;
row->right_user_fringe_face_id = it->right_user_fringe_face_id;
it->left_user_fringe_bitmap = 0;
it->left_user_fringe_face_id = 0;
it->right_user_fringe_bitmap = 0;
it->right_user_fringe_face_id = 0;
```

The bitmap is set in `handle_single_display_spec` (around xdisp.c:6452)
while `get_next_display_element` is processing the overlay's
`before-string`. It then persists on the iterator across the rest of the
loop iterations for that row.

`fringe.c:update_window_fringes` later gives `row->left_user_fringe_bitmap`
priority over the built-in indicators (truncation, continuation, etc.)
and copies the result into `row->left_fringe_bitmap`, which is what
`fringe-bitmaps-at-pos` reports.

### The word-wrap save/restore machinery

`display_line`'s main loop is:

```
while (true)
  {
    get_next_display_element (it);   // fills current element; may set fringe
    ... wrap-point check, SAVE_IT (wrap_it, ...) ...
    PRODUCE_GLYPHS (it);
    ... fit check; if overflow -> goto back_to_wrap; break ...
    set_iterator_to_next (it, true);
  }
```

When word-wrap sees a candidate break (a non-whitespace element right
after a space), it records the position with `SAVE_IT (wrap_it, *it, ...)`
plus a set of `wrap_row_*` row metrics (used count, ascent, height, min/max
positions, face id). When a later element overflows the line,
`goto back_to_wrap` restores `wrap_it` and the `wrap_row_*` metrics, marks
the row continued, and ends the row. The next `display_line` call resumes
from the restored iterator.

---

## 3. Root cause

The fringe bitmap is set on the iterator **during**
`get_next_display_element` for the overlay-start position. The wrap-point
`SAVE_IT` happens in that **same** loop iteration, *after*
`get_next_display_element`. So `wrap_it` captures the iterator with the
fringe bitmap already set.

Sequence in the bug case (overlay-start coincides with the wrap point):

1. Iterator reaches overlay-start. `get_next_display_element` processes
   the `before-string`'s `(left-fringe ...)` spec and sets
   `it->left_user_fringe_bitmap`.
2. Wrap-point check passes (preceding space made `may_wrap` true, the
   element can wrap before it). `SAVE_IT (wrap_it, ...)` captures the
   iterator **including** the fringe bitmap.
3. The word overflows the line. `goto back_to_wrap` runs
   `RESTORE_IT (it, &wrap_it, ...)`; the iterator still has the fringe set.
4. The loop breaks. At the end of `display_line`, the fringe is copied to
   the **current** row (the line before the wrap) and cleared from the
   iterator.
5. The next `display_line` resumes from the restored wrap point. The
   `before-string` has already been consumed, so it is not re-processed,
   and the iterator's fringe fields are now zero. The line that actually
   shows the word gets **no** fringe.

Result: fringe on visual line N (wrong), nothing on line N+1 (where the
word is displayed).

The key insight: there are two distinct situations and the original code
cannot tell them apart at `back_to_wrap` time:

- **(A)** fringe was set by an overlay *earlier* on the line, before the
  wrap point. It belongs on the current row.
- **(B)** fringe was set by the overlay *at* the wrap point (the wrapped
  word's own overlay). It belongs on the next row.

Both leave the bitmap sitting on the iterator at `back_to_wrap`, so the
original unconditional "copy iterator -> row, then clear" handles (A)
correctly and (B) incorrectly.

---

## 4. The fix

Idea: remember the fringe state as it was **before**
`get_next_display_element` at each loop iteration. At a wrap point, save
that "pre-element" fringe state alongside the other `wrap_row_*` metrics.
At `back_to_wrap`, the pre-element state is exactly the fringe that
belongs to the current row (case A contributions only); anything the
iterator gained *at* the wrap point (case B) is the difference, and must
travel to the next row.

Four edits to `display_line` (xdisp.c, branch `fix/word-wrap`):

### 4.1 New locals (line ~25816)

```c
int wrap_row_left_fringe UNINIT, wrap_row_left_fringe_face UNINIT;
int wrap_row_right_fringe UNINIT, wrap_row_right_fringe_face UNINIT;
bool did_back_to_wrap = false;
```

### 4.2 Snapshot fringe before get_next_display_element (line ~25996)

At the top of the main loop, before the `get_next_display_element` call:

```c
int pre_gnde_left_fringe = it->left_user_fringe_bitmap;
int pre_gnde_left_fringe_face = it->left_user_fringe_face_id;
int pre_gnde_right_fringe = it->right_user_fringe_bitmap;
int pre_gnde_right_fringe_face = it->right_user_fringe_face_id;
```

These are block-local to the loop body; they capture the fringe state
accumulated by *previous* iterations, before the current element can add
to it.

### 4.3 Save pre-element fringe at the wrap point (line ~26098)

Inside the `if (may_wrap && char_can_wrap_before (it))` block, right after
the existing `wrap_face_id = prev_face_id;`:

```c
wrap_row_left_fringe = pre_gnde_left_fringe;
wrap_row_left_fringe_face = pre_gnde_left_fringe_face;
wrap_row_right_fringe = pre_gnde_right_fringe;
wrap_row_right_fringe_face = pre_gnde_right_fringe_face;
```

### 4.4 Flag back_to_wrap (line ~26369)

```c
back_to_wrap:
  did_back_to_wrap = true;
  ...
```

### 4.5 Conditional fringe transfer at end of display_line (line ~26798)

```c
if (did_back_to_wrap)
  {
    /* Current row gets only the fringe committed before the wrap
       point.  */
    row->left_user_fringe_bitmap = wrap_row_left_fringe;
    row->left_user_fringe_face_id = wrap_row_left_fringe_face;
    row->right_user_fringe_bitmap = wrap_row_right_fringe;
    row->right_user_fringe_face_id = wrap_row_right_fringe_face;
    /* If the iterator's fringe equals what we just put on the row,
       it was set before the wrap point: clear it.  Otherwise it was
       set at the wrap point: keep it on the iterator so the next
       display_line places it on the row that shows the word.  */
    if (it->left_user_fringe_bitmap == wrap_row_left_fringe)
      {
        it->left_user_fringe_bitmap = 0;
        it->left_user_fringe_face_id = 0;
      }
    if (it->right_user_fringe_bitmap == wrap_row_right_fringe)
      {
        it->right_user_fringe_bitmap = 0;
        it->right_user_fringe_face_id = 0;
      }
  }
else
  {
    /* unchanged original behavior */
    row->left_user_fringe_bitmap = it->left_user_fringe_bitmap;
    row->left_user_fringe_face_id = it->left_user_fringe_face_id;
    row->right_user_fringe_bitmap = it->right_user_fringe_bitmap;
    row->right_user_fringe_face_id = it->right_user_fringe_face_id;
    it->left_user_fringe_bitmap = 0;
    it->left_user_fringe_face_id = 0;
    it->right_user_fringe_bitmap = 0;
    it->right_user_fringe_face_id = 0;
  }
```

The comparison `it->..._bitmap == wrap_row_..._fringe` is the crux: it
distinguishes case (A) from case (B) without needing to know *where* the
fringe was set.

---

## 5. Why it is correct (case analysis)

Let `IT` = `it->left_user_fringe_bitmap` at `back_to_wrap` (the value
restored from `wrap_it`), and `PRE` = `wrap_row_left_fringe` (the
pre-element snapshot saved at the wrap point).

| Case | Setup | PRE | IT | Row gets | Iterator keeps | Result |
|------|-------|-----|----|----------|----------------|--------|
| 1 (the bug) | overlay at wrap point | 0 | B | 0 | B (PRE != IT) | next row gets B ✓ |
| 2 | overlay before wrap point | A | A | A | cleared (PRE == IT) | current row gets A, next row clean ✓ |
| 3 | overlay before AND at wrap point | A | B | A | B (PRE != IT) | current row A, next row B ✓ |

Case 3 relies on `A != B`. If two different overlays happen to use the
**same** bitmap value (one before, one at the wrap point), `PRE == IT`
and the at-wrap-point fringe is dropped from the next row. This is an
extreme corner case (two overlays with identical fringe bitmaps on the
same visual line straddling the wrap boundary), and the failure mode is
benign: the indicator still appears once, on the current row, instead of
being duplicated. Pre-fix behavior in that scenario was already wrong.

Non-wrapping rows are completely unaffected: `did_back_to_wrap` stays
false and the `else` branch is byte-for-byte the original code.

---

## 6. Tests

`test/src/xdisp-tests.el` adds `xdisp-tests--fringe-at-word-wrap`:

- Guarded by `(skip-unless (display-graphic-p))` because
  `fringe-bitmaps-at-pos` needs real fringes; it is skipped in `--batch`.
- Builds the minimal reproducer, forces `(redisplay t)`, and asserts the
  fringe is on the word's visual line and absent from the line above.

Verified manually in a GUI frame:

```
visual-line-start: 0
visual-line-target: 1     ;; word-wrap confirmed active
fringe-at-target: (right-triangle nil nil)
fringe-at-start:  (nil right-curly-arrow nil)
PASS: t
```

The 10 pre-existing `xdisp-tests` still pass in `--batch` (the new one
shows as skipped there).

---

## 7. Caveats and notes for future work

- **Right-fringe path is mirrored but not separately tested.** The fix
  handles `right_user_fringe_*` symmetrically, but the ERT test only
  covers the left fringe. A right-fringe + RTL test would strengthen
  coverage.
- **R2L / bidi rows.** `back_to_wrap` has a `row->reversed_p` branch
  (`unproduce_glyphs`). The fix sits at the end of `display_line`, after
  bidi handling, and only touches fringe fields, so it should be
  orthogonal, but this was not exercised with an explicit RTL test.
- **`move_it_in_display_line_to`** has its own word-wrap logic
  (`char_can_wrap_before` near xdisp.c:10281) used for cursor motion and
  scrolling, not for drawing. It does not transfer fringe bitmaps to
  rows, so it needs no change. Do not "fix" it by symmetry.
- **Upstream submission strategy.** The bug report
  (`fringe-word-wrap-bug-report.md`) deliberately omits the patch and
  describes the problem in display-engine terms, pointing only loosely at
  `display_line`. The intent is to let the maintainer arrive at the fix;
  this patch is the reference implementation kept on `fix/word-wrap`.
- **The "dots vs >>" observation** seen with flycheck in a real LaTeX
  buffer is unrelated: that is which bitmap flycheck selects per severity
  level, not a redisplay issue. The fix only governs *which row* the
  chosen bitmap lands on.

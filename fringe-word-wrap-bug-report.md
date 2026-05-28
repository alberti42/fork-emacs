Subject: before-string fringe indicator misplaced at word-wrap boundary

When `word-wrap` is t and a word is pushed to the next visual line
because it does not fit on the current one, an overlay on that word
whose `before-string` carries a display `(left-fringe ...)` property
has its fringe indicator placed on the visual line *before* the
wrap, not on the visual line where the word is actually displayed.

Recipe to reproduce (starting from emacs -Q):

  (progn
    (switch-to-buffer (get-buffer-create "*fringe-test*"))
    (erase-buffer)
    (setq-local word-wrap t)
    (setq-local truncate-lines nil)
    ;; Fill the line to 8 columns short of the window width,
    ;; then add " TARGETWORD end".  Word-wrap will push TARGETWORD
    ;; to the second visual line.
    (let* ((width (window-body-width))
           (fill (- width 8))
           (target-pos (+ (point-min) fill 1)))
      (insert (make-string fill ?.) " TARGETWORD end")
      (let ((ov (make-overlay target-pos (+ target-pos 10))))
        (overlay-put ov 'before-string
                     (propertize "x" 'display
                                 '(left-fringe right-triangle))))))

After evaluating, look at the left fringe:

  - The first visual line shows a row of dots ending with a space.
    A right-pointing triangle (▶) appears in the left fringe of
    this line.

  - The second visual line shows "TARGETWORD end".  Its left fringe
    is empty.

Expected: the triangle should be on the second visual line, next to
TARGETWORD (the word the overlay marks), not on the first.

You can confirm programmatically after (redisplay t):

  (fringe-bitmaps-at-pos (point-min))
  => (right-triangle right-curly-arrow nil)   ;; wrong -- triangle is here

  (fringe-bitmaps-at-pos (+ (point-min) (- (window-body-width) 8) 1))
  => (nil nil nil)                            ;; should be here

Flymake is probably the most visible package affected: it uses the
same mechanism (overlay with before-string carrying a left-fringe
display spec), so its error indicator in the fringe appears one
visual line above the flagged word whenever word-wrap moves the
word to the next line.  The attached fringe-word-wrap-flymake-demo.el
shows this with a minimal flymake backend: evaluate it in emacs -Q
and the ‼ indicator lands on the wrong visual line.  As the simpler
reproducer above shows, though, the bug is in the display engine
and, I believe, it cannot be worked around from Elisp.

My guess is that when word-wrap moves a word to the next visual line,
the fringe indicator set by `before-string` of the attached overlay is
not carried along with the word.  The word itself wraps correctly, but
the fringe placement still refers to where the word would have started
without wrapping.

In GNU Emacs 31.0.60 of 2026-05-25.

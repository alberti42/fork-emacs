;;; fringe-word-wrap-flymake-demo.el --- demonstrate fringe misplacement  -*- lexical-binding: t; -*-

;; Evaluate this buffer (M-x eval-buffer) in emacs -Q to see the bug.
;; A flymake error indicator (double-exclamation-mark) should appear
;; on the second visual line, next to the word "MISSPELLED".  Instead
;; it appears on the first visual line, one line above the word.

(defvar-local fringe-demo--diag-pos nil
  "Buffer position where the demo backend reports a diagnostic.")

(defun fringe-demo--backend (report-fn &rest _args)
  "Flymake backend that reports one error at `fringe-demo--diag-pos'."
  (when fringe-demo--diag-pos
    (funcall report-fn
             (list (flymake-make-diagnostic
                    (current-buffer)
                    fringe-demo--diag-pos
                    (min (+ fringe-demo--diag-pos 10)
                         (point-max))
                    :error
                    "demo error on this word")))))

(let ((buf (get-buffer-create "*fringe-demo*")))
  (switch-to-buffer buf)
  (erase-buffer)
  (setq-local word-wrap t)
  (setq-local truncate-lines nil)
  (let* ((width (window-body-width))
         (fill (- width 8)))
    (insert (make-string fill ?.) " MISSPELLED end\n")
    (setq-local fringe-demo--diag-pos (+ (point-min) fill 1)))
  (flymake-mode 1)
  (add-hook 'flymake-diagnostic-functions #'fringe-demo--backend nil t)
  (flymake-start))

;; After a moment, look at the left fringe:
;;
;;   Expected:  the ‼ indicator appears on the second visual line,
;;              next to MISSPELLED.
;;
;;   Actual:    the ‼ indicator appears on the first visual line
;;              (the row of dots), one line above the word it marks.

;;; xdisp-tests.el --- tests for xdisp.c functions -*- lexical-binding: t -*-

;; Copyright (C) 2020-2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'ert)

(defmacro xdisp-tests--in-minibuffer (&rest body)
  (declare (debug t) (indent 0))
  `(catch 'result
     (minibuffer-with-setup-hook
         (lambda ()
           (let ((redisplay-skip-initial-frame nil)
                 (executing-kbd-macro nil)) ;Don't skip redisplay
             (throw 'result (progn . ,body))))
       (let ((executing-kbd-macro t)) ;Force real minibuffer in `read-string'.
         (read-string "toto: ")))))

(ert-deftest xdisp-tests--minibuffer-resizing () ;; bug#43519
  (should
   (equal
    t
    (xdisp-tests--in-minibuffer
      (insert "hello")
      (let ((ol (make-overlay (point) (point)))
            (max-mini-window-height 1)
            (text (copy-sequence "askdjfhaklsjdfhlkasjdfhklasdhflkasdhflkajsdhflkashdfkljahsdlfkjahsdlfkjhasldkfhalskdjfhalskdfhlaksdhfklasdhflkasdhflkasdhflkajsdhklajsdgh")))
        ;; (save-excursion (insert text))
        ;; (sit-for 2)
        ;; (delete-region (point) (point-max))
        (put-text-property 0 1 'cursor t text)
        (overlay-put ol 'after-string text)
        (redisplay 'force)
        ;; Make sure we do the see "hello" text.
        (prog1 (equal (window-start) (point-min))
          ;; (list (window-start) (window-end) (window-width))
          (delete-overlay ol)))))))

(ert-deftest xdisp-tests--minibuffer-scroll () ;; bug#44070
  (let ((posns
         (xdisp-tests--in-minibuffer
           (let ((max-mini-window-height 4))
             (dotimes (_ 80) (insert "\nhello"))
             (goto-char (point-min))
             (redisplay 'force)
             (goto-char (point-max))
             ;; A simple edit like removing the last `o' shouldn't cause
             ;; the rest of the minibuffer's text to move.
             (list
              (progn (redisplay 'force) (window-start))
              (progn (delete-char -1)
                     (redisplay 'force) (window-start))
              (progn (goto-char (point-min)) (redisplay 'force)
                     (goto-char (point-max)) (redisplay 'force)
                     (window-start)))))))
    (should (equal (nth 0 posns) (nth 1 posns)))
    (should (equal (nth 1 posns) (nth 2 posns)))))

(ert-deftest xdisp-tests--window-text-pixel-size () ;; bug#45748
  (with-temp-buffer
    (insert "xxx")
    (switch-to-buffer (current-buffer))
    (let* ((char-width (frame-char-width))
           (size (window-text-pixel-size nil t t))
           (width-in-chars (/ (car size) char-width)))
      (should (equal width-in-chars 3)))))

(ert-deftest xdisp-tests--window-text-pixel-size-leading-space () ;; bug#45748
  (with-temp-buffer
    (insert " xx")
    (switch-to-buffer (current-buffer))
    (let* ((char-width (frame-char-width))
           (size (window-text-pixel-size nil t t))
           (width-in-chars (/ (car size) char-width)))
      (should (equal width-in-chars 3)))))

(ert-deftest xdisp-tests--window-text-pixel-size-trailing-space () ;; bug#45748
  (with-temp-buffer
    (insert "xx ")
    (switch-to-buffer (current-buffer))
    (let* ((char-width (frame-char-width))
           (size (window-text-pixel-size nil t t))
           (width-in-chars (/ (car size) char-width)))
      (should (equal width-in-chars 3)))))

(ert-deftest xdisp-tests--window-text-pixel-size-backward-boundary-string ()
  ;; bug#64252
  "IGNORE-LINE-AT-END leaves END's whole buffer line out of the height.
A before-string, after-string, or `display' string or image anchored on
that line is drawn as part of it, so however tall it is, it must not
change the measured height of the lines above.  The measurement stops at
the top of END's buffer line (reached by walking down to the line's
beginning), so a string drawn at or below that top is never counted.

Needs a graphical frame: a multi-line string collapses to zero rows on a
text terminal, which would make the check vacuous."
  (skip-unless (display-graphic-p))
  (with-temp-buffer
    (dotimes (i 8) (insert (format "line %d\n" i)))
    (switch-to-buffer (current-buffer))
    (redisplay t)
    (let* ((to (save-excursion (goto-char (point-min)) (forward-line 4) (point)))
           (nl (save-excursion (goto-char to) (line-end-position)))
           (tall "boundary\nstring\nfour\nlines\n")
           ;; Height of everything above END's buffer line: a large pixel
           ;; offset clamps FROM to point-min.
           (above (lambda (end)
                    (nth 1 (window-text-pixel-size nil (cons end -1000000)
                                                   end nil nil nil t))))
           ;; Whole-buffer height, with END's line included: it grows when
           ;; the string is genuinely tall (guards against a vacuous test).
           ;; A plain (non-cons) FROM returns a (width . height) pair.
           (full (lambda ()
                   (cdr (window-text-pixel-size nil (point-min) (point-max)))))
           (h-above (funcall above to))
           (h-full  (funcall full)))
      (should (> h-above 0))
      ;; Overlay before-/after-strings anchored on line 4: at its start,
      ;; and at its terminating newline (where the string stacks below).
      (dolist (spec (list (list 'before-string to to to)
                          (list 'after-string  to to to)
                          (list 'after-string  nl (1+ nl) nl)))
        (pcase-let ((`(,prop ,beg ,end ,to*) spec))
          (let ((ov (make-overlay beg end)))
            (overlay-put ov prop tall)
            (redisplay t)
            (should (> (funcall full) h-full))
            (should (equal (funcall above to*) h-above))
            (delete-overlay ov))))
      ;; A `display' string on a character of line 4.  This path already
      ;; worked before the fix; keep it as a guard that the generalization
      ;; did not regress it.
      (put-text-property to (1+ to) 'display tall)
      (redisplay t)
      (should (> (funcall full) h-full))
      (should (equal (funcall above to) h-above))
      (remove-text-properties to (1+ to) '(display nil))
      ;; Same for a `display' image (an automated mirror of the
      ;; interactive reproducer's test-003).  A tall image on line 4 is
      ;; part of that line and excluded.
      (when (image-type-available-p 'svg)
        (put-text-property
         to (1+ to) 'display
         (create-image (concat "<svg xmlns='http://www.w3.org/2000/svg'"
                               " width='40' height='200'>"
                               "<rect width='100%' height='100%'"
                               " fill='#5b9bd5'/></svg>")
                       'svg t))
        (redisplay t)
        (should (> (funcall full) h-full))
        (should (equal (funcall above to) h-above))
        (remove-text-properties to (1+ to) '(display nil))))))

(ert-deftest xdisp-tests--window-text-pixel-size-backward-boundary-wrapped ()
  ;; bug#64252
  "IGNORE-LINE-AT-END counts a wrapped line's rows in full when it lies
above END, and excludes a tall string on END's own line.  pixel-scroll's
sole caller passes `window-start' -- a buffer-line start -- so END tops
its line; this checks a wrapped line neither loses rows above END nor
leaks when it is END's own line."
  (skip-unless (display-graphic-p))
  (with-temp-buffer
    (setq truncate-lines nil)
    (insert "first\n")
    (insert (make-string 2000 ?x) "\n")   ; a long line that wraps
    (insert "third\n")
    (switch-to-buffer (current-buffer))
    (redisplay t)
    (let* ((p-long (save-excursion (goto-char (point-min)) (forward-line 1) (point)))
           (p3 (save-excursion (goto-char (point-min)) (forward-line 2) (point)))
           (tall "boundary\nstring\nfour\nlines\n")
           (above (lambda (end)
                    (nth 1 (window-text-pixel-size nil (cons end -1000000)
                                                   end nil nil nil t))))
           (h-above-p3 (funcall above p3)))
      ;; The wrapped line above line 3 contributes many screen rows.
      (should (> h-above-p3 (* 3 (frame-char-height))))
      ;; A tall before-string ON the wrapped line (above line 3) is part
      ;; of the counted region, so the height above line 3 grows.
      (let ((ov (make-overlay p-long p-long)))
        (overlay-put ov 'before-string tall)
        (redisplay t)
        (should (> (funcall above p3) h-above-p3))
        (delete-overlay ov))
      ;; A tall after-string on line 3 itself (END's line) is excluded.
      (let ((ov (make-overlay p3 p3)))
        (overlay-put ov 'after-string tall)
        (redisplay t)
        (should (equal (funcall above p3) h-above-p3))
        (delete-overlay ov)))))

(ert-deftest xdisp-tests--find-directional-overrides-case-1 ()
  (with-temp-buffer
    (insert "\
int main() {
  bool isAdmin = false;
  /*‮ }⁦if (isAdmin)⁩ ⁦ begin admins only */
  printf(\"You are an admin.\\n\");
  /* end admins only ‮ { ⁦*/
  return 0;
}")
    (goto-char (point-min))
    (should (eq (bidi-find-overridden-directionality (point-min) (point-max)
                                                     nil)
                46))))

(ert-deftest xdisp-tests--find-directional-overrides-case-2 ()
  (with-temp-buffer
    (insert "\
#define is_restricted_user(user)			\\
  !strcmp (user, \"root\") ? 0 :			\\
  !strcmp (user, \"admin\") ? 0 :			\\
  !strcmp (user, \"superuser‮⁦? 0 : 1⁩ ⁦\")⁩‬

int main () {
  printf (\"root: %d\\n\", is_restricted_user (\"root\"));
  printf (\"admin: %d\\n\", is_restricted_user (\"admin\"));
  printf (\"superuser: %d\\n\", is_restricted_user (\"superuser\"));
  printf (\"luser: %d\\n\", is_restricted_user (\"luser\"));
  printf (\"nobody: %d\\n\", is_restricted_user (\"nobody\"));
}")
    (goto-char (point-min))
    (should (eq (bidi-find-overridden-directionality (point-min) (point-max)
                                                     nil)
                138))))

(ert-deftest xdisp-tests--find-directional-overrides-case-3 ()
  (with-temp-buffer
    (insert "\
#define is_restricted_user(user)			\\
  !strcmp (user, \"root\") ? 0 :			\\
  !strcmp (user, \"admin\") ? 0 :			\\
  !strcmp (user, \"superuser‮⁦? '#' : '!'⁩ ⁦\")⁩‬

int main () {
  printf (\"root: %d\\n\", is_restricted_user (\"root\"));
  printf (\"admin: %d\\n\", is_restricted_user (\"admin\"));
  printf (\"superuser: %d\\n\", is_restricted_user (\"superuser\"));
  printf (\"luser: %d\\n\", is_restricted_user (\"luser\"));
  printf (\"nobody: %d\\n\", is_restricted_user (\"nobody\"));
}")
    (goto-char (point-min))
    (should (eq (bidi-find-overridden-directionality (point-min) (point-max)
                                                     nil)
                138))))

(ert-deftest test-get-display-property ()
  (with-temp-buffer
    (insert (propertize "foo" 'face 'bold 'display '(height 2.0)))
    (should (equal (get-display-property 2 'height) 2.0)))
  (with-temp-buffer
    (insert (propertize "foo" 'face 'bold 'display '((height 2.0)
                                                     (space-width 2.0))))
    (should (equal (get-display-property 2 'height) 2.0))
    (should (equal (get-display-property 2 'space-width) 2.0)))
  (with-temp-buffer
    (insert (propertize "foo bar" 'face 'bold
                        'display '[(height 2.0)
                                   (space-width 20)]))
    (should (equal (get-display-property 2 'height) 2.0))
    (should (equal (get-display-property 2 'space-width) 20))))

(ert-deftest test-messages-buffer-name ()
  (should
   (equal
    (let ((messages-buffer-name "test-message"))
      (message "foo")
      (with-current-buffer messages-buffer-name
        (buffer-string)))
    "foo\n")))

(ert-deftest xdisp-test-format-mode-line ()
  ;; 'format-mode-line' returns an empty string with no properties in
  ;; noninteractive sessions.
  (skip-when noninteractive)
  (with-temp-buffer
    (insert (format-mode-line " " t))
    (should (equal (buffer-string) #(" " 0 1 (face mode-line-active)))))
  (with-temp-buffer
    (insert (format-mode-line
             (propertize "x" 'face 'bold-italic)
             1200000000000000000000000000))
    (should (null (get-text-property 1 'face)))))

;;; xdisp-tests.el ends here

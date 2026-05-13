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

;;; window-truncated-on-{left,right}-p

(defmacro xdisp-tests--with-displayed-buffer (&rest body)
  "Run BODY in a fresh buffer displayed in a narrow frame.
Binds `redisplay-skip-initial-frame' and `executing-kbd-macro' to
nil so that `(redisplay \\='force)' populates the glyph matrix,
and resizes the frame to 40 columns so that \"long\" sample lines
reliably overflow.

Tests that depend on the display engine actually setting
truncation bits (i.e. `display_line' running with a finite
`last_visible_x') will only behave correctly in an interactive
Emacs session.  Callers that need that should add
`(skip-unless (not noninteractive))' before invoking this
macro."
  (declare (debug t) (indent 0))
  `(with-temp-buffer
     (switch-to-buffer (current-buffer))
     (let ((redisplay-skip-initial-frame nil)
           (executing-kbd-macro nil)
           (orig-width (frame-width))
           (orig-height (frame-height)))
       (unwind-protect
           (progn
             (set-frame-width nil 40)
             (set-frame-height nil 24)
             ,@body)
         (set-frame-width nil orig-width)
         (set-frame-height nil orig-height)))))

(ert-deftest xdisp-tests--window-truncated-not-when-line-fits ()
  "Short line under `truncate-lines': neither edge is reported truncated."
  (skip-unless (not noninteractive))
  (xdisp-tests--with-displayed-buffer
    (insert "short\n")
    (setq-local truncate-lines t)
    (redisplay 'force)
    (should-not (window-truncated-on-right-p))
    (should-not (window-truncated-on-left-p))))

(ert-deftest xdisp-tests--window-truncated-on-right-when-line-overflows ()
  "Long line under `truncate-lines': right edge is reported truncated."
  (skip-unless (not noninteractive))
  (xdisp-tests--with-displayed-buffer
    (insert (make-string 500 ?x) "\n")
    (setq-local truncate-lines t)
    (redisplay 'force)
    (should (window-truncated-on-right-p))
    (should-not (window-truncated-on-left-p))))

(ert-deftest xdisp-tests--window-truncated-not-when-line-wraps ()
  "Long line with continuation (no `truncate-lines'): neither edge is truncated.
Continuation is not truncation; both predicates must distinguish them."
  (skip-unless (not noninteractive))
  (xdisp-tests--with-displayed-buffer
    (insert (make-string 500 ?x) "\n")
    (setq-local truncate-lines nil)
    (redisplay 'force)
    (should-not (window-truncated-on-right-p))
    (should-not (window-truncated-on-left-p))))

(ert-deftest xdisp-tests--window-truncated-on-left-when-hscrolled ()
  "After `set-window-hscroll' on a line: left edge is reported truncated."
  (skip-unless (not noninteractive))
  (xdisp-tests--with-displayed-buffer
    (insert "abcdefghij\n")
    (setq-local truncate-lines t)
    (setq-local auto-hscroll-mode nil)
    (goto-char (point-min))
    (set-window-hscroll (selected-window) 3)
    (redisplay 'force)
    (should (window-truncated-on-left-p))))

(ert-deftest xdisp-tests--window-truncated-ignores-mode-line ()
  "A very long mode-line must not be reported as the buffer being truncated.
Regression test for the mode-line filter in `window_has_truncation'."
  (skip-unless (not noninteractive))
  (xdisp-tests--with-displayed-buffer
    (insert "short\n")
    (setq-local mode-line-format (make-string 500 ?m))
    (setq-local truncate-lines t)
    (redisplay 'force)
    (should-not (window-truncated-on-right-p))
    (should-not (window-truncated-on-left-p))))

(ert-deftest xdisp-tests--window-truncated-ignores-header-line ()
  "A very long header-line must not be reported as buffer truncation."
  (skip-unless (not noninteractive))
  (xdisp-tests--with-displayed-buffer
    (insert "short\n")
    (setq-local header-line-format (make-string 500 ?h))
    (setq-local truncate-lines t)
    (redisplay 'force)
    (should-not (window-truncated-on-right-p))
    (should-not (window-truncated-on-left-p))))

(ert-deftest xdisp-tests--window-truncated-rejects-non-window ()
  "Passing a non-window value signals an error.
This test does not depend on redisplay and runs in batch mode."
  (should-error (window-truncated-on-left-p 'not-a-window))
  (should-error (window-truncated-on-right-p 'not-a-window)))

(ert-deftest xdisp-tests--window-truncated-on-right-rtl ()
  "RTL paragraph with a long line: right (visual) edge is reported truncated.
The predicates report which visual edge was drawn with a truncation
indicator, regardless of paragraph direction."
  (skip-unless (not noninteractive))
  (xdisp-tests--with-displayed-buffer
    (insert (apply #'concat (make-list 50 "שלום ")) "\n")
    (setq-local truncate-lines t)
    (setq-local bidi-paragraph-direction 'right-to-left)
    (redisplay 'force)
    (should (window-truncated-on-right-p))))

;;; xdisp-tests.el ends here

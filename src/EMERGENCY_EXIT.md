# Emergency escape: planned improvements

## Background

Before this patch, the TTY emergency escape had no counter at all:

- First `C-g`: `quit-flag` is nil → set it to `Qt`, done.
- Second `C-g`: `quit-flag` already non-nil AND TTY present → emergency
  escape fires immediately, asking "Auto-save?" then "Abort?".

The `force_quit_count` counter existed only for the non-TTY case (when
`inhibit-quit` is set), where it tracked repeated `C-g` presses to
eventually force `inhibit-quit` to nil.

This made accidental escapes common with Magit: Magit holds `inhibit-quit`
during operations, so the first `C-g` sets `quit-flag` but cannot be
processed.  Any subsequent `C-g` — including ones buffered while waiting —
triggered the emergency escape the moment Magit released control.

The "Abort?" prompt compounded the problem: it reads naturally as "abort
this emergency action" (safe), but actually means "kill Emacs" (destructive).

## Changes already applied

- `keyboard.c`: introduced `tty_emergency_escape_count`, a dedicated counter
  for the TTY emergency escape branch, independent of `force_quit_count`.
  Threshold is hardcoded to 10 consecutive `C-g` presses.
- `keyboard.c`: "Abort?" prompt renamed to "Kill Emacs?" to eliminate the
  ambiguity.

## TODO: make threshold user-configurable

### 1. Add a new Lisp variable in `keyboard.c`

```c
DEFVAR_INT ("emergency-escape-threshold", emergency_escape_threshold,
  doc: /* Number of consecutive C-g presses required to trigger emergency escape.
A value of 1 restores the original behavior (any C-g while quit-flag is
already set triggers the escape).  Higher values reduce accidental triggers.
Default is 10.  */);
emergency_escape_threshold = 10;
```

Declare the corresponding C variable in `keyboard.h` (or as `static int`
near `force_quit_count`).

### 2. Replace hardcoded 10 in the condition

```c
  if (!NILP (Vquit_flag) && get_named_terminal (dev_tty)
      && ++tty_emergency_escape_count >= emergency_escape_threshold)
```

### 3. NEWS entry

Under `* Editing Changes in Emacs 31.1` (or similar):

```
---
** New variable 'emergency-escape-threshold'.
Controls how many consecutive C-g presses are required to trigger the
emergency escape.  Default is 10; set to 1 to restore the original behavior.
```

### 4. Manual entry

In `doc/emacs/trouble.texi`, find the node describing the emergency escape
(search for "emergency escape") and add a paragraph documenting
`emergency-escape-threshold`.

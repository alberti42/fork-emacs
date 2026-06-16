# PR: macOS — make the NS daemon reopenable from the Dock

**Branch:** `fix-macos-lifecycle` &nbsp;|&nbsp; **Target:** GNU Emacs `master` (NS port, `--with-ns`, `NS_IMPL_COCOA`)
**Series:** 5 code commits — **A** "ns: make a frameless daemon reopenable from the
Dock" (NS port), **B** "Don't let closing a clientless frame kill a daemon", **C**
"ns: add `ns-show-daemon-in-dock` …" (convenience API), **D** "ns: focus the frame
the reopen gesture creates", **E** "Don't leave input bound to a keyboard that has
no frames" — plus this cover letter.

> SHAs are intentionally **not** quoted here: the branch is periodically rebased
> onto `master`, so they churn. Refer to commits by subject; the order on the
> branch is A → B → C → (this cover letter) → D → E.
>
> This file is a **branch-local cover letter / memory aid** for when this gets
> filed to `bug-gnu-emacs` (debbugs). It is **not** meant to be merged upstream —
> drop it before submission (don't include the cover-letter commit in
> `git format-patch`). The three code commits (A, B, C) are the deliverable.
>
> Companion design docs (in the `emacs-mac-builder` repo, not part of this tree):
> `docs/macos-app-lifecycle-investigation.md` (the validated defect spec, with
> file:line citations) and `docs/nsterm-reopen-fix-plan.md` (implementation notes).

---

## TL;DR

Run an Emacs **daemon**, open a GUI frame, close it. The daemon **correctly**
drops its Dock presence (activation policy → `Prohibited`, Launch Services reports
`BackgroundOnly` — verified). The defect is the **way back**: the macOS-native
gesture to get a frame again is to click the app (a pinned Dock icon, or
`Emacs.app` in Finder), but the daemon is now in `Prohibited` — Apple's *"may not
create windows **or be activated**"* — **and the NS port implements no
`applicationShouldHandleReopen:hasVisibleWindows:`**, the standard Cocoa hook that
turns such a click into a window. So the click produces an **inert app with no
frame**; the only recovery is a terminal `emacsclient -c`. A macOS user reasonably
concludes *"Emacs is broken."*

**Fix (Patch A):** stop parking in `Prohibited` (use a reactivatable policy), and
implement the reopen contract so a click yields a frame. **Patch B** then makes
sure that once such a frame is closed again, the daemon survives instead of being
killed by `C-x C-c` on a clientless frame. **Patch D** focuses the frame the
gesture creates, without which a background app builds the window but never shows
it. **Patch E** stops input staying bound to a keyboard that has no frames, which
is what otherwise swallows the click before anything can act on it.

---

## 1. Background: the native macOS app lifecycle

A normal macOS GUI app (`Regular`) stays available with **no windows open** (Mail,
Notes, Preview). Clicking its Dock/Finder icon while it has none triggers
`applicationShouldHandleReopen:hasVisibleWindows:`, in which the app makes a fresh
window. Closing the last *window* does not quit the app; **⌘Q** does. This
window-vs-app distinction is fundamental to the platform.

`NSApplicationActivationPolicy`:

| Policy | Dock tile | Menu bar | Can be activated / create windows? |
|---|---|---|---|
| `Regular` | yes | yes | yes |
| `Accessory` (`LSUIElement`) | no | no | **yes** — programmatically or by clicking |
| `Prohibited` | no | no | **no** — "may not create windows or be activated" |

The asymmetry driving the bug: **`Accessory` is reactivatable; `Prohibited` is not.**

---

## 2. Root cause (validated, not theorized)

Three parts:

1. On losing its last GUI frame the daemon parks in **`Prohibited`**
   (`ns_delete_terminal`, `src/nsterm.m`) — the one policy that cannot be
   reactivated.
2. The port never implemented **`applicationShouldHandleReopen:`**, so even a
   reactivatable app would have nothing to turn a click into a frame.
3. Even once the click reaches Emacs, its event is **queued for a keyboard nobody
   is reading** and never dispatched (§4c). The gesture is recorded and lost.

### Evidence

An instrumented build (temporary `fprintf` in `ns_delete_terminal` around
`setActivationPolicy:`, reading `[NSApp activationPolicy]` before/after) was driven
against an isolated `--fg-daemon` with full init; phase markers interleaved via
`(princ … #'external-debugging-output)`. Create one GUI frame (`emacsclient -c`) →
delete it → read the ordered log + `lsappinfo`:

```
RBMARK before-delete
ns_delete_terminal ENTERED;     policy_before=0   ; 0 = Regular
ns_delete_terminal set Prohibited; policy_now=2   ; 2 = Prohibited
RBMARK after-delete
```
`lsappinfo` after the delete: **`type="BackgroundOnly"`**.

So: closing the last frame **runs** `ns_delete_terminal`, **sets** `Prohibited`,
and Launch Services **honors** it. That backgrounding is *correct* for a server.
The bug is purely the un-reopenable state that follows. Two earlier hypotheses were
tested and **refuted** (recorded so they aren't revisited): (1) "the
`Regular→Prohibited` downgrade is silently dropped" — no, `lsappinfo` confirms
`BackgroundOnly`; (2) "`ns_delete_terminal` never runs on frame close" — no, the
ordered log shows it runs between the markers.

---

## 3. Patch A — make a frameless daemon reopenable from the Dock

Files: `src/nsterm.m`, `lisp/term/ns-win.el`.

1. **Don't park in `Prohibited`.** `ns_delete_terminal` now reads a new variable
   **`ns-frameless-activation-policy`** (`regular` default, or `accessory`) and
   sets that instead. Both are reactivatable; `Prohibited` is no longer used.
   `regular` keeps a live Dock tile (Mail/Notes model); `accessory` hides the tile
   but stays activatable, so a pinned-icon / `open` click can still reopen it.

2. **Implement `applicationShouldHandleReopen:hasVisibleWindows:`.** When there is
   no visible window, post the existing `ns-new-frame` event (the same path the
   Dock's "New Frame" item uses), gated on **`ns-reopen-creates-frame`** (default
   `t`). Returning `YES` lets AppKit run its default reopen behavior too.

3. **Frameless `ns-new-frame` handling.** A new `ns-new-frame` command: when the
   selected frame is not an NS frame — which is exactly the frameless-daemon case,
   where the selected frame is the initial terminal — create the frame on an
   existing NS display (`make-frame-on-display`) instead of bare `make-frame`,
   which fails there with *"Unknown terminal type."*

4. **`system-key-alist` on every terminal.** `ns-setup-special-keys` now populates
   *every* live terminal's `system-key-alist`, not just the current keyboard's, so
   the NS command events still translate while the daemon is frameless.

5. **`Regular` restored on frame creation.** Creating a frame returns the app to
   `Regular` (existing path in `nsfns.m`, `Fx_create_frame`), so the new frame gets
   a normal tile + menu bar.

### 3a. Non-obvious, empirically-required: dispatch `[ns-new-frame]` as a *special event*

The reopen handler is necessary but **not sufficient**. With `[ns-new-frame]` in
`global-map` (the stock binding), the **first** Dock click on a frameless daemon
produced *no frame* — a second click was needed. A single-click instrumented trace
showed why: the reopen *does* fire on click 1 (`flag=0`), `newFrame:` *does* run
and queue the `ns-new-frame` event — but it then **sits in the keyboard buffer**.
An idle, frameless daemon's command loop won't dispatch a `global-map` key event
until the *next* input arrives: it has no focused-frame / current-keyboard context
to run `read-key-sequence` against (the event is tagged to the NS keyboard, while
the daemon's loop is reading the initial terminal). Click 2 supplies that context.

**Fix:** bind `[ns-new-frame]` in **`special-event-map`**, not `global-map`.
Special events are run by `read-char` the instant the event is read — regardless of
focus — so the binding is found without a focused-frame context. (`make-frame` from
the special-event context was fine for the idle-daemon path in testing; the only
theoretical concern is reentrancy if it were triggered mid-redisplay, which the
reopen path is not.)

This is necessary but **not sufficient**, and the residue is §4c: being *read* is
the hard part. `newFrame:` stamps the event with `SELECTED_FRAME ()`, which on a
frameless daemon is the initial terminal frame, so the event belongs to that
keyboard. While input is locked to a different keyboard — any minibuffer read or
recursive edit takes such a lock — the event is queued for a keyboard nobody reads
and the click does nothing. An instrumented build shows the whole path: the click
arrives, `newFrame:` queues it, the symbol translates, the special-event binding is
found — and in between, `DIVERTED ns-new-frame: event kboard=… current_kboard=…
single_kboard=1`.

### All parts are required

A reopen handler can't fire while `Prohibited` (not activatable); dropping
`Prohibited` without a handler leaves a live tile that does nothing on click; a
handler whose event goes to `global-map` is never looked up on an idle frameless
daemon; an event addressed to an unread keyboard is queued and dropped (§4c); and a
frame created without focus stays invisible (§4b).

---

## 4. Patch B — don't let closing a clientless frame kill a daemon

Files: `lisp/files.el`, `lisp/server.el`.

Once Patch A lets a click create a frame, closing *that* frame must not kill the
daemon. `save-buffers-kill-terminal` (`C-x C-c`) dispatches on
`(frame-parameter nil 'client)`: a frame with **no client** fell through to
`save-buffers-kill-emacs` and killed Emacs. In a daemon that's wrong for an
in-process frame (one from `make-frame`, or from the Dock via the reopen handler) —
it would take down the whole daemon and every other session's state.

Emacs already protects *client* frames here (`server-save-buffers-kill-terminal`);
this **generalizes that protection to all of a daemon's frames**, framed as
removing an inconsistency rather than adding a special case.

- **`lisp/server.el`:** new shared helper
  **`server-save-buffers-kill-terminal-noclient`** — offer to save buffers and
  `delete-frame`, unless this is the last frame standing (honoring
  `server-stop-automatically`, discounting the daemon's initial frame), in which
  case `save-buffers-kill-emacs`. The `'nowait` branch of
  `server-save-buffers-kill-terminal` now calls it too, so a non-client Dock frame
  and a `nowait` (`emacsclient -n -c`) frame behave **identically in every config**.
- **`lisp/files.el`:** `save-buffers-kill-terminal` routes a **clientless** frame in
  a daemon through that helper instead of killing Emacs.

Design choices (deliberate):

- **Window-system-agnostic:** gated on `(daemonp)`, *not* on NS. The rule — *a
  daemon is killed only by explicit `kill-emacs` / `server-stop-automatically`,
  never by a frame-close gesture* — holds for any daemon; only the Dock *trigger*
  is NS-specific.
- **Reopen frames stay non-client** (plain `make-frame`, `client = nil`), not a
  dummy `'nowait` client. The C reopen path stays uniform; all kill-vs-delete policy
  lives in Lisp. (`emacs --daemon` always starts the server, so `(daemonp) ⟹ server
  running` — deferring this to `server.el` is legitimate reuse, not new coupling.)
- **Save-on-close retained:** closing the last frame still offers to save modified
  buffers (a daemon silently accumulating unsaved buffers that vanish on reboot is
  both un-macOS-like and dangerous). This matches a fileless `emacsclient -c`.

---

## 4a. End-to-end: how a headless daemon becomes clickable (Patch C + user init)

This is the user-facing half of the story, and it's why **Patch C** exists.

Patch A's `applicationShouldHandleReopen:` only fires once the app is **registered
with Launch Services** (i.e. has a Dock tile). A LaunchAgent-started
`emacs --fg-daemon` is **headless and unregistered** — there is nothing to click.
**Patch C** provides the command **`ns-show-daemon-in-dock`** for exactly this: it
registers the process (Dock tile, no visible window) so a click can be handled. The
user calls it from a daemon's init:

```elisp
(when (daemonp) (ns-show-daemon-in-dock))
```

How it works — and why it leaves no phantom frame (**verified: tile, icon, and
first-click reopen all work**):

- It briefly creates an **invisible** NS frame and immediately deletes it.
- `make-frame` runs `ns_term_init`, which opens the NS connection and **registers
  the process with Launch Services** (Foreground + tile).
- Deleting that (last NS) frame runs `ns_delete_terminal`, which — with this series
  + `ns-frameless-activation-policy = regular` — **keeps the app `Regular` (tile
  stays)**, never `Prohibited`; the in-process NS/AppKit display **lingers**, so the
  connection isn't torn down.
- Net: the daemon ends in the clean "frameless but registered" state, `frame-list`
  back to just the initial terminal frame — **no phantom frame** — and a Dock click
  is handled by Patch A (first click, via §3a).

No deferral is needed: the create-then-delete works **synchronously** at init time
(verified — an earlier `run-at-time 0` wrapper turned out to be unnecessary).
`ns-show-daemon-in-dock` is the (a) "Elisp trick" implementation; the function name
leaves room for a future (b) C implementation — set up the NS connection +
activation policy + Dock icon directly, without ever creating a frame — behind the
same API (see the function's own comment).

This composition (headless daemon + `ns-show-daemon-in-dock` + Patch A) also points
at an obvious future enhancement: have the daemon self-register, or have the bundle
launch via `--fg-daemon`, so "click `Emacs.app` from boot → get a frame" works with
no manual step at all. Out of scope for this series.

---

## 4b. Patch D — focus the frame the reopen gesture creates

File: `lisp/term/ns-win.el`, `src/nsterm.m`.

Creating a window does not bring a background application forward; only focusing it
does. `ns_focus_frame` is the one routine that both activates the app and orders
the window front, and plain `make-frame` calls neither. So `ns-new-frame` focuses
the frame it creates in **both** of its branches — the frameless-daemon branch and
the branch taken once an NS frame is already selected. Without this, the first
click's frame appears and every later click builds a real but invisible frame;
`emacsclient -c` then activates the app and all of them surface at once.

`ns_focus_frame` also asks for activation with `activateIgnoringOtherApps:`, which
macOS 14 deprecated and may refuse for an app that is not already frontmost. It
now prefers `[NSApp activate]` where the SDK and the running system provide it,
matching the version guard already used elsewhere in `nsterm.m`.

---

## 4c. Patch E — don't leave input bound to a keyboard that has no frames

Files: `src/frame.c`, `src/keyboard.c`, `src/keyboard.h`.

A keyboard whose last frame is gone can receive no input, yet Emacs can stay bound
to it and locked to it. Every event addressed to any other keyboard is then queued
and never read, and the lock cannot be lifted, because lifting it needs input from
the very keyboard nobody can reach. On a frameless daemon this swallows every
application-level NS command — the reopen gesture, `ns-open-file` from the Finder,
the quit gesture — and leaves a session that looks hung while sitting idle at 0%
CPU.

Three things keep input bound there:

1. **`delete_frame` skipped its release path** whenever the terminal's reference
   count reached zero, on the assumption that the terminal was going away. A delete
   hook may leave the terminal alive waiting for new frames, which is exactly what
   `ns_delete_terminal` does — it never calls `delete_terminal`. `delete_terminal`
   clears the terminal's name, so a name still present means the terminal stayed and
   its keyboard must still be accounted for.
2. **Releasing the lock left `current_kboard` pointing at the frameless keyboard**,
   and every interactive command re-locks onto whatever that is
   (`funcall-interactively` → `temporarily_switch_to_single_kboard`). The new
   `kboard_lost_last_frame` drops the lock and repoints only to a frame a user can
   actually type on — never the daemon's initial frame, which has a keyboard but no
   way to type on it. With no usable frame anywhere it repoints nothing and lets
   `read_char` follow whatever keyboard produces input next.
3. **`pop_kboard` restored such a keyboard** as long as its *terminal* existed,
   putting the lock straight back when the deleting command unwound. It now requires
   a live frame as well, reaching the fallback that was already there for deleted
   terminals.

Only the first hunk is prompted by NS behaviour. The other two are generic
keyboard-lifetime bugs: any terminal whose delete hook keeps the terminal alive, and
any multi-terminal session that loses the frames of a locked keyboard, hits them.

---

## 5. New user-facing additions

Variables (Patch A):

- **`ns-frameless-activation-policy`** (`regular` | `accessory`, default `regular`).
  How a daemon presents itself after losing its last GUI frame. `Prohibited` is
  intentionally not offered (it cannot be reactivated). A new frame restores
  `Regular`.
- **`ns-reopen-creates-frame`** (boolean, default `t`). Whether a reopen with no
  visible window creates a frame. `nil` makes the reopen a no-op (purist opt-out).

Command (Patch C):

- **`ns-show-daemon-in-dock`** — register a headless daemon with the OS so it gets a
  Dock tile (and is therefore clickable / reopenable) without showing a window.
  Opt-in (the user calls it from init); a truly headless daemon is left undisturbed
  if it's never called.

The variables default to the new, correct behavior; gate behind them for
acceptability.

---

## 6. Testing / validation

Use an **isolated, uniquely-named `--fg-daemon`** (own socket) so a real daemon is
never disturbed. Gotchas that cost real time during the investigation:

- **`terminal-list` reports the `ns` terminal "live" after `ns_delete_terminal`
  ran** — and it is: that hook drops the display info and returns without calling
  `delete_terminal`, so the terminal and its keyboard outlive the last frame. §4c
  depends on this. For the activation policy, trust `lsappinfo` (`type=` field:
  `Foreground` / `BackgroundOnly`) and `fprintf` tracing.
- **A background `--daemon` detaches stderr** — `fprintf`/`NSLog` is not captured.
  Use `--fg-daemon` for any stderr logging.

Acceptance criteria:

1. **Daemon, `regular`:** start → `emacsclient -c` → close the frame → tile stays;
   **one** Dock click (or `open -a`) → a new frame appears; policy stays
   `Foreground` throughout.
2. **Daemon, `accessory`:** same, but the tile is gone after close (`BackgroundOnly`)
   yet a click still creates a frame *with a normal menu bar* (Regular restored).
3. **No `Prohibited`** ever appears post-close.
4. **First-click reopen:** a single Dock click produces the frame — no second click
   needed. Requires §3a, §4b and §4c together.
4a. **Repeated clicks each show a frame** (§4b): click three times on a frameless
   daemon and three frames appear, rather than one visible and two invisible ones
   that surface later when something else activates the app.
4b. **Reopen with a prompt open** (§4c): with one frame, `C-x C-f`, then `C-x 5 0`;
   one Dock click brings back a frame with the pending prompt in it, and typing
   goes to that frame. Before §4c the click was recorded and dropped.
5. **Daemon survives `C-x C-c` on a clientless frame** (Patch B): offers to save,
   deletes the frame, daemon keeps running — identically to a `nowait` frame.
6. **`server-stop-automatically` honored:** with it set, closing the last real frame
   shuts the daemon down — same for a Dock frame and a `nowait` frame.
7. **Non-daemon unchanged; ⌘Q / "Quit Emacs" still quit; `ns-confirm-quit`
   unchanged.**

---

## 7. Scope

In scope: the five commits above. Explicitly **out of scope**:

- **Non-daemon "stay alive frameless"** — *infeasible* without a hidden frame:
  `delete_frame` (`src/frame.c`) errors `"Attempt to delete the only frame"` even
  with `force`, and a non-daemon has no initial terminal frame, so it cannot run
  frameless. (`osx-pseudo-daemon` keeps a hidden frame for exactly this reason; for
  a daemon, this series makes that workaround unnecessary.)
- URL-scheme handling (`application:openURLs:` / `org-protocol://`).
- Any separate launcher app.

---

## 8. Compatibility / risk

- New behavior is reachable only on the NS port; defaults are the corrected
  behavior (`regular`, reopen-on, daemon-survives-clientless-close).
- The one behavior *change* for existing users: `C-x C-c` on a **non-client** frame
  in a **daemon** no longer kills the daemon (it deletes the frame). This is a
  fix — closing a Dock/`make-frame` frame silently killing the whole daemon was
  surprising — and `server-stop-automatically` is still honored, and explicit
  `kill-emacs` / ⌘Q still quit.
- `ns-confirm-quit` behavior is unchanged.

---

## 9. Commits

In branch order (A → B → C → cover letter → D → E):

```
A  ns: make a frameless daemon reopenable from the Dock   (src/nsterm.m, lisp/term/ns-win.el)
B  Don't let closing a clientless frame kill a daemon      (lisp/files.el, lisp/server.el)
C  ns: add ns-show-daemon-in-dock ...                      (lisp/term/ns-win.el)
D  ns: focus the frame the reopen gesture creates          (lisp/term/ns-win.el, src/nsterm.m)
E  Don't leave input bound to a keyboard that has no frames (src/frame.c, src/keyboard.c,
                                                            src/keyboard.h)
```

SHAs are deliberately omitted (the branch is rebased onto `master` periodically).
The cover letter sits in the middle of the series, so select the code commits by
subject rather than by a single range, and **drop the cover-letter commit**.

C is optional — a convenience API, not part of the core defect fix. A+B+D+E is the
smallest set that gives a working reopen. E stands on its own: two of its three
hunks are generic keyboard-lifetime bugs and could be filed separately from the
macOS work.

---

## 10. References

- `src/nsterm.m`: `ns_delete_terminal` (sets the frameless policy),
  `applicationShouldHandleReopen:` (new), `newFrame:`,
  `applicationDidFinishLaunching:` (the `Regular` upgrade), `terminate:` /
  `applicationShouldTerminate:` (`ns-confirm-quit`), `windowShouldClose:`.
- `lisp/term/ns-win.el`: `ns-new-frame` command + `special-event-map [ns-new-frame]`;
  `ns-setup-special-keys`; the two `defcustom` wrappers.
- `lisp/files.el`: `save-buffers-kill-terminal`. `lisp/server.el`:
  `server-save-buffers-kill-terminal-noclient`, `server-save-buffers-kill-terminal`.
- `lisp/frame.el`: `handle-delete-frame`. `src/frame.c`: `delete_frame`
  (sole-frame error → the non-daemon-frameless impossibility).
- Apple: `NSApplicationActivationPolicy`; `applicationShouldHandleReopen:hasVisibleWindows:`.
- Prior art: `osx-pseudo-daemon` (Lisp hidden-frame workaround); debbugs #79859
  (native macOS dock integration — upstream receptive).

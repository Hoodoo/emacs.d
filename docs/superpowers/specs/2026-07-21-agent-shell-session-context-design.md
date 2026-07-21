# Agent-shell session context (tab-per-session)

## Problem

Agent-driven development and incident-response work happens across an
agent-shell buffer plus a handful of supporting buffers — a terminal (eat),
a magit status/diff, sometimes a dired. Today these live as ordinary
buffers with no relationship to each other, so switching between two
concurrent tasks means manually hunting down and re-arranging the right
set of windows each time.

Goal: let an agent-shell session "carry" its supporting buffers, and make
switching between sessions a single action that restores the right set of
windows.

## Non-goals

- `agent-shell-fork` is explicitly out of scope. It stays exactly as it
  works today (no tab, no auto-tagging). Revisit only if fork usage picks
  up later.
- No cross-machine / persistence-across-restart story. This is in-memory,
  session-lifetime only.
- Not solving multiple buffers of the same type per session beyond what
  `window-sides-slots` already allows (currently `1 1 1 1`, one per side).

## Core idea: the agent-shell buffer *is* the session identity

No separate session-ID registry. A session is identified by its
agent-shell buffer object. Supporting buffers point back to it via a
buffer-local variable; there is no reverse index to keep in sync — the set
of buffers belonging to a session is always computed on demand by
scanning `(buffer-list)` for matches. This avoids stale-registry bugs
entirely, at the cost of an O(buffers) scan on the (rare, human-triggered)
operations that need it.

Two buffer-local variables:

- `hoodoo/session-buffer` (on context buffers) — the agent-shell buffer
  this buffer belongs to.
- `hoodoo/session-label` (on the agent-shell buffer) — the short label
  the user typed at session start; also the tab's name.

## Starting a session

`hoodoo/claude-start-in` and `hoodoo/codex-start-in` change to:

1. Prompt for a directory (as today).
2. Prompt for a short label, defaulting to the directory's basename.
3. Create a new `tab-bar` tab, name it the label, switch to it.
4. Dynamically bind a `hoodoo/session--pending-label` variable to the
   label, then call the existing start function
   (`agent-shell-anthropic-start-claude-code` /
   `agent-shell-openai-start-codex`) inside that `let` — mirroring how
   this config already dynamically binds `agent-shell-cwd-function` for
   the same start functions.
5. A function on `agent-shell-mode-hook` (added once, globally, at
   `use-package :config` time) reads `hoodoo/session--pending-label`. If
   set, it sets `hoodoo/session-label` buffer-locally on `(current-buffer)`
   and installs a buffer-local `kill-buffer-hook` (see Ending a session).
   This hook runs synchronously inside `agent-shell--start`, after
   buffer-local state is initialized and after the new-vs-resume strategy
   has resolved — before the `let` from step 4 unwinds — so it reliably
   fires exactly once per session, whether new or resumed. (Confirmed by
   reading `agent-shell--start` in `agent-shell.el`: `agent-shell-mode-hook`
   is documented as running "after the buffer-local state has been set
   up," unconditionally, regardless of session strategy.)

`hoodoo/session--pending-label` must be introduced with `defvar` (making it
special/dynamically-scoped) before it's `let`-bound, same as
`agent-shell-cwd-function` is a `defcustom` for the same reason — otherwise
the `let` in step 4 is lexical and invisible to the hook function in step 5.

`agent-shell-session-strategy` is already `'prompt` in this config, so the
existing new-vs-resume choice happens *inside* step 4 — this design does
not special-case resume. Every call to `hoodoo/claude-start-in` gets a
fresh tab regardless of whether the user ends up starting fresh or
resuming a past session.

## Building context

New commands, mirroring the existing eat/magit/dired entry points but
tagging the result:

- `hoodoo/session-eat`
- `hoodoo/session-magit-status`
- `hoodoo/session-dired`

Each:

1. Resolves "the session of the current tab" — the sole `agent-shell-mode`
   buffer displayed in a window of the current tab. `user-error`s with a
   clear message if none is found (e.g. run from a tab with no session).
2. Calls the underlying command/buffer creation as normal.
3. Displays the resulting buffer with `display-buffer` (not
   `switch-to-buffer` directly) so it's routed through the existing
   `auto-side-windows` global `display-buffer-alist` entry into the
   correct side window — no new layout code needed.
4. Sets `hoodoo/session-buffer` on the resulting buffer to the session
   buffer found in step 1.

`hoodoo/session-attach-buffer`:

1. Resolves the current tab's session buffer (same helper as above).
2. `completing-read` over live buffers (excluding the session buffer
   itself and buffers already tagged to *this* session).
3. If the chosen buffer is already tagged to a *different* session,
   confirm before overwriting.
4. Sets `hoodoo/session-buffer` on it.

## Switching sessions

Plain `tab-bar` navigation (`C-x t o`, or picking by name) — tabs are
meaningfully labeled now, so no dedicated picker command is needed.
`tab-bar` already persists each tab's window configuration, so whatever
arrangement you left a session's windows in (resized a side window,
moved something) comes back as-is.

## Ending a session

A buffer-local `kill-buffer-hook`, installed on the agent-shell buffer at
creation time, runs when that buffer is killed:

1. Collect attached buffers: all live buffers whose `hoodoo/session-buffer`
   equals this agent-shell buffer.
2. If none, do nothing further.
3. Otherwise present a multi-select (`completing-read-multiple` for v1)
   listing the attached buffers, pre-checked by type:
   - eat buffers: pre-checked (cheap to respawn)
   - magit-status buffers: pre-checked (cheap to reopen)
   - dired buffers: unchecked (likely mid-navigation, keep by default)
4. Kill whichever buffers the user confirms.
5. Close the session's tab (`tab-bar-close-tab`), since its reason for
   existing is gone. Only if the tab being closed is the current tab /
   still exists — guard defensively in case of unusual kill ordering.

Killing an attached buffer directly (not via the session) needs no special
handling — it just stops existing; nothing references it.

## Error handling / edge cases

- `hoodoo/session-*` commands invoked in a tab with no agent-shell buffer:
  `user-error` with a clear message, no silent no-op.
- Attaching a buffer already tagged to a different, still-live session:
  confirm before reassigning.
- Duplicate tab labels (e.g. two sessions both default to the same
  directory basename): allowed as-is; `tab-bar` doesn't require unique
  names. Can revisit if this proves confusing in practice.
- The `kill-buffer-hook` must tolerate being called when
  `tab-bar-mode` is off or the tab was already closed by other means —
  wrap the tab-close step so it degrades to a no-op rather than erroring.

## Testing approach

Real ACP agent processes can't be driven headlessly, so:

- Unit-level logic (tag propagation, "find session of current tab",
  "collect attached buffers", cleanup buffer-selection defaults) is
  tested in `emacs -Q --batch` scripts against plain buffers with
  `major-mode` set to `agent-shell-mode`/`eat-mode`/etc. — no real
  agent-shell session required, matching the approach used to verify the
  `auto-side-windows` fix earlier in this repo's history.
- Real agent-shell integration (steps that actually call
  `agent-shell-anthropic-start-claude-code`) gets a manual interactive
  pass, since it requires a live ACP agent process.

## Open items deferred, not blocking

- Whether `hoodoo/session-eat` (etc.) should reuse an existing tagged eat
  buffer in the current tab vs. always creating a new one — not decided;
  default to "reuse if one exists, else create," revisit if it's wrong
  in practice.
- Nicer cleanup UI (a `transient` menu instead of
  `completing-read-multiple`) — possible follow-up, not required for v1.

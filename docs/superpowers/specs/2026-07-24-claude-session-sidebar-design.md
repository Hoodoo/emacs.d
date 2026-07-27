# claude-session-sidebar — live session stats sidebar

## Problem

`claude-session-log.el` can parse a Claude Code session's JSONL log into
structured data (tokens, cost, models, files touched, branches, task-list),
but nothing renders it. The numbers aren't eyeball-able from the raw log,
and there's no reason to context-switch away from the agent-shell buffer
just to check them.

Goal: a small sidebar, in the style of `vulpea-ui`, that shows session
stats for "whatever agent-shell session is at point" and keeps itself
current while you work.

## Non-goals

- No dependency on `hoodoo-session-context` or any tab/session-management
  concept, same reasoning as `claude-session-log` itself: this resolves
  "the session at point" from ambient buffer/window state, not from
  tab-scoped session identity, so it keeps working regardless of how the
  tab-per-session workflow evolves.
- No support for non-Claude-Code agent-shell backends (e.g. a Codex
  session started via `hoodoo/codex-start-in`). Codex doesn't write
  Claude Code's JSONL format at all, so there is nothing to parse for it.
  This isn't special-cased — it falls out naturally: the constructed path
  won't exist, and "no session data" is already the correct behavior for
  that case (see Non-existent-file handling below).
- No file-watching, no `fd`. Both were considered and dropped: the session
  JSONL path is *constructed directly* from buffer-local `agent-shell`
  state (no search needed), and live-refresh is copied from
  `vulpea-ui`'s idle-timer + `vui-use-async` pattern rather than any
  filesystem-watching mechanism (see Live refresh below).
- Only one widget for v1 (stats: models, token totals, cost, duration).
  Task-list, files-touched, and branch widgets are deliberately deferred
  until there's a reason (real numbers looked at, real want identified) to
  build them — but the widget registry is designed so adding one later
  doesn't require touching core sidebar code.
- No generic "note at point" framework for arbitrary third-party
  consumers, unlike `vulpea-ui`. This is a purpose-built sidebar for one
  data source (`claude-session-log`), not a reusable chrome library.
  Revisit if a second consumer shows up.

## Session-at-point resolution

Mirrors `vulpea-ui`'s "note from buffer" pattern, reimplemented locally
(no dependency on `vulpea-ui` or `hoodoo-session-context`):

1. **Find the sole visible agent-shell buffer.** *(Revised after initial
   implementation — see below.)* Scan every window in the frame,
   including side windows (`(window-list frame 'no-mini)`, no
   `window-parameter`/`window-side` filtering), for buffers whose
   `major-mode` is `agent-shell-mode`, dedupe, and take the result if
   there is exactly one; more than one is ambiguous (no session), same
   as none. This mirrors `hoodoo-session-context.el`'s own
   `hoodoo/session--current-session-buffer`, reimplemented
   independently here (still no dependency on `hoodoo-session-context`
   itself). The initial implementation instead ported
   `vulpea-ui--get-main-window` (excluding all side windows, on the
   assumption that the "content" buffer is never itself a side
   window) — that assumption is false in this repo, whose own
   `init.el` config (`auto-side-windows-bottom-buffer-modes`)
   deliberately routes every `agent-shell-mode` buffer into a side
   window, so the original approach could never find a session at
   all. Discovered via live testing, fixed by replacing the main-window
   search with the algorithm described here.
2. **Confirm exactly one candidate was found.** If none or more than one
   agent-shell-mode buffer is visible, there is no session at point.
3. **Read session id and cwd from agent-shell's own buffer-local state**
   (confirmed present, no need to add tracking):
   - session-id: `(map-nested-elt (agent-shell--state) '(:session :id))`
   - cwd: `(agent-shell-cwd)`, called with that buffer current (it reads
     `default-directory`/project root, so it must run in the right buffer)
4. **Encode the cwd the way Claude Code's CLI does**, verified against two
   real project directories on this machine (`/home/hoooo/.emacs.d` →
   `-home-hoooo--emacs-d`, confirming both `/` and `.` map to `-`,
   independently, with no collapsing of resulting repeated dashes):
   `(replace-regexp-in-string "[/.]" "-" (expand-file-name cwd))`
5. **Construct the path directly**, no search:
   `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`
6. **Non-existent-file handling.** If session-id or cwd is nil, or the
   constructed path doesn't exist (session not yet flushed to disk, or an
   agent-shell buffer backed by a non-Claude-Code agent), there is no
   session data to show. The sidebar hides itself (see Window management)
   rather than showing an error.

Forward-declare `agent-shell--state`, `agent-shell-cwd`, and
`agent-shell-mode` the same way `hoodoo-session-context.el` does for
`agent-shell-mode-hook` — so this file loads standalone under test without
requiring the real `agent-shell` package.

## Window management

Direct port of `vulpea-ui`'s side-window chrome:

- Sidebar buffer named per-frame: `*claude-session-sidebar:<window-id>*`
  (mirrors `vulpea-ui--sidebar-buffer-name`).
- `defcustom claude-session-sidebar-position` (default `'right`) and
  `defcustom claude-session-sidebar-size` (default `0.33`) — same defaults
  and same semantics as `vulpea-ui-sidebar-position`/`-size`.
- Creating the window guarantees its side a slot in a *local copy* of
  `window-sides-slots` (same `--ensure-side-slot` logic as `vulpea-ui`),
  so the sidebar still appears even if the user's global
  `window-sides-slots` would otherwise refuse it — but the user has said
  they're fine tuning `window-sides-slots` by hand if slots run tight
  against `hoodoo-session-context`'s eat/magit/dired windows.
- Auto-show/auto-hide on `window-buffer-change-functions` and
  `window-selection-change-functions`, exactly like `vulpea-ui`: resolve
  the session at point (above) on every buffer/selection change; show and
  render if found, hide if not (and it was previously shown).
- `claude-session-sidebar-toggle`/`-open`/`-close` commands provided for
  manual control too, same shape as `vulpea-ui-sidebar-toggle`/etc.

## Widgets

A minimal registry, so more widgets can be added later without touching
core code:

```elisp
(defvar claude-session-sidebar--widgets nil
  "Alist of (id :component SYMBOL :order NUMBER).")

(defun claude-session-sidebar-register-widget (id &rest props)
  "Register a widget. PROPS is a plist: :component (a vui component
symbol) :order (a number, lower = earlier).")
```

The sidebar's root component renders registered widgets in `:order`,
passing each the resolved session path (or the parsed
`claude-session-log-session` struct, via `vui-use-async` — see below).

**v1's one widget: `claude-session-sidebar-widget-stats`.** Shows, for the
session at point:
- Models involved (list)
- Token totals (input/output/cache, aggregate — not broken out per model
  in v1; a per-model table is easy to add later if the aggregate isn't
  enough once real numbers are visible)
- Total cost (the "real cost" field, including subagents)
- Duration

## Live refresh

Copied from `vulpea-ui`'s pattern (confirmed by reading its source, not
guessed): a **repeating idle timer**
(`run-with-idle-timer claude-session-sidebar-auto-refresh-delay t ...`,
default delay `1.5`, matching `vulpea-ui-auto-refresh-delay`) drives
refresh while the sidebar is visible. No file-watching, no polling
library — the timer just triggers a re-render; `vui`'s own reconciliation
means unchanged content doesn't redraw.

The stats widget wraps its data load in `vui-use-async`, keyed on
`(path . mtime)` where `mtime` is `file-attribute-modification-time` on
the JSONL file. Since `vui-use-async` only re-invokes its loader when the
key changes, this means: no re-parse (and no re-render) happens unless the
file actually grew since the last check — the exact "redraws only if
changed" behavior from the original findings notes, achieved as a side
effect of `vui-use-async`'s own caching rather than any bespoke diffing.
`vui-use-async`'s `:status` (`pending`/`ready`/`error`) plist gives the
"keep last good view, dim a status indicator on a failed read, retry next
tick" resilience from those same notes for free — worth using even though
`claude-session-log-parse-file` is normally fast/synchronous, since a
truncated read mid-write (the same append-only-file race
`claude-session-log--read-jsonl-lines` already tolerates at the line
level) should degrade gracefully here too, not flicker an error into the
sidebar.

The idle timer starts when the sidebar becomes visible and stops when it's
hidden or killed (mirrors `vulpea-ui--start-idle-timer`/`--stop-idle-timer`,
tied to this sidebar's own visibility, not global).

## Testing approach

- Window/resolution logic (main-window detection, path construction,
  cwd-encoding, non-existent-file handling) is testable in
  `emacs -Q --batch`, the same way `hoodoo-session-context-test.el` tests
  window logic: fake buffers with `major-mode` set to `agent-shell-mode`,
  `agent-shell--state`/`agent-shell-cwd` stubbed via `cl-letf`, no real
  agent-shell process needed.
- Widget rendering (the actual `vui` mount/render) needs an interactive
  pass, same caveat `hoodoo-session-context`'s design doc already notes
  for anything requiring a live ACP agent process — except here the
  caveat is about `vui` rendering, not ACP, so it's a lighter manual check
  (mount the component against a real or fixture `claude-session-log-session`
  struct and eyeball it).

## Open items deferred, not blocking

- Per-model token/cost breakdown in the stats widget (aggregate only for
  v1) — add once aggregate numbers turn out insufficient.
- Task-list, files-touched, branches widgets — deferred per Non-goals.
- What happens when multiple frames each have their own sidebar instance
  showing different sessions — `vulpea-ui`'s per-frame instance hash table
  pattern is copied as-is and should just work, but hasn't been exercised
  here yet.

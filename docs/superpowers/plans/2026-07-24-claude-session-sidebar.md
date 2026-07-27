# claude-session-sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `claude-session-sidebar.el`, a `vui.el`-based sidebar that
shows `claude-session-log` stats for "whatever agent-shell session is at
point," auto-showing/hiding and auto-refreshing the way `vulpea-ui.el`
does for org notes.

**Architecture:** One file, ported piece-by-piece from `vulpea-ui.el`
(window chrome, auto-show/hide, idle-timer refresh) with `vulpea-ui`'s own
"note" concept replaced by "resolved session JSONL path." A small widget
registry holds one built-in widget (`claude-session-sidebar-widget-stats`)
for v1. No dependency on `hoodoo-session-context` or `vulpea-ui` — this is
a standalone port, not a shared library.

**Tech Stack:** `vui.el` (component/render/async primitives), Emacs
built-ins (`map`, `cl-lib`, `seq`), and this repo's own `claude-session-log`
for parsing. Forward-declares `agent-shell`'s functions/mode (does not
`require` it) so this file loads standalone under test, same convention as
`hoodoo-session-context.el`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-24-claude-session-sidebar-design.md`.
- Library file: `claude-session-sidebar.el` at the repo root (same
  placement as `hoodoo-session-context.el`/`claude-session-log.el`).
- Test file: `tests/claude-session-sidebar-test.el`.
- Test run command (confirmed working in this repo — `vui` needs an
  explicit `-L` since it's not on the default batch load-path,
  `claude-session-log.el` needs an explicit `-l` since it's a dependency,
  not just a test fixture):
  `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`
- **Verified, not guessed, API facts this plan depends on** (each checked
  directly against `agent-shell.el`/`vui.el` source or by running real
  code in `emacs -Q --batch` before writing this plan):
  - `agent-shell--state` is a **function** (agent-shell.el:5310), not a
    bare variable reference — despite there also being a `defvar-local`
    of the same name for storage (Lisp-2: separate function/variable
    namespaces). The function `(agent-shell--state)` must be called with
    the target buffer as `current-buffer` — it signals an error if that
    buffer isn't `agent-shell-mode`-derived, and signals if the state is
    nil. Always call it inside `(with-current-buffer buf ...)` and treat
    any signal as "no session info," never let it escape.
  - `(agent-shell-cwd)` (agent-shell-project.el:67) must also be called
    with the target buffer as `current-buffer` — it falls through
    `projectile-project-root` / `project-root` / `default-directory`, all
    of which are only meaningful relative to the buffer that's current.
  - Claude Code's on-disk directory-encoding scheme, verified against two
    real project directories on this machine: replace every `/` and every
    `.` in the expanded cwd with `-`, independently (no collapsing) —
    `(replace-regexp-in-string "[/.]" "-" (expand-file-name cwd))`.
  - `map-nested-elt` (built-in, `map.el`) is used for reading
    `agent-shell--state` rather than `plist-get`, because that state's
    internal shape is alist-based in places (built via `cons`, not a flat
    plist) — `map-nested-elt` works across both representations.
  - `display-buffer-in-side-window`, `vui-mount`, `switch-to-buffer`, and
    `select-window` all work correctly in plain `emacs -Q --batch` — no
    real display/frame is needed, confirmed by running each directly.
    This means widget-rendering tests in this plan are real automated
    tests, not "needs an interactive pass" as the design doc's Testing
    Approach section speculated before this was checked — the design
    doc's speculation was conservative; write real tests per task instead.
  - `vui-mount` returns a `vui-instance` struct with accessor
    `vui-instance-buffer`; `vui-update-props` reuses an instance without
    invalidating memos, `vui-update` invalidates them — use
    `vui-update-props` for the soft/idle refresh path.
  - `vui-use-async`'s `KEY` argument is a normal (unquoted) Lisp
    expression re-evaluated each render and compared with `equal` to the
    previous key — not a literal quoted symbol. Its `LOADER` is called
    immediately (synchronously) unless it itself starts an async process;
    our loader is synchronous (`claude-session-log-parse-file` is cheap).
- No `require 'agent-shell'` anywhere in the library or its tests — only
  `declare-function`/`defvar` forward declarations, mirroring
  `hoodoo-session-context.el`'s existing pattern in this repo.
- No file-watching, no `fd`, no live polling beyond the idle timer
  described in the design doc.

---

### Task 1: Session-at-point resolution

**Files:**
- Create: `claude-session-sidebar.el`
- Test: `tests/claude-session-sidebar-test.el`

**Interfaces:**
- Produces: `claude-session-sidebar--get-main-window (&optional frame)`,
  `claude-session-sidebar--session-info-from-buffer (buffer)` (returns
  `(session-id . cwd)` cons or nil), `claude-session-sidebar--encode-cwd
  (cwd)` (string), `claude-session-sidebar--session-jsonl-path (session-id
  encoded-cwd)` (string), `claude-session-sidebar--resolve-session-path
  (&optional frame)` (string path or nil — the orchestrator this task's
  other functions feed into).
- Consumes: nothing from later tasks. `claude-session-sidebar--get-main-
  window` references `claude-session-sidebar--get-sidebar-window` (Task
  2's function) to exclude the sidebar's own window, matching
  `vulpea-ui--get-main-window`'s exact structure — but since Task 2
  doesn't exist yet, this task defines
  `claude-session-sidebar--get-sidebar-window` as a **forward stub**
  (`(defun claude-session-sidebar--get-sidebar-window (&optional _frame)
  nil)`) that Task 2 will replace with the real implementation. Task 1's
  tests must not depend on the stub's behavior (a nil sidebar window is
  indistinguishable from "no sidebar exists yet," which is the correct
  state during Task 1 anyway).

- [ ] **Step 1: Write the failing tests**

Create `tests/claude-session-sidebar-test.el`:

```elisp
;;; claude-session-sidebar-test.el --- Tests for claude-session-sidebar -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(ert-deftest claude-session-sidebar-test-get-main-window-prefers-selected ()
  (let ((buf (generate-new-buffer "main")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer buf)
          (should (eq (claude-session-sidebar--get-main-window) (selected-window))))
      (kill-buffer buf)
      (delete-other-windows))))

(ert-deftest claude-session-sidebar-test-get-main-window-skips-side-windows ()
  (let ((buf (generate-new-buffer "main"))
        (side-buf (generate-new-buffer "side")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer buf)
          (let ((main-win (selected-window))
                (side-win (display-buffer-in-side-window
                           side-buf '((side . right) (slot . 0)))))
            (select-window side-win)
            (should (eq (claude-session-sidebar--get-main-window) main-win))))
      (mapc #'kill-buffer (list buf side-buf))
      (delete-other-windows))))

(ert-deftest claude-session-sidebar-test-session-info-from-buffer-non-agent-shell ()
  (let ((buf (generate-new-buffer "plain")))
    (unwind-protect
        (should (null (claude-session-sidebar--session-info-from-buffer buf)))
      (kill-buffer buf))))

(ert-deftest claude-session-sidebar-test-session-info-from-buffer-agent-shell ()
  (let ((buf (generate-new-buffer "agent")))
    (unwind-protect
        (with-current-buffer buf
          (setq major-mode 'agent-shell-mode)
          (setq default-directory "/tmp/some-project/")
          (cl-letf (((symbol-function 'agent-shell--state)
                     (lambda () (list :session (list :id "abc-123")))))
            (should (equal (claude-session-sidebar--session-info-from-buffer buf)
                           (cons "abc-123" "/tmp/some-project/")))))
      (kill-buffer buf))))

(ert-deftest claude-session-sidebar-test-session-info-from-buffer-state-error ()
  "A signal from `agent-shell--state' (e.g. \"No shell state available\")
must be treated as \"no session info\", never let escape."
  (let ((buf (generate-new-buffer "agent")))
    (unwind-protect
        (with-current-buffer buf
          (setq major-mode 'agent-shell-mode)
          (cl-letf (((symbol-function 'agent-shell--state)
                     (lambda () (error "No shell state available"))))
            (should (null (claude-session-sidebar--session-info-from-buffer buf)))))
      (kill-buffer buf))))

(ert-deftest claude-session-sidebar-test-encode-cwd ()
  ;; Verified against two real directories on this machine.
  (should (equal (claude-session-sidebar--encode-cwd "/home/hoooo/.emacs.d")
                 "-home-hoooo--emacs-d"))
  (should (equal (claude-session-sidebar--encode-cwd "/home/hoooo/AISlop/codex-adventure-game-prolog")
                 "-home-hoooo-AISlop-codex-adventure-game-prolog")))

(ert-deftest claude-session-sidebar-test-session-jsonl-path ()
  (should (equal (claude-session-sidebar--session-jsonl-path "abc-123" "-home-hoooo--emacs-d")
                 (expand-file-name "abc-123.jsonl"
                                   (expand-file-name "-home-hoooo--emacs-d"
                                                      "~/.claude/projects/")))))

(ert-deftest claude-session-sidebar-test-resolve-session-path-no-agent-shell-buffer ()
  (let ((buf (generate-new-buffer "plain")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer buf)
          (should (null (claude-session-sidebar--resolve-session-path))))
      (kill-buffer buf)
      (delete-other-windows))))

(ert-deftest claude-session-sidebar-test-resolve-session-path-nonexistent-file ()
  (let ((buf (generate-new-buffer "agent")))
    (unwind-protect
        (with-current-buffer buf
          (setq major-mode 'agent-shell-mode)
          (setq default-directory "/tmp/")
          (delete-other-windows)
          (switch-to-buffer buf)
          (cl-letf (((symbol-function 'agent-shell--state)
                     (lambda () (list :session (list :id "no-such-session-id-xyz")))))
            (should (null (claude-session-sidebar--resolve-session-path)))))
      (kill-buffer buf)
      (delete-other-windows))))

(ert-deftest claude-session-sidebar-test-resolve-session-path-existing-file ()
  (let* ((buf (generate-new-buffer "agent"))
         (project-dir (make-temp-file "claude-session-sidebar-test" t))
         (claude-dir (expand-file-name
                      (claude-session-sidebar--encode-cwd project-dir)
                      "~/.claude/projects/"))
         (jsonl-path (expand-file-name "session-xyz.jsonl" claude-dir)))
    (unwind-protect
        (progn
          (make-directory claude-dir t)
          (with-temp-file jsonl-path (insert "{\"type\":\"user\"}\n"))
          (with-current-buffer buf
            (setq major-mode 'agent-shell-mode)
            (setq default-directory project-dir)
            (delete-other-windows)
            (switch-to-buffer buf)
            (cl-letf (((symbol-function 'agent-shell--state)
                       (lambda () (list :session (list :id "session-xyz")))))
              (should (equal (claude-session-sidebar--resolve-session-path) jsonl-path)))))
      (kill-buffer buf)
      (delete-other-windows)
      (when (file-exists-p jsonl-path) (delete-file jsonl-path))
      (when (file-directory-p claude-dir) (delete-directory claude-dir))
      (when (file-directory-p project-dir) (delete-directory project-dir t)))))

(provide 'claude-session-sidebar-test)
;;; claude-session-sidebar-test.el ends here
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: fails to load — `claude-session-sidebar.el` does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `claude-session-sidebar.el`:

```elisp
;;; claude-session-sidebar.el --- Sidebar for claude-session-log -*- lexical-binding: t; -*-

;;; Commentary:
;; A `vui.el' sidebar showing `claude-session-log' stats for the
;; agent-shell session at point. Ported from `vulpea-ui.el''s window
;; chrome and auto-show/hide/refresh pattern, with `vulpea-ui''s "note"
;; concept replaced by "resolved session JSONL path."
;; See docs/superpowers/specs/2026-07-24-claude-session-sidebar-design.md

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'claude-session-log)

;; Forward declarations so this file loads standalone (e.g. under test,
;; without the real `agent-shell' package present), mirroring the same
;; pattern already used by `hoodoo-session-context.el' in this repo.
(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell-cwd "agent-shell-project")
(unless (boundp 'agent-shell-mode)
  (defvar agent-shell-mode nil))

;; Task 2 will replace this stub with the real sidebar-window lookup.
;; A nil return is indistinguishable from "no sidebar exists yet", which
;; is correct for this task.
(defun claude-session-sidebar--get-sidebar-window (&optional _frame)
  nil)

(defun claude-session-sidebar--get-main-window (&optional frame)
  "Get the most recently used main window in FRAME.
A main window is a live, non-minibuffer window that is neither this
sidebar nor any other side window. Ported from
`vulpea-ui--get-main-window'."
  (let* ((frame (or frame (selected-frame)))
         (sidebar-win (claude-session-sidebar--get-sidebar-window frame))
         (selected (frame-selected-window frame))
         (mainp (lambda (win)
                  (and (not (eq win sidebar-win))
                       (not (window-parameter win 'window-side))
                       (not (window-minibuffer-p win))))))
    (if (and selected (funcall mainp selected))
        selected
      (or (car (sort (seq-filter mainp (window-list frame nil))
                     (lambda (a b)
                       (> (window-use-time a) (window-use-time b)))))
          (frame-first-window frame)))))

(defun claude-session-sidebar--session-info-from-buffer (buffer)
  "Return (SESSION-ID . CWD) for BUFFER, or nil.
Nil when BUFFER isn't `agent-shell-mode'-derived, or when
`agent-shell--state' has no session id (including when it signals --
that signal is swallowed here, never allowed to escape)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-shell-mode)
        (when-let* ((state (ignore-errors (agent-shell--state)))
                    (session-id (map-nested-elt state '(:session :id))))
          (cons session-id (agent-shell-cwd)))))))

(defun claude-session-sidebar--encode-cwd (cwd)
  "Encode CWD the way Claude Code's CLI names its project directories:
every `/' and `.' in the expanded path becomes `-', independently (no
collapsing of resulting repeated dashes)."
  (replace-regexp-in-string "[/.]" "-" (expand-file-name cwd)))

(defun claude-session-sidebar--session-jsonl-path (session-id encoded-cwd)
  "Return the JSONL path for SESSION-ID under Claude's ENCODED-CWD dir."
  (expand-file-name (concat session-id ".jsonl")
                     (expand-file-name encoded-cwd "~/.claude/projects/")))

(defun claude-session-sidebar--resolve-session-path (&optional frame)
  "Return the JSONL path for the session at point in FRAME, or nil.
Nil when the main window's buffer isn't an agent-shell session, or when
the constructed path doesn't exist on disk yet (session not flushed,
or a non-Claude-Code agent-shell backend)."
  (when-let* ((main-win (claude-session-sidebar--get-main-window frame))
              (buf (window-buffer main-win))
              (info (claude-session-sidebar--session-info-from-buffer buf))
              (path (claude-session-sidebar--session-jsonl-path
                     (car info)
                     (claude-session-sidebar--encode-cwd (cdr info)))))
    (when (file-exists-p path)
      path)))

(provide 'claude-session-sidebar)
;;; claude-session-sidebar.el ends here
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 9 tests, 9 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-sidebar.el tests/claude-session-sidebar-test.el
git commit -m "$(cat <<'EOF'
Add claude-session-sidebar session-at-point resolution

Ports vulpea-ui's main-window detection and adds direct JSONL-path
construction from agent-shell's own buffer-local state (session id +
cwd), with Claude Code's real directory-encoding scheme verified
against two real project directories on this machine.
EOF
)"
```

---

### Task 2: Window management chrome

**Files:**
- Modify: `claude-session-sidebar.el`
- Test: `tests/claude-session-sidebar-test.el`

**Interfaces:**
- Consumes: nothing new from Task 1's interfaces (this task replaces the
  Task 1 stub for `claude-session-sidebar--get-sidebar-window`).
- Produces: `claude-session-sidebar-position` / `-size` (defcustoms),
  `claude-session-sidebar--sidebar-buffer-name (&optional frame)`,
  `claude-session-sidebar--get-sidebar-buffer (&optional frame)`,
  `claude-session-sidebar--get-sidebar-window (&optional frame)`
  (**replaces Task 1's stub of the same name**), `claude-session-sidebar--
  sidebar-visible-p (&optional frame)`, `claude-session-sidebar--create-
  sidebar-window (buffer)`, `claude-session-sidebar--hide-sidebar-window
  (&optional frame)`, `claude-session-sidebar--show-sidebar-window
  (&optional frame)`, `claude-session-sidebar-mode` (major mode, derived
  from `vui-mode`), `claude-session-sidebar-mode-map`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/claude-session-sidebar-test.el` (before `provide`):

```elisp
(ert-deftest claude-session-sidebar-test-create-sidebar-window-when-side-disabled ()
  "Sidebar window is created even when its side is disabled -- same
regression this pattern already guards against in vulpea-ui (vulpea-journal#21)."
  (let ((window-sides-slots '(1 0 0 1))   ; right side disabled
        (claude-session-sidebar-position 'right))
    (save-window-excursion
      (let* ((buf (get-buffer-create " *claude-session-sidebar-test*"))
             (win (claude-session-sidebar--create-sidebar-window buf)))
        (unwind-protect
            (progn
              (should (window-live-p win))
              (should (eq (window-parameter win 'window-side) 'right)))
          (when (window-live-p win) (ignore-errors (delete-window win)))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest claude-session-sidebar-test-hide-sidebar-window-keeps-non-side-window ()
  (save-window-excursion
    (let ((buf (get-buffer-create (claude-session-sidebar--sidebar-buffer-name))))
      (unwind-protect
          (progn
            (switch-to-buffer buf)
            (let ((win (selected-window)))
              (should (eq (claude-session-sidebar--get-sidebar-window) win))
              (should-not (window-parameter win 'window-side))
              (claude-session-sidebar--hide-sidebar-window)
              (should (window-live-p win))
              (should (eq (window-buffer win) buf))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest claude-session-sidebar-test-hide-sidebar-window-deletes-side-window ()
  (save-window-excursion
    (let* ((buf (get-buffer-create (claude-session-sidebar--sidebar-buffer-name)))
           (win (display-buffer-in-side-window buf '((side . right) (slot . 0)))))
      (unwind-protect
          (progn
            (should (eq (claude-session-sidebar--get-sidebar-window) win))
            (claude-session-sidebar--hide-sidebar-window)
            (should-not (window-live-p win)))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest claude-session-sidebar-test-sidebar-visible-p ()
  (save-window-excursion
    (let* ((buf (get-buffer-create (claude-session-sidebar--sidebar-buffer-name)))
           (win (display-buffer-in-side-window buf '((side . right) (slot . 0)))))
      (unwind-protect
          (should (claude-session-sidebar--sidebar-visible-p))
        (delete-window win)
        (should-not (claude-session-sidebar--sidebar-visible-p))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest claude-session-sidebar-test-mode-derives-from-vui-mode ()
  (let ((buf (generate-new-buffer "sidebar-mode-test")))
    (unwind-protect
        (with-current-buffer buf
          (claude-session-sidebar-mode)
          (should (derived-mode-p 'vui-mode)))
      (kill-buffer buf))))
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: the 9 earlier tests still pass; the 5 new tests fail (`void-function` for the window helpers, `void-function`/mode-undefined for the mode test).

- [ ] **Step 3: Write the implementation**

Replace the Task 1 stub:

```elisp
;; Task 2 will replace this stub with the real sidebar-window lookup.
;; A nil return is indistinguishable from "no sidebar exists yet", which
;; is correct for this task.
(defun claude-session-sidebar--get-sidebar-window (&optional _frame)
  nil)
```

with (require `'vui` here, since this task's mode definition needs it):

```elisp
(require 'vui)

(defcustom claude-session-sidebar-position 'right
  "Position of the sidebar in the frame.
One of `left', `right', `top', or `bottom'."
  :type '(choice (const :tag "Left" left)
          (const :tag "Right" right)
          (const :tag "Top" top)
          (const :tag "Bottom" bottom))
  :group 'claude-session-sidebar)

(defcustom claude-session-sidebar-size 0.33
  "Size of the sidebar window (width if left/right, height if top/bottom)."
  :type 'number
  :group 'claude-session-sidebar)

(defun claude-session-sidebar--sidebar-buffer-name (&optional frame)
  "Return the sidebar buffer name for FRAME."
  (let ((frame (or frame (selected-frame))))
    (format "*claude-session-sidebar:%s*" (or (frame-parameter frame 'window-id) ""))))

(defun claude-session-sidebar--get-sidebar-buffer (&optional frame)
  "Get the sidebar buffer for FRAME, or nil if it doesn't exist."
  (get-buffer (claude-session-sidebar--sidebar-buffer-name frame)))

(defun claude-session-sidebar--get-sidebar-window (&optional frame)
  "Get the sidebar window for FRAME, or nil if it doesn't exist."
  (let ((buf (claude-session-sidebar--get-sidebar-buffer frame)))
    (when buf (get-buffer-window buf frame))))

(defun claude-session-sidebar--sidebar-visible-p (&optional frame)
  "Return non-nil if the sidebar is visible in FRAME."
  (claude-session-sidebar--get-sidebar-window frame))

(defun claude-session-sidebar--display-buffer-params ()
  "Return `display-buffer' parameters for the sidebar."
  (let ((side claude-session-sidebar-position)
        (size claude-session-sidebar-size))
    `((side . ,side)
      (slot . 0)
      (window-width . ,(if (memq side '(left right)) size nil))
      (window-height . ,(if (memq side '(top bottom)) size nil))
      (window-parameters . ((no-delete-other-windows . t)
                            (dedicated . t)
                            (no-other-window . nil))))))

(defun claude-session-sidebar--ensure-side-slot (slots side)
  "Return SLOTS with SIDE guaranteed at least one available slot.
Ported from `vulpea-ui--ensure-side-slot'."
  (let ((idx (pcase side
               ('left 0) ('top 1) ('right 2) ('bottom 3)
               (_ (error "Invalid side: %S" side))))
        (slots (copy-sequence slots)))
    (let ((cur (nth idx slots)))
      (when (and (numberp cur) (< cur 1))
        (setf (nth idx slots) 1)))
    slots))

(defun claude-session-sidebar--create-sidebar-window (buffer)
  "Create a sidebar window for BUFFER using side window mechanics.
Ported from `vulpea-ui--create-sidebar-window'."
  (let ((window-sides-slots
         (claude-session-sidebar--ensure-side-slot
          window-sides-slots claude-session-sidebar-position)))
    (display-buffer-in-side-window buffer (claude-session-sidebar--display-buffer-params))))

(defun claude-session-sidebar--hide-sidebar-window (&optional frame)
  "Hide the sidebar window in FRAME without killing the buffer.
Only an actual side window is deleted, mirroring
`vulpea-ui--hide-sidebar-window'."
  (let ((win (claude-session-sidebar--get-sidebar-window frame)))
    (when (and (window-live-p win) (window-parameter win 'window-side))
      (delete-window win))))

(defun claude-session-sidebar--show-sidebar-window (&optional frame)
  "Show the sidebar window in FRAME."
  (let ((buf (claude-session-sidebar--get-sidebar-buffer frame)))
    (when (and buf (not (claude-session-sidebar--sidebar-visible-p frame)))
      (claude-session-sidebar--create-sidebar-window buf))))

(defvar claude-session-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'claude-session-sidebar-close)
    (define-key map (kbd "g") #'claude-session-sidebar-refresh)
    map)
  "Keymap for `claude-session-sidebar-mode'.")

(define-derived-mode claude-session-sidebar-mode vui-mode "claude-session-sidebar"
  "Major mode for the claude-session-sidebar buffer.
\\{claude-session-sidebar-mode-map}"
  :group 'claude-session-sidebar
  (setq-local truncate-lines t))
```

`claude-session-sidebar-close` and `claude-session-sidebar-refresh` are
referenced in the keymap but defined in Task 6 — declare them now so
byte-compilation doesn't warn:

```elisp
(declare-function claude-session-sidebar-close "claude-session-sidebar")
(declare-function claude-session-sidebar-refresh "claude-session-sidebar")
```

Add that `declare-function` pair right after the `(require 'vui)` line.

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 14 tests, 14 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-sidebar.el tests/claude-session-sidebar-test.el
git commit -m "Add claude-session-sidebar window management chrome"
```

---

### Task 3: Widget registry

**Files:**
- Modify: `claude-session-sidebar.el`
- Test: `tests/claude-session-sidebar-test.el`

**Interfaces:**
- Produces: `claude-session-sidebar-register-widget (id &rest props)`,
  `claude-session-sidebar--ordered-widgets ()` (returns the registry
  sorted by `:order`, ascending).

- [ ] **Step 1: Write the failing tests**

Append to `tests/claude-session-sidebar-test.el`:

```elisp
(ert-deftest claude-session-sidebar-test-register-and-order-widgets ()
  (let ((claude-session-sidebar--widgets nil))
    (claude-session-sidebar-register-widget 'b :component 'widget-b :order 20)
    (claude-session-sidebar-register-widget 'a :component 'widget-a :order 10)
    (should (equal (mapcar #'car (claude-session-sidebar--ordered-widgets))
                   '(a b)))))

(ert-deftest claude-session-sidebar-test-register-widget-overwrites ()
  (let ((claude-session-sidebar--widgets nil))
    (claude-session-sidebar-register-widget 'a :component 'widget-a :order 10)
    (claude-session-sidebar-register-widget 'a :component 'widget-a-v2 :order 10)
    (should (= (length claude-session-sidebar--widgets) 1))
    (should (equal (plist-get (cdr (assq 'a claude-session-sidebar--widgets)) :component)
                   'widget-a-v2))))
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: the 14 earlier tests still pass; the 2 new tests fail with
`void-variable claude-session-sidebar--widgets`.

- [ ] **Step 3: Write the implementation**

Add to `claude-session-sidebar.el` (after the mode definition):

```elisp
(defvar claude-session-sidebar--widgets nil
  "Alist of (ID :component SYMBOL :order NUMBER).")

(defun claude-session-sidebar-register-widget (id &rest props)
  "Register a sidebar widget under ID.
PROPS is a plist: :component (a `vui-defcomponent' symbol taking a
single :path prop) and :order (a number; lower renders earlier).
Registering under an existing ID replaces its entry."
  (setf (alist-get id claude-session-sidebar--widgets) props))

(defun claude-session-sidebar--ordered-widgets ()
  "Return `claude-session-sidebar--widgets' sorted by :order, ascending."
  (sort (copy-alist claude-session-sidebar--widgets)
        (lambda (a b) (< (or (plist-get (cdr a) :order) 0)
                          (or (plist-get (cdr b) :order) 0)))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 16 tests, 16 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-sidebar.el tests/claude-session-sidebar-test.el
git commit -m "Add claude-session-sidebar widget registry"
```

---

### Task 4: Stats widget

**Files:**
- Modify: `claude-session-sidebar.el`
- Test: `tests/claude-session-sidebar-test.el`

**Interfaces:**
- Consumes: `claude-session-log-parse-file` and its struct accessors
  (from `claude-session-log.el`, already required at file top); `vui-use-
  ref`, `vui-use-async`, `vui-defcomponent`, `vui-vstack`, `vui-text`,
  `vui-muted` (from `vui.el`).
- Produces: `claude-session-sidebar--aggregate-tokens (session)` (returns
  `(input . output)`), `claude-session-sidebar--render-stats (session)`
  (a vnode), `claude-session-sidebar--stats-display-data (status path
  fresh last-ref)` (the stale-on-error decision helper, mirrors
  `vulpea-ui--mentions-display-data`), `claude-session-sidebar-widget-
  stats` (the `vui-defcomponent`, taking a `path` prop).

- [ ] **Step 1: Write the failing tests**

Append to `tests/claude-session-sidebar-test.el`:

```elisp
(ert-deftest claude-session-sidebar-test-aggregate-tokens ()
  (let ((session (make-claude-session-log-session
                  :usage-by-model
                  (list (cons "claude-sonnet-5" '(:input 100 :output 50 :cache-write-5m 0
                                                  :cache-write-1h 0 :cache-read 0))
                        (cons "claude-haiku-4-5" '(:input 10 :output 5 :cache-write-5m 0
                                                   :cache-write-1h 0 :cache-read 0))))))
    (should (equal (claude-session-sidebar--aggregate-tokens session) '(110 . 55)))))

;; NOTE: these four tests build LAST-REF as a plain `(cons nil nil)',
;; NOT via `(vui-use-ref nil)'. `vui-use-ref' signals "called outside
;; of component context" unless called from inside an active
;; component render (verified against vui.el's source:
;; `vui--get-or-create-ref' checks `vui--current-instance' and errors
;; if nil) -- these are unit tests of the pure decision helper, not of
;; the component, so they construct the cons cell `vui-use-ref' would
;; have handed back rather than going through vui's render machinery.
;; The real component (this task's `vui-defcomponent', tested by
;; `claude-session-sidebar-test-widget-stats-renders-real-session'
;; below via `vui-mount') does call the real `vui-use-ref'.

(ert-deftest claude-session-sidebar-test-stats-display-data-ready ()
  (let* ((last-ref (cons nil nil))
         (fresh (make-claude-session-log-session :session-id "s1"))
         (decision (claude-session-sidebar--stats-display-data 'ready "path1" fresh last-ref)))
    (should (eq (car decision) 'shown))
    (should (eq (cdr decision) fresh))
    (should (equal (car last-ref) (cons "path1" fresh)))))

(ert-deftest claude-session-sidebar-test-stats-display-data-error-with-cache ()
  (let* ((last-ref (cons nil nil))
         (fresh (make-claude-session-log-session :session-id "s1")))
    (claude-session-sidebar--stats-display-data 'ready "path1" fresh last-ref)
    (let ((decision (claude-session-sidebar--stats-display-data 'error "path1" nil last-ref)))
      (should (eq (car decision) 'shown))
      (should (eq (cdr decision) fresh)))))

(ert-deftest claude-session-sidebar-test-stats-display-data-error-no-cache ()
  (let* ((last-ref (cons nil nil))
         (decision (claude-session-sidebar--stats-display-data 'error "path1" nil last-ref)))
    (should (eq (car decision) 'error))))

(ert-deftest claude-session-sidebar-test-stats-display-data-pending-no-cache ()
  (let* ((last-ref (cons nil nil))
         (decision (claude-session-sidebar--stats-display-data 'pending "path1" nil last-ref)))
    (should (eq (car decision) 'loading))))

(ert-deftest claude-session-sidebar-test-widget-stats-renders-real-session ()
  (let* ((dir (make-temp-file "claude-session-sidebar-test" t))
         (path (expand-file-name "sess.jsonl" dir)))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert (concat "{\"type\":\"assistant\",\"timestamp\":\"2026-07-21T10:00:00.000Z\","
                            "\"message\":{\"role\":\"assistant\",\"model\":\"claude-sonnet-5\","
                            "\"content\":[],\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}\n")))
          (let ((instance (vui-mount (vui-component 'claude-session-sidebar-widget-stats :path path)
                                      "*claude-session-sidebar-widget-test*")))
            (unwind-protect
                (with-current-buffer (vui-instance-buffer instance)
                  (should (string-match-p "claude-sonnet-5" (buffer-string)))
                  (should (string-match-p "100" (buffer-string))))
              (kill-buffer (vui-instance-buffer instance)))))
      (delete-directory dir t))))
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: the 16 earlier tests still pass; the 6 new tests fail (`void-function` for the missing helpers/component).

- [ ] **Step 3: Write the implementation**

Add to `claude-session-sidebar.el` (after the widget registry):

```elisp
(defun claude-session-sidebar--aggregate-tokens (session)
  "Return (INPUT . OUTPUT) token totals summed across every model in SESSION."
  (let ((input 0) (output 0))
    (dolist (entry (claude-session-log-session-usage-by-model session))
      (setq input (+ input (plist-get (cdr entry) :input)))
      (setq output (+ output (plist-get (cdr entry) :output))))
    (cons input output)))

(defun claude-session-sidebar--render-stats (session)
  "Render SESSION (a `claude-session-log-session') as a stats vnode."
  (let ((tokens (claude-session-sidebar--aggregate-tokens session)))
    (vui-vstack
     (vui-text (format "Models: %s"
                       (string-join (claude-session-log-session-models session) ", "))
       :face 'bold)
     (vui-text (format "Duration: %.0fs"
                       (or (claude-session-log-session-duration-seconds session) 0)))
     (vui-text (format "Tokens: %d in / %d out" (car tokens) (cdr tokens)))
     (vui-text (format "Total cost: $%.4f"
                       (or (claude-session-log-session-total-cost session) 0.0))))))

(defun claude-session-sidebar--stats-display-data (status path fresh last-ref)
  "Decide which session struct to render and keep LAST-REF in sync.

STATUS is the `vui-use-async' status for PATH. FRESH is the freshly
loaded `claude-session-log-session', meaningful when STATUS is `ready'.
LAST-REF is a ref (see `vui-use-ref') holding (PATH . SESSION) from the
previous successful load. Mirrors `vulpea-ui--mentions-display-data'.

Returns one of:
  (shown . SESSION)  render SESSION -- fresh on `ready', or the cached
                     struct for the same PATH while pending/errored, so
                     the sidebar doesn't blank out on a transient hiccup;
  (error)            render the error state (nothing cached for PATH);
  (loading)          render the loading state (nothing cached for PATH)."
  (pcase status
    ('ready (setcar last-ref (cons path fresh)) (cons 'shown fresh))
    ('error
     (let ((prev (car last-ref)))
       (if (and prev (equal (car prev) path))
           (cons 'shown (cdr prev))
         (cons 'error nil))))
    (_ (let ((prev (car last-ref)))
         (if (and prev (equal (car prev) path))
             (cons 'shown (cdr prev))
           (cons 'loading nil))))))

(defun claude-session-sidebar--file-mtime (path)
  "Return PATH's modification time, or nil if it doesn't exist."
  (file-attribute-modification-time (file-attributes path)))

(vui-defcomponent claude-session-sidebar-widget-stats (path)
  "Stats widget: models, duration, token totals, total cost for PATH."
  :render
  (let* ((last-ref (vui-use-ref nil))
         (mtime (claude-session-sidebar--file-mtime path))
         (result (vui-use-async (list path mtime)
                   (lambda (resolve reject)
                     (condition-case err
                         (funcall resolve (claude-session-log-parse-file path))
                       (error (funcall reject (error-message-string err)))))))
         (status (plist-get result :status))
         (decision (claude-session-sidebar--stats-display-data
                    status path (plist-get result :data) last-ref))
         (state (car decision))
         (session (cdr decision)))
    (pcase state
      ('shown (claude-session-sidebar--render-stats session))
      ('error (vui-muted (format "Unavailable: %s" (plist-get result :error))))
      (_ (vui-muted "Loading…")))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 22 tests, 22 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-sidebar.el tests/claude-session-sidebar-test.el
git commit -m "Add claude-session-sidebar stats widget"
```

---

### Task 5: Root component and render/mount orchestration

**Files:**
- Modify: `claude-session-sidebar.el`
- Test: `tests/claude-session-sidebar-test.el`

**Interfaces:**
- Consumes: `claude-session-sidebar--ordered-widgets` (Task 3),
  `claude-session-sidebar--get-sidebar-window`/`--sidebar-buffer-name`
  (Task 2), `vui-mount`/`vui-update-props`/`vui-instance-buffer`/`vui-
  component` (from `vui.el`).
- Produces: `claude-session-sidebar-root` (the top-level `vui-defcomponent`,
  taking a `path` prop, rendering "no session" or every registered widget
  in order), `claude-session-sidebar--instances` (per-frame hash table of
  `vui-instance`), `claude-session-sidebar--rendering` (re-entry guard),
  `claude-session-sidebar--render-sidebar (path &optional frame)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/claude-session-sidebar-test.el`:

```elisp
(ert-deftest claude-session-sidebar-test-root-no-session ()
  (let ((instance (vui-mount (vui-component 'claude-session-sidebar-root :path nil)
                              "*claude-session-sidebar-root-test-1*")))
    (unwind-protect
        (with-current-buffer (vui-instance-buffer instance)
          (should (string-match-p "No Claude Code session" (buffer-string))))
      (kill-buffer (vui-instance-buffer instance)))))

(ert-deftest claude-session-sidebar-test-root-renders-registered-widgets ()
  (let ((claude-session-sidebar--widgets nil)
        (dir (make-temp-file "claude-session-sidebar-test" t)))
    (unwind-protect
        (let ((path (expand-file-name "sess.jsonl" dir)))
          (with-temp-file path
            (insert (concat "{\"type\":\"assistant\",\"timestamp\":\"2026-07-21T10:00:00.000Z\","
                            "\"message\":{\"role\":\"assistant\",\"model\":\"claude-sonnet-5\","
                            "\"content\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n")))
          (claude-session-sidebar-register-widget
           'stats :component 'claude-session-sidebar-widget-stats :order 10)
          (let ((instance (vui-mount (vui-component 'claude-session-sidebar-root :path path)
                                      "*claude-session-sidebar-root-test-2*")))
            (unwind-protect
                (with-current-buffer (vui-instance-buffer instance)
                  (should (string-match-p "claude-sonnet-5" (buffer-string))))
              (kill-buffer (vui-instance-buffer instance)))))
      (delete-directory dir t))))

(ert-deftest claude-session-sidebar-test-render-sidebar-without-window-is-noop ()
  "No live sidebar window means no error, no instance created --
mirrors vulpea-ui-test-render-sidebar-without-window-is-noop."
  (save-window-excursion
    (let ((claude-session-sidebar--instances (make-hash-table :test 'eq)))
      (claude-session-sidebar--render-sidebar "/some/path.jsonl")
      (should (zerop (hash-table-count claude-session-sidebar--instances))))))

(ert-deftest claude-session-sidebar-test-render-sidebar-restores-original-window ()
  (save-window-excursion
    (let* ((claude-session-sidebar--instances (make-hash-table :test 'eq))
           (main-buf (generate-new-buffer "main"))
           (sidebar-buf (get-buffer-create (claude-session-sidebar--sidebar-buffer-name)))
           (sidebar-win (display-buffer-in-side-window
                         sidebar-buf '((side . right) (slot . 0)))))
      (unwind-protect
          (progn
            (switch-to-buffer main-buf)
            (let ((original-window (selected-window)))
              (claude-session-sidebar--render-sidebar nil)
              (should (eq (selected-window) original-window))))
        (when (window-live-p sidebar-win) (ignore-errors (delete-window sidebar-win)))
        (mapc #'kill-buffer (list main-buf sidebar-buf))))))
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: the 22 earlier tests still pass; the 4 new tests fail
(`void-function`/undefined-component errors).

- [ ] **Step 3: Write the implementation**

Add to `claude-session-sidebar.el` (after the stats widget):

```elisp
(vui-defcomponent claude-session-sidebar-root (path)
  "Root sidebar component: no-session message, or every registered
widget in `:order', each passed PATH."
  :render
  (if (null path)
      (vui-muted "No Claude Code session at point.")
    (apply #'vui-vstack
           (mapcar (lambda (entry)
                     (vui-component (plist-get (cdr entry) :component) :path path))
                   (claude-session-sidebar--ordered-widgets)))))

(defvar claude-session-sidebar--instances (make-hash-table :test 'eq)
  "Hash table of frame -> `vui-instance' for the sidebar root component.")

(defvar claude-session-sidebar--rendering nil
  "Non-nil while the sidebar is rendering. Guards against hook re-entry.")

(defvar-local claude-session-sidebar--current-path nil
  "The session path currently rendered in this sidebar buffer.")

(defun claude-session-sidebar--render-sidebar (path &optional frame)
  "Render PATH into FRAME's sidebar, reusing its `vui-instance' if live.
Ported from `vulpea-ui--render-sidebar': selects the sidebar window
before mounting (since `vui-mount' ends with `switch-to-buffer'), then
restores the originally-selected window."
  (let* ((claude-session-sidebar--rendering t)
         (frame (or frame (selected-frame)))
         (sidebar-win (claude-session-sidebar--get-sidebar-window frame)))
    (when (window-live-p sidebar-win)
      (let* ((buf-name (claude-session-sidebar--sidebar-buffer-name frame))
             (buf (get-buffer-create buf-name))
             (original-window (selected-window))
             (existing-instance (gethash frame claude-session-sidebar--instances)))
        (select-window sidebar-win t)
        (with-current-buffer buf
          (if (and existing-instance
                   (vui-instance-buffer existing-instance)
                   (buffer-live-p (vui-instance-buffer existing-instance)))
              (vui-update-props existing-instance (list :path path))
            (let ((new-instance
                   (vui-mount
                    (vui-component 'claude-session-sidebar-root :path path)
                    buf-name)))
              (puthash frame new-instance claude-session-sidebar--instances)))
          (setq claude-session-sidebar--current-path path)
          (goto-char (point-min)))
        (when (window-live-p original-window)
          (select-window original-window t))))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 26 tests, 26 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-sidebar.el tests/claude-session-sidebar-test.el
git commit -m "Add claude-session-sidebar root component and render/mount"
```

---

### Task 6: Auto show/hide, idle-timer refresh, and commands

**Files:**
- Modify: `claude-session-sidebar.el`
- Test: `tests/claude-session-sidebar-test.el`

**Interfaces:**
- Consumes: `claude-session-sidebar--resolve-session-path` (Task 1),
  `claude-session-sidebar--sidebar-visible-p`/`--create-sidebar-window`/
  `--hide-sidebar-window`/`--show-sidebar-window`/`--get-sidebar-buffer`
  (Task 2), `claude-session-sidebar--render-sidebar`/`--instances`/
  `--rendering`/`--current-path` (Task 5).
- Produces: `claude-session-sidebar-auto-hide` (defcustom, default `t`),
  `claude-session-sidebar-auto-refresh-delay` (defcustom, default `1.5`),
  `claude-session-sidebar--auto-hidden` (per-frame hash table),
  `claude-session-sidebar--on-buffer-change (&optional frame)`,
  `claude-session-sidebar--idle-timer`, `--start-idle-timer`/`--stop-
  idle-timer`, `--setup-hooks`/`--teardown-hooks`, and the interactive
  commands `claude-session-sidebar-open`, `-close`, `-toggle`, `-refresh`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/claude-session-sidebar-test.el`:

```elisp
(ert-deftest claude-session-sidebar-test-on-buffer-change-hides-when-no-session ()
  (save-window-excursion
    (let* ((claude-session-sidebar--instances (make-hash-table :test 'eq))
           (claude-session-sidebar--auto-hidden (make-hash-table :test 'eq))
           (main-buf (generate-new-buffer "plain"))
           (sidebar-buf (get-buffer-create (claude-session-sidebar--sidebar-buffer-name)))
           (sidebar-win (display-buffer-in-side-window
                         sidebar-buf '((side . right) (slot . 0)))))
      (unwind-protect
          (progn
            (with-current-buffer sidebar-buf
              (setq claude-session-sidebar--current-path "/some/prior/session.jsonl"))
            (switch-to-buffer main-buf)
            (claude-session-sidebar--on-buffer-change)
            (should-not (window-live-p sidebar-win))
            (should (gethash (selected-frame) claude-session-sidebar--auto-hidden)))
        (mapc #'kill-buffer (list main-buf sidebar-buf))))))

(ert-deftest claude-session-sidebar-test-on-buffer-change-reshows-when-session-found ()
  "Resolution itself is already covered by Task 1's tests -- this test
stubs `--resolve-session-path' directly so it exercises only
`--on-buffer-change''s own show/re-render decision."
  (save-window-excursion
    (let* ((claude-session-sidebar--instances (make-hash-table :test 'eq))
           (claude-session-sidebar--auto-hidden (make-hash-table :test 'eq))
           (main-buf (generate-new-buffer "main"))
           (sidebar-buf (get-buffer-create (claude-session-sidebar--sidebar-buffer-name))))
      (unwind-protect
          (progn
            (puthash (selected-frame) t claude-session-sidebar--auto-hidden)
            (switch-to-buffer main-buf)
            (cl-letf (((symbol-function 'claude-session-sidebar--resolve-session-path)
                       (lambda (&optional _frame) "/some/session.jsonl")))
              (claude-session-sidebar--on-buffer-change)
              (should (claude-session-sidebar--sidebar-visible-p))
              (should-not (gethash (selected-frame) claude-session-sidebar--auto-hidden))))
        (mapc #'kill-buffer (list main-buf sidebar-buf))
        (ignore-errors (delete-window (claude-session-sidebar--get-sidebar-window)))))))

(ert-deftest claude-session-sidebar-test-start-stop-idle-timer ()
  (unwind-protect
      (progn
        (claude-session-sidebar--start-idle-timer)
        (should (timerp claude-session-sidebar--idle-timer))
        (claude-session-sidebar--stop-idle-timer)
        (should (null claude-session-sidebar--idle-timer)))
    (claude-session-sidebar--stop-idle-timer)))

(ert-deftest claude-session-sidebar-test-open-close-toggle ()
  :tags '(:integration)
  (skip-unless (ignore-errors (make-frame '((visibility . nil)))))
  (let ((frame (make-frame '((visibility . nil)))))
    (unwind-protect
        (with-selected-frame frame
          (should-not (claude-session-sidebar--sidebar-visible-p))
          (claude-session-sidebar-open)
          (should (claude-session-sidebar--sidebar-visible-p))
          (claude-session-sidebar-close)
          (should-not (claude-session-sidebar--sidebar-visible-p))
          (claude-session-sidebar-toggle)
          (should (claude-session-sidebar--sidebar-visible-p))
          (claude-session-sidebar-toggle)
          (should-not (claude-session-sidebar--sidebar-visible-p)))
      (claude-session-sidebar--teardown-hooks)
      (delete-frame frame))))
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: the 26 earlier tests still pass; the 4 new tests fail
(`void-function`/`void-variable` for the missing pieces). The
`:integration`-tagged test is not skipped by anything in this run (there
is no tag filter in the plain `-f ert-run-tests-batch-and-exit` command)
— it runs like any other and is expected to fail at RED same as the rest.

- [ ] **Step 3: Write the implementation**

Add to `claude-session-sidebar.el` (after the render/mount function):

```elisp
(defcustom claude-session-sidebar-auto-hide t
  "When non-nil, automatically hide the sidebar when there's no session at point."
  :type 'boolean
  :group 'claude-session-sidebar)

(defcustom claude-session-sidebar-auto-refresh-delay 1.5
  "Idle seconds before auto-refreshing the sidebar."
  :type 'number
  :group 'claude-session-sidebar)

(defvar claude-session-sidebar--auto-hidden (make-hash-table :test 'eq)
  "Hash table tracking frames where the sidebar was auto-hidden.")

(defun claude-session-sidebar--on-buffer-change (&optional _frame)
  "Auto-show/hide the sidebar and re-render on session change.
Ported from `vulpea-ui--on-buffer-change', with `vulpea-ui''s \"note\"
replaced by \"resolved session path\", compared with `equal' rather
than a note-id lookup."
  (unless (or (minibufferp) claude-session-sidebar--rendering)
    (let* ((frame (selected-frame))
           (sidebar-buf (claude-session-sidebar--get-sidebar-buffer frame))
           (auto-hidden-p (gethash frame claude-session-sidebar--auto-hidden)))
      (when sidebar-buf
        (let* ((path (claude-session-sidebar--resolve-session-path frame))
               (had-path (buffer-local-value 'claude-session-sidebar--current-path sidebar-buf))
               (visible (claude-session-sidebar--sidebar-visible-p frame))
               (same-path (and path had-path (equal path had-path))))
          (cond
           ((and (null path) had-path claude-session-sidebar-auto-hide visible)
            (claude-session-sidebar--hide-sidebar-window frame)
            (puthash frame t claude-session-sidebar--auto-hidden))
           ((and path auto-hidden-p)
            (remhash frame claude-session-sidebar--auto-hidden)
            (claude-session-sidebar--show-sidebar-window frame)
            (unless same-path (claude-session-sidebar--render-sidebar path frame)))
           ((and path visible (not same-path))
            (claude-session-sidebar--render-sidebar path frame))))))))

(defvar claude-session-sidebar--idle-timer nil
  "Timer for auto-refreshing the sidebar on idle.")

(defun claude-session-sidebar--on-idle ()
  "Soft-refresh the visible sidebar on idle: re-render without
invalidating widget memos (`vui-use-async' handles its own
mtime-keyed staleness check internally)."
  (when (claude-session-sidebar--sidebar-visible-p)
    (claude-session-sidebar--render-sidebar
     (claude-session-sidebar--resolve-session-path))))

(defun claude-session-sidebar--start-idle-timer ()
  "Start the idle timer for auto-refresh."
  (claude-session-sidebar--stop-idle-timer)
  (setq claude-session-sidebar--idle-timer
        (run-with-idle-timer claude-session-sidebar-auto-refresh-delay t
                             #'claude-session-sidebar--on-idle)))

(defun claude-session-sidebar--stop-idle-timer ()
  "Stop the idle timer for auto-refresh."
  (when claude-session-sidebar--idle-timer
    (cancel-timer claude-session-sidebar--idle-timer)
    (setq claude-session-sidebar--idle-timer nil)))

(defun claude-session-sidebar--setup-hooks ()
  "Set up hooks and the idle timer for sidebar auto-show/hide/refresh."
  (add-hook 'window-buffer-change-functions #'claude-session-sidebar--on-buffer-change)
  (add-hook 'window-selection-change-functions #'claude-session-sidebar--on-buffer-change)
  (claude-session-sidebar--start-idle-timer))

(defun claude-session-sidebar--teardown-hooks ()
  "Remove hooks and stop the idle timer."
  (remove-hook 'window-buffer-change-functions #'claude-session-sidebar--on-buffer-change)
  (remove-hook 'window-selection-change-functions #'claude-session-sidebar--on-buffer-change)
  (claude-session-sidebar--stop-idle-timer))

;;;###autoload
(defun claude-session-sidebar-open ()
  "Open or show the claude-session-sidebar in the current frame."
  (interactive)
  (let* ((frame (selected-frame))
         (buf-name (claude-session-sidebar--sidebar-buffer-name frame))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'claude-session-sidebar-mode)
        (claude-session-sidebar-mode)))
    (unless (claude-session-sidebar--sidebar-visible-p frame)
      (claude-session-sidebar--create-sidebar-window buf))
    (claude-session-sidebar--setup-hooks)
    (claude-session-sidebar--render-sidebar
     (claude-session-sidebar--resolve-session-path frame) frame)))

;;;###autoload
(defun claude-session-sidebar-close ()
  "Close the claude-session-sidebar in the current frame."
  (interactive)
  (let* ((frame (selected-frame))
         (buf (claude-session-sidebar--get-sidebar-buffer frame)))
    (claude-session-sidebar--hide-sidebar-window frame)
    (when buf (kill-buffer buf))
    (remhash frame claude-session-sidebar--instances)
    (remhash frame claude-session-sidebar--auto-hidden)
    (when (zerop (hash-table-count claude-session-sidebar--instances))
      (claude-session-sidebar--teardown-hooks))))

;;;###autoload
(defun claude-session-sidebar-toggle ()
  "Toggle the claude-session-sidebar visibility in the current frame."
  (interactive)
  (if (claude-session-sidebar--sidebar-visible-p)
      (claude-session-sidebar-close)
    (claude-session-sidebar-open)))

;;;###autoload
(defun claude-session-sidebar-refresh ()
  "Force refresh the sidebar, invalidating widget memos."
  (interactive)
  (let* ((frame (selected-frame))
         (path (claude-session-sidebar--resolve-session-path frame))
         (instance (gethash frame claude-session-sidebar--instances)))
    (when (and instance (vui-instance-buffer instance)
               (buffer-live-p (vui-instance-buffer instance)))
      (vui-update instance (list :path path)))))
```

Remove the earlier `(declare-function claude-session-sidebar-close
"claude-session-sidebar")` / `-refresh` forward declarations added in
Task 2 — the real definitions now exist above them in load order, so the
placeholders are no longer needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -L straight/build/vui -l claude-session-log.el -l claude-session-sidebar.el -l tests/claude-session-sidebar-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 30 tests, 30 results as expected, 0 unexpected`. If the
`:integration`-tagged `claude-session-sidebar-test-open-close-toggle` test
fails specifically because `make-frame` isn't supported in this batch
environment, its own `skip-unless` should report it as skipped, not
failed — treat a skip as acceptable for that one test only; any other
failure blocks this task.

- [ ] **Step 5: Commit**

```bash
git add claude-session-sidebar.el tests/claude-session-sidebar-test.el
git commit -m "Add claude-session-sidebar auto show/hide, idle refresh, and commands"
```

---

## Self-review notes

- **Spec coverage:** session-at-point resolution incl. verified cwd
  encoding (Task 1); vulpea-ui-ported window chrome incl. slot-guarantee
  regression test (Task 2); configurable widget registry (Task 3); the
  one v1 widget with stale-on-error resilience via `vui-use-ref`/`vui-
  use-async` keyed on `(path . mtime)` (Task 4); root component +
  render/mount orchestration matching vulpea-ui's exact
  select-window-before-mount / restore-original-window pattern (Task 5);
  auto-show/hide + idle-timer refresh + manual commands (Task 6) — every
  design-doc section maps to a task.
- **Placeholder scan:** no TBD/TODO; every step has complete, runnable
  code and an exact expected-output line for its test run.
- **Type consistency:** checked function names/signatures are used
  identically everywhere they're consumed across tasks — e.g.
  `claude-session-sidebar--get-sidebar-window` has the same `(&optional
  frame)` signature as both Task 1's stub and Task 2's real
  implementation (Task 1's tests never depend on its return value being
  non-nil, so the swap is safe); `claude-session-sidebar--render-sidebar`'s
  `(path &optional frame)` signature is identical everywhere it's called
  (Task 5's own tests, Task 6's `--on-buffer-change`/`--on-idle`/`-open`).
- One deliberate scope note carried over from the design doc: this plan
  does **not** implement the `hoodoo-session-context`-style tab-per-
  session identity anywhere — "session at point" is resolved fresh from
  ambient window/buffer state on every call, by design.

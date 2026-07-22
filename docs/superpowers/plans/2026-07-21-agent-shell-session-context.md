# Agent-shell Session Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tag eat/magit/dired buffers to the agent-shell session (buffer) they support, and give each session its own auto-managed `tab-bar` tab, so switching between concurrent agent-driven tasks restores the right windows.

**Architecture:** All new logic lives in a new standalone file, `hoodoo-session-context.el`, loaded from `init.el`'s `agent-shell` `use-package` block. A session's identity is its agent-shell buffer; context buffers carry a buffer-local pointer back to it (no separate registry — always recomputed from `(buffer-list)`). A dynamically-bound pending-label variable plus `agent-shell-mode-hook` ties a freshly started session to the tab-bar tab created for it.

**Tech Stack:** Emacs Lisp, ERT (built-in test framework), `tab-bar.el` and `seq.el` (built-in) — no new external packages.

## Global Constraints

- Target runtime: Emacs 29.3 (matches the installed version in this environment).
- No new external/straight packages — only Emacs built-ins (`tab-bar`, `seq`, `cl-lib`).
- `hoodoo-session-context.el` must load standalone via `emacs -Q --batch -l hoodoo-session-context.el` — no dependency on `straight.el` bootstrap or `init.el` — so the test suite can run headlessly and fast.
- Public interactive commands use the `hoodoo/session-` prefix; internal helpers not meant to be called directly use the `hoodoo/session--` (double-dash) prefix, per standard Elisp convention.
- New interactive commands are bound under the existing `C-c a` prefix in the `agent-shell` `use-package` `:bind` block in `init.el`.
- Source of truth for behavior is `docs/superpowers/specs/2026-07-21-agent-shell-session-context-design.md`; any deviation from it must be called out in the commit message.
- Test runner command (used throughout this plan):
  `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
  (run from `/home/hoooo/.emacs.d`)

---

### Task 1: Library scaffolding + label defaulting

**Files:**
- Create: `hoodoo-session-context.el`
- Create: `tests/hoodoo-session-context-test.el`

**Interfaces:**
- Produces:
  - `hoodoo/session--default-label (dir)` → string. Takes a directory path, returns its basename (e.g. `"/home/hoooo/proj/"` → `"proj"`).
  - Forward declarations for `agent-shell-mode-hook` and `agent-shell-cwd-function` (see Step 3 note) — these must live at the very top of the file, before any `defun`, because a value-less `(defvar foo)` only makes `foo` dynamically-scoped for `let` forms *textually after it in the same file*. Tasks 5 and 6 add functions that `let`-bind `agent-shell-cwd-function`; if the declaration came after them, those bindings would silently be lexical instead of dynamic.

- [ ] **Step 1: Write the failing test**

Create `tests/hoodoo-session-context-test.el`:

```elisp
;;; hoodoo-session-context-test.el --- Tests for hoodoo-session-context -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(ert-deftest hoodoo/session-test-default-label ()
  (should (equal (hoodoo/session--default-label "/home/hoooo/proj/") "proj"))
  (should (equal (hoodoo/session--default-label "/home/hoooo/proj") "proj"))
  (should (equal (hoodoo/session--default-label "/home/hoooo/") "hoooo")))

(provide 'hoodoo-session-context-test)
;;; hoodoo-session-context-test.el ends here
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -l ert -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `hoodoo-session-context.el` doesn't exist yet, so `hoodoo/session--default-label` is void. (This step just confirms the test is wired up; the load error itself is the "failure" here since the library file doesn't exist yet.)

- [ ] **Step 3: Write minimal implementation**

Create `hoodoo-session-context.el`:

```elisp
;;; hoodoo-session-context.el --- Session-scoped context buffers for agent-shell -*- lexical-binding: t; -*-

;;; Commentary:
;; Ties eat/magit/dired buffers to the agent-shell session (buffer) they
;; support, and manages one tab-bar tab per session so switching between
;; concurrent agent-driven tasks restores the right set of windows.
;; See docs/superpowers/specs/2026-07-21-agent-shell-session-context-design.md

;;; Code:

(require 'seq)
(require 'tab-bar)

;; Forward declarations so this file loads standalone (e.g. under test,
;; without the real `agent-shell' package present) and so the dynamic
;; `let' bindings of `agent-shell-cwd-function' added in later tasks
;; actually bind dynamically rather than lexically. A value-less
;; `defvar' only takes effect for forms *after* it in the same file,
;; so these must come before any function that `let'-binds
;; `agent-shell-cwd-function' or relies on `agent-shell-mode-hook'.
;; When the real `agent-shell' / `agent-shell-project' are loaded,
;; their own `defvar'/`defcustom' take over (harmless to declare twice).
(unless (boundp 'agent-shell-mode-hook)
  (defvar agent-shell-mode-hook nil))
(defvar agent-shell-cwd-function)

(defun hoodoo/session--default-label (dir)
  "Compute the default session label for DIR: its basename."
  (file-name-nondirectory (directory-file-name dir)))

(provide 'hoodoo-session-context)
;;; hoodoo-session-context.el ends here
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — `Ran 1 tests, 1 results as expected`

- [ ] **Step 5: Commit**

```bash
git add hoodoo-session-context.el tests/hoodoo-session-context-test.el
git commit -m "Add hoodoo-session-context library scaffolding and label defaulting"
```

---

### Task 2: Buffer tagging and attached-buffer lookup

**Files:**
- Modify: `hoodoo-session-context.el`
- Test: `tests/hoodoo-session-context-test.el`

**Interfaces:**
- Consumes: nothing new from Task 1.
- Produces:
  - `hoodoo/session-buffer` — buffer-local variable (via `defvar-local`), holds the agent-shell buffer a context buffer is attached to, or nil.
  - `hoodoo/session--tag-buffer (buffer session-buffer)` → sets `hoodoo/session-buffer` in BUFFER.
  - `hoodoo/session--attached-buffers (session-buffer)` → list of live buffers whose `hoodoo/session-buffer` `eq` SESSION-BUFFER.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hoodoo-session-context-test.el` (before the `(provide ...)` line):

```elisp
(ert-deftest hoodoo/session-test-tag-and-lookup ()
  (let ((session (generate-new-buffer "session"))
        (eat-buf (generate-new-buffer "eat"))
        (dired-buf (generate-new-buffer "dired"))
        (unrelated (generate-new-buffer "unrelated")))
    (unwind-protect
        (progn
          (hoodoo/session--tag-buffer eat-buf session)
          (hoodoo/session--tag-buffer dired-buf session)
          (should (eq (buffer-local-value 'hoodoo/session-buffer eat-buf) session))
          (should (equal (sort (mapcar #'buffer-name
                                        (hoodoo/session--attached-buffers session))
                                #'string<)
                          (sort (list "dired" "eat") #'string<)))
          (should (null (hoodoo/session--attached-buffers unrelated))))
      (mapc #'kill-buffer (list session eat-buf dired-buf unrelated)))))

(ert-deftest hoodoo/session-test-attached-buffers-excludes-killed ()
  (let ((session (generate-new-buffer "session"))
        (eat-buf (generate-new-buffer "eat")))
    (unwind-protect
        (progn
          (hoodoo/session--tag-buffer eat-buf session)
          (kill-buffer eat-buf)
          (should (null (hoodoo/session--attached-buffers session))))
      (kill-buffer session))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `hoodoo/session--tag-buffer` is void.

- [ ] **Step 3: Write minimal implementation**

Add to `hoodoo-session-context.el`, after the `hoodoo/session--default-label` function:

```elisp
(defvar-local hoodoo/session-buffer nil
  "The agent-shell buffer this buffer is attached to, or nil.")

(defun hoodoo/session--tag-buffer (buffer session-buffer)
  "Attach BUFFER to SESSION-BUFFER."
  (with-current-buffer buffer
    (setq-local hoodoo/session-buffer session-buffer)))

(defun hoodoo/session--attached-buffers (session-buffer)
  "Return live buffers attached to SESSION-BUFFER."
  (seq-filter (lambda (buf)
                (eq (buffer-local-value 'hoodoo/session-buffer buf)
                    session-buffer))
              (buffer-list)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — `Ran 3 tests, 3 results as expected`

- [ ] **Step 5: Commit**

```bash
git add hoodoo-session-context.el tests/hoodoo-session-context-test.el
git commit -m "Add buffer tagging and attached-buffer lookup"
```

---

### Task 3: Current-session-buffer resolution

**Files:**
- Modify: `hoodoo-session-context.el`
- Test: `tests/hoodoo-session-context-test.el`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `hoodoo/session--current-session-buffer (&optional frame)` → the sole buffer with `major-mode` `agent-shell-mode` displayed in a window of FRAME (default selected frame), or nil if there isn't exactly one. Dedupes by buffer identity (`seq-uniq ... #'eq`) before counting, so one buffer shown in multiple windows (e.g. after `C-x 2`) still counts as exactly one, not ambiguous.
  - `hoodoo/session--require-current-session-buffer ()` → same, but signals `user-error` instead of returning nil.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hoodoo-session-context-test.el`:

```elisp
(ert-deftest hoodoo/session-test-current-session-buffer ()
  (let ((agent-buf (generate-new-buffer "agent"))
        (other-buf (generate-new-buffer "other")))
    (unwind-protect
        (progn
          ;; Deterministic single-window baseline: `display-buffer'
          ;; heuristics can reuse/split windows unpredictably, and
          ;; leftover windows from earlier tests would make this test
          ;; order-dependent. `switch-to-buffer' always replaces the
          ;; buffer of the selected window.
          (delete-other-windows)
          (with-current-buffer agent-buf (setq major-mode 'agent-shell-mode))
          (switch-to-buffer other-buf)
          (should (null (hoodoo/session--current-session-buffer)))
          (should-error (hoodoo/session--require-current-session-buffer)
                        :type 'user-error)
          (switch-to-buffer agent-buf)
          (should (eq (hoodoo/session--current-session-buffer) agent-buf)))
      (mapc #'kill-buffer (list agent-buf other-buf))
      (delete-other-windows))))

(ert-deftest hoodoo/session-test-current-session-buffer-ambiguous ()
  (let ((agent-buf-1 (generate-new-buffer "agent-1"))
        (agent-buf-2 (generate-new-buffer "agent-2")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer agent-buf-1 (setq major-mode 'agent-shell-mode))
          (with-current-buffer agent-buf-2 (setq major-mode 'agent-shell-mode))
          ;; `split-window' + `set-window-buffer' guarantees two real
          ;; windows; relying on a `display-buffer' action alist like
          ;; `display-buffer-pop-up-window' isn't deterministic in a
          ;; batch/no-frame environment.
          (switch-to-buffer agent-buf-1)
          (set-window-buffer (split-window) agent-buf-2)
          (should (null (hoodoo/session--current-session-buffer))))
      (mapc #'kill-buffer (list agent-buf-1 agent-buf-2))
      (delete-other-windows))))

(ert-deftest hoodoo/session-test-current-session-buffer-same-buffer-two-windows ()
  (let ((agent-buf (generate-new-buffer "agent")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer agent-buf (setq major-mode 'agent-shell-mode))
          ;; The same buffer displayed in two windows (e.g. after `C-x 2')
          ;; is still exactly one session buffer, not an ambiguous pair —
          ;; candidates must be deduped by buffer identity, not counted
          ;; per window.
          (switch-to-buffer agent-buf)
          (set-window-buffer (split-window) agent-buf)
          (should (eq (hoodoo/session--current-session-buffer) agent-buf)))
      (kill-buffer agent-buf)
      (delete-other-windows))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `hoodoo/session--current-session-buffer` is void.

- [ ] **Step 3: Write minimal implementation**

Add to `hoodoo-session-context.el`, after `hoodoo/session--attached-buffers`:

```elisp
(defun hoodoo/session--current-session-buffer (&optional frame)
  "Return the agent-shell buffer displayed in a window of FRAME, or nil
unless there is exactly one."
  (let ((candidates
         (seq-uniq
          (seq-filter (lambda (buf)
                        (eq (buffer-local-value 'major-mode buf) 'agent-shell-mode))
                      (mapcar #'window-buffer (window-list frame 'no-mini)))
          #'eq)))
    (when (= (length candidates) 1)
      (car candidates))))

(defun hoodoo/session--require-current-session-buffer ()
  "Like `hoodoo/session--current-session-buffer', but signal `user-error'
instead of returning nil."
  (or (hoodoo/session--current-session-buffer)
      (user-error "No agent-shell session in this tab")))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — `Ran 6 tests, 6 results as expected`

- [ ] **Step 5: Commit**

```bash
git add hoodoo-session-context.el tests/hoodoo-session-context-test.el
git commit -m "Add current-session-buffer resolution"
```

---

### Task 4: Session-end cleanup

**Files:**
- Modify: `hoodoo-session-context.el`
- Test: `tests/hoodoo-session-context-test.el`

**Interfaces:**
- Consumes: `hoodoo/session--tag-buffer`, `hoodoo/session--attached-buffers` (Task 2).
- Produces:
  - `hoodoo/session--default-checked-p (buffer)` → t if BUFFER's major-mode is `eat-mode` or `magit-status-mode` (pre-checked for cleanup), nil otherwise (e.g. `dired-mode`).
  - `hoodoo/session--close-current-tab-safely ()` → closes the current tab if `tab-bar-mode` is on and there's more than one tab; no-ops otherwise.
  - `hoodoo/session--on-session-kill ()` → meant to run as a buffer-local `kill-buffer-hook` in a dying agent-shell buffer. Collects attached buffers via `hoodoo/session--attached-buffers`, prompts (via `completing-read-multiple`) for which to kill (pre-selected per `hoodoo/session--default-checked-p`), kills the chosen ones, then calls `hoodoo/session--close-current-tab-safely`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hoodoo-session-context-test.el`:

```elisp
(ert-deftest hoodoo/session-test-default-checked-p ()
  (let ((eat-buf (generate-new-buffer "eat"))
        (magit-buf (generate-new-buffer "magit"))
        (dired-buf (generate-new-buffer "dired")))
    (unwind-protect
        (progn
          (with-current-buffer eat-buf (setq major-mode 'eat-mode))
          (with-current-buffer magit-buf (setq major-mode 'magit-status-mode))
          (with-current-buffer dired-buf (setq major-mode 'dired-mode))
          (should (hoodoo/session--default-checked-p eat-buf))
          (should (hoodoo/session--default-checked-p magit-buf))
          (should-not (hoodoo/session--default-checked-p dired-buf)))
      (mapc #'kill-buffer (list eat-buf magit-buf dired-buf)))))

(ert-deftest hoodoo/session-test-close-current-tab-safely-single-tab-noop ()
  (let ((tab-bar-mode t))
    (cl-letf (((symbol-function 'tab-bar-tabs) (lambda () (list "only-tab")))
              ((symbol-function 'tab-bar-close-tab)
               (lambda (&rest _) (error "should not be called"))))
      ;; Should not signal, since there's only one tab.
      (hoodoo/session--close-current-tab-safely))))

(ert-deftest hoodoo/session-test-close-current-tab-safely-multiple-tabs-closes ()
  (let ((tab-bar-mode t)
        (closed nil))
    (cl-letf (((symbol-function 'tab-bar-tabs)
               (lambda () (list "tab-1" "tab-2")))
              ((symbol-function 'tab-bar-close-tab)
               (lambda (&rest _) (setq closed t))))
      (hoodoo/session--close-current-tab-safely)
      (should closed))))

(ert-deftest hoodoo/session-test-close-current-tab-safely-tab-bar-off-noop ()
  (let ((tab-bar-mode nil))
    (cl-letf (((symbol-function 'tab-bar-tabs)
               (lambda (&rest _) (error "should not be called")))
              ((symbol-function 'tab-bar-close-tab)
               (lambda (&rest _) (error "should not be called"))))
      ;; Should not signal, and should short-circuit before ever
      ;; consulting `tab-bar-tabs', since `tab-bar-mode' is off.
      (hoodoo/session--close-current-tab-safely))))

(ert-deftest hoodoo/session-test-on-session-kill-prompts-and-kills-defaults ()
  (let ((session (generate-new-buffer "session"))
        (eat-buf (generate-new-buffer "eat"))
        (dired-buf (generate-new-buffer "dired"))
        (tab-closed nil)
        (prompt-arg nil)
        (captured-def nil))
    (unwind-protect
        (progn
          (with-current-buffer eat-buf (setq major-mode 'eat-mode))
          (with-current-buffer dired-buf (setq major-mode 'dired-mode))
          (hoodoo/session--tag-buffer eat-buf session)
          (hoodoo/session--tag-buffer dired-buf session)
          (cl-letf (((symbol-function 'completing-read-multiple)
                     (lambda (prompt collection &optional predicate
                                     require-match initial-input hist def
                                     &rest _)
                       (ignore collection predicate require-match
                               initial-input hist)
                       (setq prompt-arg prompt)
                       (setq captured-def def)
                       (list (buffer-name eat-buf))))
                    ((symbol-function 'hoodoo/session--close-current-tab-safely)
                     (lambda () (setq tab-closed t))))
            (with-current-buffer session
              (hoodoo/session--on-session-kill)))
          (should (string-match-p "eat" prompt-arg))
          ;; The DEF argument (7th positional) passed to
          ;; `completing-read-multiple' should pre-select only the
          ;; default-checked buffers: "eat" present, "dired" absent.
          (should (string-match-p "eat" captured-def))
          (should-not (string-match-p "dired" captured-def))
          (should-not (buffer-live-p eat-buf))
          (should (buffer-live-p dired-buf))
          (should tab-closed))
      (mapc (lambda (b) (when (buffer-live-p b) (kill-buffer b)))
            (list session eat-buf dired-buf)))))

(ert-deftest hoodoo/session-test-on-session-kill-noop-when-nothing-attached ()
  (let ((session (generate-new-buffer "session"))
        (tab-closed nil))
    (unwind-protect
        (cl-letf (((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) (error "should not prompt")))
                  ((symbol-function 'hoodoo/session--close-current-tab-safely)
                   (lambda () (setq tab-closed t))))
          (with-current-buffer session
            (hoodoo/session--on-session-kill))
          (should tab-closed))
      (kill-buffer session))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `hoodoo/session--default-checked-p` is void.

- [ ] **Step 3: Write minimal implementation**

Add to `hoodoo-session-context.el`, after `hoodoo/session--require-current-session-buffer`:

```elisp
(defun hoodoo/session--default-checked-p (buffer)
  "Whether BUFFER should be pre-checked for killing when its session ends."
  (memq (buffer-local-value 'major-mode buffer) '(eat-mode magit-status-mode)))

(defun hoodoo/session--close-current-tab-safely ()
  "Close the current tab, tolerating tab-bar being off or there being
only one tab left."
  (when (and (bound-and-true-p tab-bar-mode)
             (> (length (tab-bar-tabs)) 1))
    (ignore-errors (tab-bar-close-tab))))

(defun hoodoo/session--on-session-kill ()
  "Buffer-local `kill-buffer-hook' for agent-shell buffers.  Offers to
kill attached context buffers, then closes the session's tab."
  (let ((attached (hoodoo/session--attached-buffers (current-buffer))))
    (when attached
      (let* ((default-buffers (seq-filter #'hoodoo/session--default-checked-p attached))
             (default-names (mapcar #'buffer-name default-buffers))
             (chosen (completing-read-multiple
                      (format "Kill attached buffers (default: %s): "
                              (string-join default-names ", "))
                      (mapcar #'buffer-name attached)
                      nil t nil nil (string-join default-names ","))))
        (dolist (name chosen)
          (when-let ((buf (get-buffer name)))
            (kill-buffer buf))))))
  (hoodoo/session--close-current-tab-safely))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — `Ran 12 tests, 12 results as expected`

- [ ] **Step 5: Commit**

```bash
git add hoodoo-session-context.el tests/hoodoo-session-context-test.el
git commit -m "Add session-end cleanup (attached-buffer prompt + tab close)"
```

---

### Task 5: Tab creation and mode-hook wiring

**Files:**
- Modify: `hoodoo-session-context.el`
- Test: `tests/hoodoo-session-context-test.el`

**Interfaces:**
- Consumes: `hoodoo/session--on-session-kill` (Task 4).
- Produces:
  - `hoodoo/session-label` — buffer-local variable (via `defvar-local`), set on agent-shell buffers to the session's label.
  - `hoodoo/session--pending-label` — `defvar` (dynamically scoped), nil by default; dynamically bound around session-start calls.
  - `hoodoo/session--make-tab (label)` → creates a new tab-bar tab and renames it to LABEL.
  - `hoodoo/session-mode-hook-fn ()` → meant for `agent-shell-mode-hook`. If `hoodoo/session--pending-label` is non-nil, sets `hoodoo/session-label` buffer-locally on `(current-buffer)` and installs `hoodoo/session--on-session-kill` as a buffer-local `kill-buffer-hook`.
  - `hoodoo/session--start-in-tab (label start-function)` → creates+switches to a tab named LABEL, then calls the 0-arg STAR-FUNCTION with `hoodoo/session--pending-label` dynamically bound to LABEL.
  - Registers `hoodoo/session-mode-hook-fn` on `agent-shell-mode-hook` (top-level `add-hook` call, unconditional side effect of loading the file — matches how the rest of `init.el` wires things up at load time).

- [ ] **Step 1: Write the failing tests**

Append to `tests/hoodoo-session-context-test.el`:

```elisp
(ert-deftest hoodoo/session-test-make-tab ()
  (let ((created nil) (renamed nil))
    (cl-letf (((symbol-function 'tab-bar-new-tab) (lambda () (setq created t)))
              ((symbol-function 'tab-bar-rename-tab) (lambda (name) (setq renamed name))))
      (hoodoo/session--make-tab "incident-42")
      (should created)
      (should (equal renamed "incident-42")))))

(ert-deftest hoodoo/session-test-mode-hook-fn-tags-when-pending ()
  (let ((buf (generate-new-buffer "agent"))
        (hoodoo/session--pending-label "incident-42")
        (hook-installed nil))
    (unwind-protect
        (with-current-buffer buf
          (setq major-mode 'agent-shell-mode)
          ;; Capture the real `add-hook' before shadowing it — the mock
          ;; must call through to the ORIGINAL, not to itself via
          ;; `#'add-hook' (which would now resolve to the mock and
          ;; recurse forever).
          (let ((orig-add-hook (symbol-function 'add-hook)))
            (cl-letf (((symbol-function 'add-hook)
                       (lambda (hook fn &rest args)
                         (when (eq hook 'kill-buffer-hook) (setq hook-installed fn))
                         (apply orig-add-hook hook fn args))))
              (hoodoo/session-mode-hook-fn)))
          (should (equal hoodoo/session-label "incident-42"))
          (should (eq hook-installed #'hoodoo/session--on-session-kill)))
      (kill-buffer buf))))

(ert-deftest hoodoo/session-test-mode-hook-fn-noop-without-pending ()
  (let ((buf (generate-new-buffer "agent"))
        (hoodoo/session--pending-label nil))
    (unwind-protect
        (with-current-buffer buf
          (hoodoo/session-mode-hook-fn)
          (should (null hoodoo/session-label)))
      (kill-buffer buf))))

(ert-deftest hoodoo/session-test-start-in-tab-binds-label-and-makes-tab ()
  (let ((made-tab nil) (seen-label nil))
    (cl-letf (((symbol-function 'hoodoo/session--make-tab)
               (lambda (label) (setq made-tab label))))
      (hoodoo/session--start-in-tab
       "incident-42"
       (lambda () (setq seen-label hoodoo/session--pending-label))))
    (should (equal made-tab "incident-42"))
    (should (equal seen-label "incident-42"))
    ;; Binding must not leak after the call.
    (should (null hoodoo/session--pending-label))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `hoodoo/session--make-tab` is void.

- [ ] **Step 3: Write minimal implementation**

Add to `hoodoo-session-context.el`, after `hoodoo/session--on-session-kill`:

```elisp
(defvar-local hoodoo/session-label nil
  "The user-chosen label for this agent-shell session, or nil.
Set on agent-shell buffers only; also used as the session's tab name.")

(defvar hoodoo/session--pending-label nil
  "Dynamically bound to a label while starting a new agent-shell session.
Read by `hoodoo/session-mode-hook-fn' once the new buffer's
`agent-shell-mode' has finished initializing.")

(defun hoodoo/session--make-tab (label)
  "Create a new tab-bar tab named LABEL and switch to it."
  (tab-bar-new-tab)
  (tab-bar-rename-tab label))

(defun hoodoo/session-mode-hook-fn ()
  "Added to `agent-shell-mode-hook'.  Tags a newly started session buffer
with the pending label (if any) and installs its cleanup hook."
  (when hoodoo/session--pending-label
    (setq-local hoodoo/session-label hoodoo/session--pending-label)
    (add-hook 'kill-buffer-hook #'hoodoo/session--on-session-kill nil t)))

(defun hoodoo/session--start-in-tab (label start-function)
  "Create a tab named LABEL, switch to it, and call START-FUNCTION
inside it with `hoodoo/session--pending-label' bound to LABEL."
  (hoodoo/session--make-tab label)
  (let ((hoodoo/session--pending-label label))
    (funcall start-function)))

(add-hook 'agent-shell-mode-hook #'hoodoo/session-mode-hook-fn)
```

Note: `agent-shell-mode-hook` here is the forward declaration from Task 1 (or the real `agent-shell` variable, once loaded from `init.el` per Task 9) — it doesn't need to be redeclared here, only used.

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — `Ran 16 tests, 16 results as expected`

- [ ] **Step 5: Commit**

```bash
git add hoodoo-session-context.el tests/hoodoo-session-context-test.el
git commit -m "Add tab creation and agent-shell-mode-hook wiring"
```

---

### Task 6: Session-start interactive commands

**Files:**
- Modify: `hoodoo-session-context.el`
- Test: `tests/hoodoo-session-context-test.el`

**Interfaces:**
- Consumes: `hoodoo/session--start-in-tab`, `hoodoo/session--default-label` (Tasks 1, 5).
- Produces:
  - `hoodoo/session--start-agent-in-tab (dir label require-features start-fn)` — shared helper. `require`s each symbol in REQUIRE-FEATURES, then creates a tab named LABEL and calls the 0-arg START-FN inside it with `agent-shell-cwd-function` dynamically bound to return DIR. Both commands below delegate to this instead of duplicating its body — the *commands* stay separate (so `M-x hoodoo/claude-start-in` / `hoodoo/codex-start-in` are still the two things you invoke), only the shared plumbing is factored out.
  - `hoodoo/claude-start-in (dir label)` — interactive command. Prompts for DIR then LABEL (defaulting to `hoodoo/session--default-label` of DIR); delegates to `hoodoo/session--start-agent-in-tab` with the Claude-specific `require`s and start function.
  - `hoodoo/codex-start-in (dir label)` — same, for Codex.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hoodoo-session-context-test.el`:

```elisp
(ert-deftest hoodoo/session-test-start-agent-in-tab ()
  (let ((tab-label nil) (required nil) (started-in-dir nil))
    (cl-letf (((symbol-function 'hoodoo/session--start-in-tab)
               (lambda (label start-fn)
                 (setq tab-label label)
                 (funcall start-fn)))
              ((symbol-function 'require)
               (lambda (feature &rest _) (push feature required) feature)))
      (hoodoo/session--start-agent-in-tab
       "/tmp/proj" "incident-42" '(fake-feature-a fake-feature-b)
       (lambda () (setq started-in-dir (funcall agent-shell-cwd-function)))))
    (should (equal tab-label "incident-42"))
    (should (equal (reverse required) '(fake-feature-a fake-feature-b)))
    (should (equal started-in-dir "/tmp/proj"))))

(ert-deftest hoodoo/session-test-claude-start-in-delegates ()
  (let (call-args)
    (cl-letf (((symbol-function 'hoodoo/session--start-agent-in-tab)
               (lambda (&rest args) (setq call-args args))))
      (hoodoo/claude-start-in "/tmp/proj" "incident-42"))
    (should (equal (nth 0 call-args) "/tmp/proj"))
    (should (equal (nth 1 call-args) "incident-42"))
    (should (equal (nth 2 call-args) '(agent-shell-anthropic agent-shell-project)))
    (should (eq (nth 3 call-args) #'agent-shell-anthropic-start-claude-code))))

(ert-deftest hoodoo/session-test-codex-start-in-delegates ()
  (let (call-args)
    (cl-letf (((symbol-function 'hoodoo/session--start-agent-in-tab)
               (lambda (&rest args) (setq call-args args))))
      (hoodoo/codex-start-in "/tmp/proj" "incident-42"))
    (should (equal (nth 0 call-args) "/tmp/proj"))
    (should (equal (nth 1 call-args) "incident-42"))
    (should (equal (nth 2 call-args) '(agent-shell-openai agent-shell-project)))
    (should (eq (nth 3 call-args) #'agent-shell-openai-start-codex))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `hoodoo/session--start-agent-in-tab` is void.

- [ ] **Step 3: Write minimal implementation**

Add to `hoodoo-session-context.el`, after `hoodoo/session--start-in-tab` (before the `add-hook` wiring line, so all `defun`s stay grouped):

```elisp
(defun hoodoo/session--start-agent-in-tab (dir label require-features start-fn)
  "Require REQUIRE-FEATURES, then start an agent shell rooted at DIR in a
new tab named LABEL.  START-FN is called with no arguments, inside a
`let' that binds `agent-shell-cwd-function' to return DIR."
  (dolist (feature require-features)
    (require feature))
  (hoodoo/session--start-in-tab
   label
   (lambda ()
     (let ((agent-shell-cwd-function (lambda () dir)))
       (funcall start-fn)))))

(defun hoodoo/claude-start-in (dir label)
  "Start a fresh Claude Code shell rooted at DIR, in its own tab named LABEL.
Leaves existing Claude shells alone."
  (interactive
   (let ((dir (read-directory-name
               "Start Claude in: "
               (or (when-let ((proj (project-current))) (project-root proj))
                   default-directory))))
     (list dir (read-string "Session label: " (hoodoo/session--default-label dir)))))
  (hoodoo/session--start-agent-in-tab
   dir label
   '(agent-shell-anthropic agent-shell-project)
   #'agent-shell-anthropic-start-claude-code))

(defun hoodoo/codex-start-in (dir label)
  "Start a fresh Codex shell rooted at DIR, in its own tab named LABEL.
Leaves existing Codex shells alone."
  (interactive
   (let ((dir (read-directory-name
               "Start Codex in: "
               (or (when-let ((proj (project-current))) (project-root proj))
                   default-directory))))
     (list dir (read-string "Session label: " (hoodoo/session--default-label dir)))))
  (hoodoo/session--start-agent-in-tab
   dir label
   '(agent-shell-openai agent-shell-project)
   #'agent-shell-openai-start-codex))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — `Ran 19 tests, 19 results as expected`

- [ ] **Step 5: Commit**

```bash
git add hoodoo-session-context.el tests/hoodoo-session-context-test.el
git commit -m "Add hoodoo/claude-start-in and hoodoo/codex-start-in with tab creation"
```

---

### Task 7: Session-aware context-buffer commands

**Files:**
- Modify: `hoodoo-session-context.el`
- Test: `tests/hoodoo-session-context-test.el`

**Interfaces:**
- Consumes: `hoodoo/session--require-current-session-buffer` (Task 3), `hoodoo/session--tag-buffer` (Task 2).
- Produces:
  - `hoodoo/session--create-and-tag (create-fn)` → calls 0-arg CREATE-FN, tags the buffer it leaves current to the current tab's session, displays it via `display-buffer`, returns it.
  - `hoodoo/session-eat ()` — interactive; `(hoodoo/session--create-and-tag #'eat)`.
  - `hoodoo/session-magit-status ()` — interactive; `(hoodoo/session--create-and-tag #'magit-status)`.
  - `hoodoo/session-dired ()` — interactive; opens dired on `default-directory`, tagged.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hoodoo-session-context-test.el`:

```elisp
(ert-deftest hoodoo/session-test-create-and-tag ()
  (let ((session (generate-new-buffer "agent"))
        (created (generate-new-buffer "fake-eat"))
        (displayed nil))
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer session (setq major-mode 'agent-shell-mode))
          (switch-to-buffer session)
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (buf &rest _) (setq displayed buf) nil)))
            (let ((result (hoodoo/session--create-and-tag
                            (lambda () (switch-to-buffer created)))))
              (should (eq result created))))
          (should (eq (buffer-local-value 'hoodoo/session-buffer created) session))
          (should (eq displayed created)))
      (mapc #'kill-buffer (list session created))
      (delete-other-windows))))

(ert-deftest hoodoo/session-test-create-and-tag-requires-session ()
  (let ((scratch (get-buffer-create "*scratch*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer scratch)
          (should-error (hoodoo/session--create-and-tag (lambda () nil))
                        :type 'user-error))
      (delete-other-windows))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `hoodoo/session--create-and-tag` is void.

- [ ] **Step 3: Write minimal implementation**

Add to `hoodoo-session-context.el`, after `hoodoo/codex-start-in`:

```elisp
(defun hoodoo/session--create-and-tag (create-fn)
  "Call CREATE-FN, tag the buffer it leaves current to the current tab's
session, display it via `display-buffer', and return it."
  (let* ((session (hoodoo/session--require-current-session-buffer))
         (buf (save-window-excursion (funcall create-fn) (current-buffer))))
    (hoodoo/session--tag-buffer buf session)
    (display-buffer buf)
    buf))

(defun hoodoo/session-eat ()
  "Open an eat buffer tagged to the current tab's agent-shell session."
  (interactive)
  (hoodoo/session--create-and-tag #'eat))

(defun hoodoo/session-magit-status ()
  "Open magit-status tagged to the current tab's agent-shell session."
  (interactive)
  (hoodoo/session--create-and-tag #'magit-status))

(defun hoodoo/session-dired ()
  "Open dired tagged to the current tab's agent-shell session."
  (interactive)
  (hoodoo/session--create-and-tag (lambda () (dired default-directory))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — `Ran 21 tests, 21 results as expected`

- [ ] **Step 5: Commit**

```bash
git add hoodoo-session-context.el tests/hoodoo-session-context-test.el
git commit -m "Add session-aware eat/magit-status/dired commands"
```

---

### Task 8: Manual buffer attachment

**Files:**
- Modify: `hoodoo-session-context.el`
- Test: `tests/hoodoo-session-context-test.el`

**Interfaces:**
- Consumes: `hoodoo/session--require-current-session-buffer` (Task 3), `hoodoo/session--tag-buffer` (Task 2).
- Produces: `hoodoo/session-attach-buffer (buffer)` — interactive; attaches an existing BUFFER to the current tab's session. Confirms before reattaching a buffer that's already attached to a different, live session.

- [ ] **Step 1: Write the failing tests**

Append to `tests/hoodoo-session-context-test.el`:

```elisp
(ert-deftest hoodoo/session-test-attach-buffer ()
  (let ((session (generate-new-buffer "agent"))
        (target (generate-new-buffer "ssh-terminal")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer session (setq major-mode 'agent-shell-mode))
          (switch-to-buffer session)
          (hoodoo/session-attach-buffer target)
          (should (eq (buffer-local-value 'hoodoo/session-buffer target) session)))
      (mapc #'kill-buffer (list session target))
      (delete-other-windows))))

(ert-deftest hoodoo/session-test-attach-buffer-confirms-reassignment ()
  (let ((session-a (generate-new-buffer "agent-a"))
        (session-b (generate-new-buffer "agent-b"))
        (target (generate-new-buffer "ssh-terminal"))
        (asked nil))
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer session-b (setq major-mode 'agent-shell-mode))
          (hoodoo/session--tag-buffer target session-a)
          (switch-to-buffer session-b)
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (&rest _) (setq asked t) nil)))
            (should-error (hoodoo/session-attach-buffer target) :type 'user-error))
          (should asked)
          ;; Declined reassignment: still attached to session-a.
          (should (eq (buffer-local-value 'hoodoo/session-buffer target) session-a)))
      (mapc #'kill-buffer (list session-a session-b target))
      (delete-other-windows))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `hoodoo/session-attach-buffer` is void.

- [ ] **Step 3: Write minimal implementation**

Add to `hoodoo-session-context.el`, after `hoodoo/session-dired`:

```elisp
(defun hoodoo/session-attach-buffer (buffer)
  "Attach an existing BUFFER to the current tab's agent-shell session."
  (interactive
   (let* ((session (hoodoo/session--require-current-session-buffer))
          (candidates
           (seq-remove
            (lambda (buf)
              (or (eq buf session)
                  (eq (buffer-local-value 'hoodoo/session-buffer buf) session)))
            (buffer-list))))
     (list (get-buffer (completing-read "Attach buffer: "
                                         (mapcar #'buffer-name candidates) nil t)))))
  (let* ((session (hoodoo/session--require-current-session-buffer))
         (existing (buffer-local-value 'hoodoo/session-buffer buffer)))
    (when (and existing (not (eq existing session)) (buffer-live-p existing)
               (not (y-or-n-p (format "%s is already attached to %s; reattach? "
                                       (buffer-name buffer) (buffer-name existing)))))
      (user-error "Not attaching %s" (buffer-name buffer)))
    (hoodoo/session--tag-buffer buffer session)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — `Ran 23 tests, 23 results as expected`

- [ ] **Step 5: Commit**

```bash
git add hoodoo-session-context.el tests/hoodoo-session-context-test.el
git commit -m "Add hoodoo/session-attach-buffer for pre-existing buffers"
```

---

### Task 9: Wire into init.el

**Files:**
- Modify: `init.el:169-215` (the `agent-shell` `use-package` block)

**Interfaces:**
- Consumes: `hoodoo/claude-start-in`, `hoodoo/codex-start-in` (Task 6), `hoodoo/session-eat`, `hoodoo/session-magit-status`, `hoodoo/session-dired`, `hoodoo/session-attach-buffer` (Tasks 7, 8).
- Produces: nothing new — this task only rewires `init.el` to load the library and expose the new commands as keybindings.

- [ ] **Step 1: Replace the `agent-shell` use-package block**

In `init.el`, replace lines 169-215 (from `(use-package agent-shell` through the closing of the old `:preface`) with:

```elisp
(use-package agent-shell
  :straight t
  :commands (agent-shell
             agent-shell-resume-session
             agent-shell-fork
             agent-shell-anthropic-start-claude-code
	     agent-shell-openai-start-codex)
  :custom
  (agent-shell-session-strategy 'prompt)
  (agent-shell-prefer-session-resume t)
  :bind
  (("C-c a c" . hoodoo/claude-start-in)
   ("C-c a d" . hoodoo/claude-start-in)
   ("C-c a l" . agent-shell)
   ("C-c a r" . agent-shell-resume-session)
   ("C-c a f" . agent-shell-fork)
   ("C-c a e" . hoodoo/session-eat)
   ("C-c a m" . hoodoo/session-magit-status)
   ("C-c a j" . hoodoo/session-dired)
   ("C-c a a" . hoodoo/session-attach-buffer))
  :config
  ;; Ties eat/magit/dired buffers to the agent-shell session (buffer)
  ;; they support, and gives each session its own tab-bar tab.
  ;; See hoodoo-session-context.el and
  ;; docs/superpowers/specs/2026-07-21-agent-shell-session-context-design.md
  (require 'hoodoo-session-context
           (expand-file-name "hoodoo-session-context.el" user-emacs-directory)))
```

Note what changed from the original: `hoodoo/claude-start-in` and `hoodoo/codex-start-in` are no longer defined in `:preface` — they now live in `hoodoo-session-context.el` (Task 6) and are pulled in via the `require` in `:config`. Three new keybindings (`C-c a e`, `C-c a m`, `C-c a j`) and the attach command (`C-c a a`) are added. The `:commands` list is unchanged, since it only names commands autoloaded from the `agent-shell` package itself.

- [ ] **Step 2: Verify init.el still parses cleanly**

Run: `emacs -Q --batch --eval "(with-temp-buffer (insert-file-contents \"init.el\") (condition-case err (progn (goto-char (point-min)) (while (not (eobp)) (read (current-buffer))) (message \"init.el reads cleanly\")) (end-of-file (message \"reached EOF cleanly\")) (error (message \"PARSE ERROR: %S\" err))))"`
Expected: `reached EOF cleanly` (same check used when this repo's `auto-side-windows` fix was verified).

- [ ] **Step 3: Verify the full library still loads and all tests still pass**

Run: `emacs -Q --batch -l ert -l hoodoo-session-context.el -l tests/hoodoo-session-context-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — `Ran 23 tests, 23 results as expected` (no regressions from the init.el rewiring, since `hoodoo-session-context.el` itself didn't change in this task).

- [ ] **Step 4: Commit**

```bash
git add init.el
git commit -m "Wire hoodoo-session-context into the agent-shell use-package block"
```

- [ ] **Step 5: Manual interactive verification (not headlessly testable)**

Start real Emacs with this config and confirm by hand:
1. `M-x hoodoo/claude-start-in`, pick a directory, accept/edit the default label — a new tab appears named after your label, with a Claude Code session running in it.
2. `C-c a e` inside that tab — an eat buffer appears in the bottom side window (per `auto-side-windows`), tagged to the session.
3. `C-c a m` — magit-status appears in the right side window, tagged.
4. Switch to another tab and back (`C-x t o` or a fresh `hoodoo/claude-start-in` in a different directory, then switch back) — the eat/magit windows from step 2/3 are still there, laid out as you left them.
5. Kill the agent-shell buffer (`C-x k` on it, or however you normally end a session) — confirm the multi-select prompt appears listing the eat and magit buffers, with eat and magit pre-checked; accept the defaults; confirm those buffers are gone and the tab has closed.
6. `C-c a a` in a tab with no attached buffers yet, targeting some unrelated already-open buffer (e.g. a dired buffer you opened manually beforehand) — confirm it becomes attached (repeat step 5's kill to see it offered for cleanup).

---

# claude-session-log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `claude-session-log.el`, a pure Emacs Lisp parser that turns a
Claude Code session's JSONL log file (plus its sibling `subagents/`
directory) into a `claude-session-log-session` struct: token usage, cost,
models used, files touched, git branch/cwd history, and the latest
task-list snapshot.

**Architecture:** One file, no presentation layer, no live file watching,
no dependency on `hoodoo-session-context`. A single entry point,
`claude-session-log-parse-file`, does one full synchronous parse per call.
Internally: read JSONL lines -> fold them into a session struct -> find
and parse sibling subagents -> compute costs (folding subagent cost into
the session's `total-cost`).

**Tech Stack:** Emacs Lisp built-ins only — `json` (`json-parse-string`,
native JSON since Emacs 27), `iso8601` (`iso8601-parse`, bundled since
Emacs 27), `cl-lib`, `seq`. No third-party packages. Tests: ERT, run via
`emacs -Q --batch`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-23-claude-session-log-design.md`.
  Every task's requirements implicitly include that spec's non-goals (no
  presentation, no live-watching, no `hoodoo-session-context` dependency,
  no wall-time bucketing/activity-timeline heuristics).
- Requires Emacs 27+ (for `json-parse-string` and `iso8601-parse`, both
  confirmed available and working in this repo's Emacs 29.3).
- Library file: `claude-session-log.el` at the repo root (same placement
  as `hoodoo-session-context.el`).
- Test file: `tests/claude-session-log-test.el` (same placement/naming as
  `tests/hoodoo-session-context-test.el`).
- Test run command (confirmed working in this repo):
  `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`
- Struct field naming deviates from the spec's subagent sketch in one
  place: the spec wrote `usage`/`cost` for `claude-session-log-subagent`;
  this plan uses `usage-by-model`/`total-cost` to match the parent
  session struct's field names exactly (same shape, same name). No other
  deviation from the spec.
- Cost table, cache multipliers, and the file-touching tool list
  (`Edit`/`Write`/`Read`/`NotebookEdit`) are exactly as specified in the
  design doc — copy the values verbatim, do not re-derive them.
- Commit after every task (this repo's history is many small, focused
  commits — match that granularity, not one commit at the end).

---

### Task 1: Structs, price table, price lookup

**Files:**
- Create: `claude-session-log.el`
- Test: `tests/claude-session-log-test.el`

**Interfaces:**
- Produces: `claude-session-log-session` struct (fields: `session-id
  source-path start-time end-time duration-seconds models
  usage-by-model cost-by-model total-cost unpriced-models files-touched
  cwds branches task-list subagents events`), `claude-session-log-subagent`
  struct (fields: `agent-type description model spawn-depth tool-use-id
  usage-by-model total-cost`), `claude-session-log-model-prices` alist
  constant, `claude-session-log--price-per-million` function returning
  `(input-price . output-price)` or nil.

- [ ] **Step 1: Write the failing tests**

Create `tests/claude-session-log-test.el`:

```elisp
;;; claude-session-log-test.el --- Tests for claude-session-log -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(ert-deftest claude-session-log-test-price-per-million-known-model ()
  (should (equal (claude-session-log--price-per-million "claude-sonnet-5")
                 '(2.00 . 10.00)))
  (should (equal (claude-session-log--price-per-million "claude-opus-4-8")
                 '(5.00 . 25.00)))
  (should (equal (claude-session-log--price-per-million "claude-haiku-4-5")
                 '(1.00 . 5.00))))

(ert-deftest claude-session-log-test-price-per-million-unknown-model ()
  (should (null (claude-session-log--price-per-million "claude-nonexistent-9"))))

(ert-deftest claude-session-log-test-session-struct-accessors ()
  (let ((s (make-claude-session-log-session :session-id "abc"
                                             :source-path "/tmp/abc.jsonl")))
    (should (equal (claude-session-log-session-session-id s) "abc"))
    (should (equal (claude-session-log-session-source-path s) "/tmp/abc.jsonl"))
    (should (null (claude-session-log-session-models s)))))

(ert-deftest claude-session-log-test-subagent-struct-accessors ()
  (let ((s (make-claude-session-log-subagent :agent-type "general-purpose"
                                              :model "claude-sonnet-5")))
    (should (equal (claude-session-log-subagent-agent-type s) "general-purpose"))
    (should (equal (claude-session-log-subagent-model s) "claude-sonnet-5"))
    (should (null (claude-session-log-subagent-total-cost s)))))

(provide 'claude-session-log-test)
;;; claude-session-log-test.el ends here
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -L . -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: fails to load — `claude-session-log.el` does not exist yet, so
requiring/byte-loading the test file errors before any test runs (there
is nothing to `-l claude-session-log.el` yet, so omit that flag for this
one verification run).

- [ ] **Step 3: Write the implementation**

Create `claude-session-log.el`:

```elisp
;;; claude-session-log.el --- Parse Claude Code session JSONL logs -*- lexical-binding: t; -*-

;;; Commentary:
;; Parses a Claude Code session's JSONL log file (and its sibling
;; subagents/ directory) into structured data: token usage, cost,
;; models used, files touched, git branch/cwd history, and the latest
;; task-list snapshot. Pure parsing only -- no presentation, no live
;; file watching.
;; See docs/superpowers/specs/2026-07-23-claude-session-log-design.md

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'iso8601)
(require 'seq)

(cl-defstruct claude-session-log-session
  session-id
  source-path
  start-time end-time duration-seconds
  models
  usage-by-model
  cost-by-model
  total-cost
  unpriced-models
  files-touched
  cwds branches
  task-list
  subagents
  events)

(cl-defstruct claude-session-log-subagent
  agent-type description model spawn-depth tool-use-id
  usage-by-model
  total-cost)

(defconst claude-session-log-model-prices
  '(("claude-fable-5" . (10.00 . 50.00))
    ("claude-mythos-5" . (10.00 . 50.00))
    ("claude-opus-4-8" . (5.00 . 25.00))
    ("claude-opus-4-7" . (5.00 . 25.00))
    ("claude-opus-4-6" . (5.00 . 25.00))
    ("claude-sonnet-5" . (2.00 . 10.00))
    ("claude-sonnet-4-6" . (3.00 . 15.00))
    ("claude-haiku-4-5" . (1.00 . 5.00)))
  "Alist of model id to (dollars-per-1M-input . dollars-per-1M-output).
Sourced from the `claude-api' skill's cached pricing table, current as
of 2026-06-24. `claude-sonnet-5' uses its introductory rate ($2/$10,
in effect through 2026-08-31) since that is what is actually billing
now; update this row once that window ends. This table needs manual
upkeep as Anthropic's pricing changes generally -- an accepted,
known maintenance cost, not a bug.")

(defconst claude-session-log-cache-write-5m-multiplier 1.25
  "Cost multiplier (on the model's input price) for 5-minute-TTL cache writes.")

(defconst claude-session-log-cache-write-1h-multiplier 2.0
  "Cost multiplier (on the model's input price) for 1-hour-TTL cache writes.")

(defconst claude-session-log-cache-read-multiplier 0.1
  "Cost multiplier (on the model's input price) for cache reads.")

(defconst claude-session-log-file-touching-tools '("Edit" "Write" "Read" "NotebookEdit")
  "Tool names whose `tool_use' blocks carry a `file_path' input worth
recording in a session's `files-touched' list.")

(defun claude-session-log--price-per-million (model)
  "Return (input-price . output-price), dollars per 1M tokens, for MODEL.
Returns nil if MODEL has no entry in `claude-session-log-model-prices'."
  (cdr (assoc model claude-session-log-model-prices)))

(provide 'claude-session-log)
;;; claude-session-log.el ends here
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 4 tests, 4 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-log.el tests/claude-session-log-test.el
git commit -m "$(cat <<'EOF'
Add claude-session-log structs and price table

Scaffolding for the Claude Code session-log parser: the session/
subagent structs and a static per-model price table for cost
computation, per the design doc.
EOF
)"
```

---

### Task 2: JSONL line reading

**Files:**
- Modify: `claude-session-log.el`
- Test: `tests/claude-session-log-test.el`

**Interfaces:**
- Consumes: nothing new from Task 1.
- Produces: `claude-session-log--read-jsonl-lines (path)` -> ordered list
  of parsed plists (one per non-blank, successfully-parsed line), using
  `:object-type 'plist :array-type 'list :null-object nil :false-object nil`.

- [ ] **Step 1: Write the failing test**

Append to `tests/claude-session-log-test.el` (before the `provide` form):

```elisp
(ert-deftest claude-session-log-test-read-jsonl-lines-skips-blank-and-malformed ()
  (let ((path (make-temp-file "claude-session-log-test" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "{\"type\":\"a\",\"timestamp\":\"t1\"}\n")
            (insert "\n")
            (insert "{\"type\":\"b\",\"timestamp\":\"t2\"}\n")
            (insert "not valid json{{{\n")
            (insert "{\"type\":\"c\",\"timestamp\":\"t3\"}\n"))
          (let ((lines (claude-session-log--read-jsonl-lines path)))
            (should (= (length lines) 3))
            (should (equal (mapcar (lambda (l) (plist-get l :type)) lines)
                           '("a" "b" "c")))
            (should (equal (mapcar (lambda (l) (plist-get l :timestamp)) lines)
                           '("t1" "t2" "t3")))))
      (delete-file path))))

(ert-deftest claude-session-log-test-read-jsonl-lines-nested-objects ()
  (let ((path (make-temp-file "claude-session-log-test" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":10}}}\n"))
          (let* ((lines (claude-session-log--read-jsonl-lines path))
                 (line (car lines))
                 (message (plist-get line :message)))
            (should (equal (plist-get message :model) "claude-sonnet-5"))
            (should (equal (plist-get (plist-get message :usage) :input_tokens) 10))))
      (delete-file path))))
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: the 4 Task 1 tests still pass; the 2 new tests fail with
`void-function claude-session-log--read-jsonl-lines`.

- [ ] **Step 3: Write the implementation**

Add to `claude-session-log.el` (after the `--price-per-million` defun,
before `(provide 'claude-session-log)`):

```elisp
(defun claude-session-log--read-jsonl-lines (path)
  "Read PATH as JSONL, returning an ordered list of parsed plists.
Blank lines are skipped. A line that fails to parse as JSON is also
skipped -- Claude Code's session files are append-only and can be read
while still being written, which can leave a partial final line."
  (let (lines)
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (unless (string-blank-p line)
            (let ((parsed (ignore-errors
                            (json-parse-string
                             line
                             :object-type 'plist
                             :array-type 'list
                             :null-object nil
                             :false-object nil))))
              (when parsed (push parsed lines)))))
        (forward-line 1)))
    (nreverse lines)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 6 tests, 6 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-log.el tests/claude-session-log-test.el
git commit -m "Add claude-session-log JSONL line reading"
```

---

### Task 3: Usage normalization, timestamp, and file-touch helpers

**Files:**
- Modify: `claude-session-log.el`
- Test: `tests/claude-session-log-test.el`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `claude-session-log--zero-usage ()` -> usage plist `(:input 0
    :output 0 :cache-write-5m 0 :cache-write-1h 0 :cache-read 0)`
  - `claude-session-log--usage-plist-from-json (usage)` -> normalized
    usage plist from a raw `message.usage` plist (handles the
    5m/1h-split-vs-combined `cache_creation` fallback)
  - `claude-session-log--merge-usage (a b)` -> fieldwise-summed usage plist
  - `claude-session-log--parse-timestamp (timestamp)` -> Lisp time value or nil
  - `claude-session-log--seconds-between (start end)` -> float seconds or nil
  - `claude-session-log--file-touches-in-content (content)` -> list of
    `file_path` strings from `Edit`/`Write`/`Read`/`NotebookEdit`
    `tool_use` blocks in CONTENT (nil-safe for plain-string content)

- [ ] **Step 1: Write the failing tests**

Append to `tests/claude-session-log-test.el`:

```elisp
(ert-deftest claude-session-log-test-zero-usage ()
  (should (equal (claude-session-log--zero-usage)
                 '(:input 0 :output 0 :cache-write-5m 0 :cache-write-1h 0 :cache-read 0))))

(ert-deftest claude-session-log-test-usage-plist-from-json-split-cache ()
  (let ((usage '(:input_tokens 100 :output_tokens 50
                 :cache_creation_input_tokens 200 :cache_read_input_tokens 300
                 :cache_creation (:ephemeral_5m_input_tokens 0
                                  :ephemeral_1h_input_tokens 200))))
    (should (equal (claude-session-log--usage-plist-from-json usage)
                   '(:input 100 :output 50 :cache-write-5m 0
                     :cache-write-1h 200 :cache-read 300)))))

(ert-deftest claude-session-log-test-usage-plist-from-json-combined-fallback ()
  ;; No `cache_creation' split object: the combined field is attributed
  ;; to the 5-minute rate, per the design doc's fallback rule.
  (let ((usage '(:input_tokens 10 :output_tokens 5
                 :cache_creation_input_tokens 40 :cache_read_input_tokens 0)))
    (should (equal (claude-session-log--usage-plist-from-json usage)
                   '(:input 10 :output 5 :cache-write-5m 40
                     :cache-write-1h 0 :cache-read 0)))))

(ert-deftest claude-session-log-test-usage-plist-from-json-missing-fields ()
  (should (equal (claude-session-log--usage-plist-from-json '(:input_tokens 1))
                 '(:input 1 :output 0 :cache-write-5m 0 :cache-write-1h 0 :cache-read 0))))

(ert-deftest claude-session-log-test-merge-usage ()
  (should (equal (claude-session-log--merge-usage
                  '(:input 100 :output 50 :cache-write-5m 0 :cache-write-1h 200 :cache-read 300)
                  '(:input 10 :output 5 :cache-write-5m 40 :cache-write-1h 0 :cache-read 0))
                 '(:input 110 :output 55 :cache-write-5m 40 :cache-write-1h 200 :cache-read 300))))

(ert-deftest claude-session-log-test-seconds-between ()
  (should (= (claude-session-log--seconds-between
              "2026-07-21T10:00:00.000Z" "2026-07-21T10:00:12.000Z")
             12.0))
  (should (null (claude-session-log--seconds-between nil "2026-07-21T10:00:12.000Z")))
  (should (null (claude-session-log--seconds-between "2026-07-21T10:00:00.000Z" nil))))

(ert-deftest claude-session-log-test-file-touches-in-content ()
  (let ((content '((:type "text" :text "ok")
                    (:type "tool_use" :id "tu0" :name "Bash" :input (:command "ls"))
                    (:type "tool_use" :id "tu1" :name "Edit"
                     :input (:file_path "/tmp/a.el" :old_string "a" :new_string "b"))
                    (:type "tool_use" :id "tu2" :name "Read"
                     :input (:file_path "/tmp/b.el")))))
    (should (equal (claude-session-log--file-touches-in-content content)
                   '("/tmp/a.el" "/tmp/b.el")))))

(ert-deftest claude-session-log-test-file-touches-in-content-string-content ()
  (should (null (claude-session-log--file-touches-in-content "plain text content"))))

(ert-deftest claude-session-log-test-file-touches-in-content-nil ()
  (should (null (claude-session-log--file-touches-in-content nil))))
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: the 6 earlier tests still pass; the 9 new tests fail with
`void-function` errors for whichever helper each test calls first.

- [ ] **Step 3: Write the implementation**

Add to `claude-session-log.el` (before `(provide 'claude-session-log)`):

```elisp
(defun claude-session-log--zero-usage ()
  "Return a zeroed usage plist."
  (list :input 0 :output 0 :cache-write-5m 0 :cache-write-1h 0 :cache-read 0))

(defun claude-session-log--usage-plist-from-json (usage)
  "Normalize a raw `message.usage' plist USAGE into this library's
internal usage-plist shape. Prefers the split
`cache_creation.ephemeral_5m_input_tokens' /
`ephemeral_1h_input_tokens' fields when present, falling back to the
combined `cache_creation_input_tokens' field (attributed to the
5-minute rate) when the split object is absent."
  (let ((cache-creation (plist-get usage :cache_creation))
        (combined (or (plist-get usage :cache_creation_input_tokens) 0)))
    (list :input (or (plist-get usage :input_tokens) 0)
          :output (or (plist-get usage :output_tokens) 0)
          :cache-write-5m (if cache-creation
                               (or (plist-get cache-creation :ephemeral_5m_input_tokens) 0)
                             combined)
          :cache-write-1h (if cache-creation
                               (or (plist-get cache-creation :ephemeral_1h_input_tokens) 0)
                             0)
          :cache-read (or (plist-get usage :cache_read_input_tokens) 0))))

(defun claude-session-log--merge-usage (a b)
  "Return a new usage plist summing usage plists A and B fieldwise."
  (list :input (+ (plist-get a :input) (plist-get b :input))
        :output (+ (plist-get a :output) (plist-get b :output))
        :cache-write-5m (+ (plist-get a :cache-write-5m) (plist-get b :cache-write-5m))
        :cache-write-1h (+ (plist-get a :cache-write-1h) (plist-get b :cache-write-1h))
        :cache-read (+ (plist-get a :cache-read) (plist-get b :cache-read))))

(defun claude-session-log--parse-timestamp (timestamp)
  "Parse an ISO 8601 TIMESTAMP string into a Lisp time value, or nil."
  (when timestamp
    (encode-time (iso8601-parse timestamp))))

(defun claude-session-log--seconds-between (start end)
  "Return the number of seconds between ISO 8601 timestamps START and
END, or nil if either is missing."
  (when (and start end)
    (float-time (time-subtract (claude-session-log--parse-timestamp end)
                                (claude-session-log--parse-timestamp start)))))

(defun claude-session-log--file-touches-in-content (content)
  "Return `file_path' values from `Edit'/`Write'/`Read'/`NotebookEdit'
`tool_use' blocks in CONTENT (a message's content-block list). CONTENT
may also be a plain string (a user message with no blocks) or nil, in
which case this returns nil."
  (when (listp content)
    (delq nil
          (mapcar (lambda (block)
                    (when (and (equal (plist-get block :type) "tool_use")
                               (member (plist-get block :name)
                                       claude-session-log-file-touching-tools))
                      (plist-get (plist-get block :input) :file_path)))
                  content))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 15 tests, 15 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-log.el tests/claude-session-log-test.el
git commit -m "Add claude-session-log usage/timestamp/file-touch helpers"
```

---

### Task 4: Fold parsed lines into a session struct

**Files:**
- Modify: `claude-session-log.el`
- Test: `tests/claude-session-log-test.el`

**Interfaces:**
- Consumes: `claude-session-log--usage-plist-from-json`,
  `claude-session-log--merge-usage`, `claude-session-log--seconds-between`,
  `claude-session-log--file-touches-in-content` (Task 3);
  `claude-session-log-session` struct (Task 1).
- Produces: `claude-session-log--parse-lines (session-id source-path
  lines)` -> a `claude-session-log-session` struct with `session-id
  source-path start-time end-time duration-seconds models
  usage-by-model files-touched cwds branches task-list events` filled
  in. `cost-by-model`, `total-cost`, `unpriced-models`, and `subagents`
  are left nil — later tasks fill those in.

- [ ] **Step 1: Write the failing test**

Append to `tests/claude-session-log-test.el`:

```elisp
(defconst claude-session-log-test--fixture-lines
  (list
   '(:type "user" :timestamp "2026-07-21T10:00:00.000Z"
     :cwd "/home/hoooo/.emacs.d" :gitBranch "main"
     :message (:role "user" :content "Do the thing"))
   '(:type "assistant" :timestamp "2026-07-21T10:00:05.000Z"
     :cwd "/home/hoooo/.emacs.d" :gitBranch "main"
     :message (:role "assistant" :model "claude-sonnet-5"
               :content ((:type "text" :text "ok")
                         (:type "tool_use" :id "tu1" :name "Edit"
                          :input (:file_path "/home/hoooo/.emacs.d/init.el"
                                  :old_string "a" :new_string "b")))
               :usage (:input_tokens 100 :output_tokens 50
                       :cache_creation_input_tokens 200
                       :cache_read_input_tokens 300
                       :cache_creation (:ephemeral_5m_input_tokens 0
                                        :ephemeral_1h_input_tokens 200))))
   '(:type "assistant" :timestamp "2026-07-21T10:00:06.000Z"
     :message (:role "assistant" :model "<synthetic>"
               :content ((:type "text" :text "interrupted"))))
   '(:type "assistant" :timestamp "2026-07-21T10:00:10.000Z"
     :cwd "/home/hoooo/.emacs.d" :gitBranch "worktree-agent-shell"
     :message (:role "assistant" :model "claude-sonnet-5"
               :content ((:type "tool_use" :id "tu2" :name "Read"
                          :input (:file_path "/home/hoooo/.emacs.d/init.el")))
               :usage (:input_tokens 10 :output_tokens 5
                       :cache_creation_input_tokens 40
                       :cache_read_input_tokens 0)))
   '(:type "attachment" :timestamp "2026-07-21T10:00:11.000Z"
     :attachment (:type "task_reminder" :itemCount 1
                  :content ((:id "1" :subject "Task 1" :description "d1"
                             :status "pending" :blocks () :blockedBy ()))))
   '(:type "attachment" :timestamp "2026-07-21T10:00:12.000Z"
     :attachment (:type "task_reminder" :itemCount 1
                  :content ((:id "1" :subject "Task 1" :description "d1"
                             :status "completed" :blocks () :blockedBy ())))))
  "Shared fixture for `claude-session-log--parse-lines' tests, mirroring
verified real Claude Code JSONL line shapes.")

(ert-deftest claude-session-log-test-parse-lines-times ()
  (let ((s (claude-session-log--parse-lines
            "test-session" "/tmp/test-session.jsonl"
            claude-session-log-test--fixture-lines)))
    (should (equal (claude-session-log-session-start-time s) "2026-07-21T10:00:00.000Z"))
    (should (equal (claude-session-log-session-end-time s) "2026-07-21T10:00:12.000Z"))
    (should (= (claude-session-log-session-duration-seconds s) 12.0))))

(ert-deftest claude-session-log-test-parse-lines-models-and-usage ()
  (let ((s (claude-session-log--parse-lines
            "test-session" "/tmp/test-session.jsonl"
            claude-session-log-test--fixture-lines)))
    ;; "<synthetic>" must be excluded.
    (should (equal (claude-session-log-session-models s) '("claude-sonnet-5")))
    (should (equal (cdr (assoc "claude-sonnet-5" (claude-session-log-session-usage-by-model s)))
                   '(:input 110 :output 55 :cache-write-5m 40
                     :cache-write-1h 200 :cache-read 300)))))

(ert-deftest claude-session-log-test-parse-lines-files-cwds-branches ()
  (let ((s (claude-session-log--parse-lines
            "test-session" "/tmp/test-session.jsonl"
            claude-session-log-test--fixture-lines)))
    ;; Edit and Read both touch the same file -- deduped to one entry.
    (should (equal (claude-session-log-session-files-touched s)
                   '("/home/hoooo/.emacs.d/init.el")))
    (should (equal (claude-session-log-session-cwds s) '("/home/hoooo/.emacs.d")))
    (should (equal (claude-session-log-session-branches s)
                   '("main" "worktree-agent-shell")))))

(ert-deftest claude-session-log-test-parse-lines-task-list-last-wins ()
  (let* ((s (claude-session-log--parse-lines
             "test-session" "/tmp/test-session.jsonl"
             claude-session-log-test--fixture-lines))
         (task-list (claude-session-log-session-task-list s)))
    (should (equal (plist-get (car (plist-get task-list :content)) :status)
                   "completed"))))

(ert-deftest claude-session-log-test-parse-lines-events ()
  (let* ((s (claude-session-log--parse-lines
             "test-session" "/tmp/test-session.jsonl"
             claude-session-log-test--fixture-lines))
         (events (claude-session-log-session-events s)))
    ;; One event per user/assistant line (3 assistant + 1 user); the two
    ;; `attachment' lines don't produce events.
    (should (= (length events) 4))
    (should (equal (mapcar (lambda (e) (plist-get e :role)) events)
                   '("user" "assistant" "assistant" "assistant")))))

(ert-deftest claude-session-log-test-parse-lines-leaves-cost-and-subagents-nil ()
  (let ((s (claude-session-log--parse-lines
            "test-session" "/tmp/test-session.jsonl"
            claude-session-log-test--fixture-lines)))
    (should (null (claude-session-log-session-cost-by-model s)))
    (should (null (claude-session-log-session-total-cost s)))
    (should (null (claude-session-log-session-unpriced-models s)))
    (should (null (claude-session-log-session-subagents s)))))
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: the 15 earlier tests still pass; the 6 new tests fail with
`void-function claude-session-log--parse-lines`.

- [ ] **Step 3: Write the implementation**

Add to `claude-session-log.el` (before `(provide 'claude-session-log)`):

```elisp
(defun claude-session-log--parse-lines (session-id source-path lines)
  "Fold parsed JSONL LINES into a `claude-session-log-session' struct
for SESSION-ID at SOURCE-PATH. `cost-by-model', `total-cost',
`unpriced-models', and `subagents' are left nil -- callers fill those
in separately (see `claude-session-log--apply-costs' and
`claude-session-log--find-subagent-meta-files')."
  (let ((usage-table (make-hash-table :test #'equal))
        models files-touched cwds branches events
        task-list start-time end-time)
    (dolist (line lines)
      (let ((timestamp (plist-get line :timestamp))
            (type (plist-get line :type)))
        (when timestamp
          (unless start-time (setq start-time timestamp))
          (setq end-time timestamp))
        (when-let ((cwd (plist-get line :cwd)))
          (cl-pushnew cwd cwds :test #'equal))
        (when-let ((branch (plist-get line :gitBranch)))
          (cl-pushnew branch branches :test #'equal))
        (cond
         ((equal type "assistant")
          (let* ((message (plist-get line :message))
                 (model (plist-get message :model))
                 (usage (plist-get message :usage)))
            (when (and model (not (equal model "<synthetic>")))
              (cl-pushnew model models :test #'equal)
              (when usage
                (let ((normalized (claude-session-log--usage-plist-from-json usage))
                      (existing (or (gethash model usage-table)
                                    (claude-session-log--zero-usage))))
                  (puthash model (claude-session-log--merge-usage existing normalized)
                           usage-table))))
            (dolist (path (claude-session-log--file-touches-in-content
                           (plist-get message :content)))
              (cl-pushnew path files-touched :test #'equal))
            (push (list :timestamp timestamp :type type
                        :role (plist-get message :role) :model model
                        :is-meta (plist-get line :isMeta)
                        :prompt-source (plist-get line :promptSource))
                  events)))
         ((equal type "user")
          (let ((message (plist-get line :message)))
            (push (list :timestamp timestamp :type type
                        :role (plist-get message :role) :model nil
                        :is-meta (plist-get line :isMeta)
                        :prompt-source (plist-get line :promptSource))
                  events)))
         ((equal type "attachment")
          (let ((attachment (plist-get line :attachment)))
            (when (equal (plist-get attachment :type) "task_reminder")
              (setq task-list attachment)))))))
    (make-claude-session-log-session
     :session-id session-id
     :source-path source-path
     :start-time start-time
     :end-time end-time
     :duration-seconds (claude-session-log--seconds-between start-time end-time)
     :models (nreverse models)
     :usage-by-model (let (alist)
                        (maphash (lambda (k v) (push (cons k v) alist)) usage-table)
                        alist)
     :files-touched (nreverse files-touched)
     :cwds (nreverse cwds)
     :branches (nreverse branches)
     :task-list task-list
     :events (nreverse events))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 21 tests, 21 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-log.el tests/claude-session-log-test.el
git commit -m "Add claude-session-log line-folding into a session struct"
```

---

### Task 5: Subagent discovery and parsing

**Files:**
- Modify: `claude-session-log.el`
- Test: `tests/claude-session-log-test.el`

**Interfaces:**
- Consumes: `claude-session-log--read-jsonl-lines` (Task 2),
  `claude-session-log--parse-lines` (Task 4),
  `claude-session-log-subagent` struct (Task 1).
- Produces: `claude-session-log--read-json-file (path)` -> parsed plist
  of a single JSON object file; `claude-session-log--find-subagent-meta-files
  (source-path)` -> list of `.meta.json` full paths, or nil if no
  `subagents/` directory exists; `claude-session-log--parse-subagent
  (meta-path)` -> `claude-session-log-subagent` struct with
  `usage-by-model` filled in (from its own sibling `.jsonl`), `total-cost`
  left nil.

- [ ] **Step 1: Write the failing tests**

Append to `tests/claude-session-log-test.el`:

```elisp
(defun claude-session-log-test--write-jsonl (path lines)
  "Write LINES (a list of JSON strings) to PATH, one per line."
  (with-temp-file path
    (dolist (line lines) (insert line "\n"))))

(ert-deftest claude-session-log-test-find-subagent-meta-files-none ()
  (let* ((dir (make-temp-file "claude-session-log-test" t))
         (source-path (expand-file-name "sess.jsonl" dir)))
    (unwind-protect
        (progn
          (claude-session-log-test--write-jsonl source-path '("{\"type\":\"user\"}"))
          (should (null (claude-session-log--find-subagent-meta-files source-path))))
      (delete-directory dir t))))

(ert-deftest claude-session-log-test-find-and-parse-subagent ()
  (let* ((dir (make-temp-file "claude-session-log-test" t))
         (source-path (expand-file-name "sess.jsonl" dir))
         (subagents-dir (expand-file-name "subagents" (file-name-sans-extension source-path)))
         (meta-path (expand-file-name "agent-1.meta.json" subagents-dir))
         (agent-jsonl-path (expand-file-name "agent-1.jsonl" subagents-dir)))
    (unwind-protect
        (progn
          (make-directory subagents-dir t)
          (claude-session-log-test--write-jsonl source-path '("{\"type\":\"user\"}"))
          (with-temp-file meta-path
            (insert "{\"agentType\":\"general-purpose\",\"description\":\"Review Task 1\","
                    "\"toolUseId\":\"toolu_01ABC\",\"spawnDepth\":1,\"model\":\"sonnet\"}"))
          (claude-session-log-test--write-jsonl
           agent-jsonl-path
           (list (concat "{\"type\":\"assistant\",\"timestamp\":\"2026-07-21T10:00:00.000Z\","
                         "\"message\":{\"role\":\"assistant\",\"model\":\"claude-sonnet-5\","
                         "\"content\":[],\"usage\":{\"input_tokens\":5,\"output_tokens\":2}}}")))
          (let ((found (claude-session-log--find-subagent-meta-files source-path)))
            (should (equal found (list meta-path))))
          (let ((sub (claude-session-log--parse-subagent meta-path)))
            (should (equal (claude-session-log-subagent-agent-type sub) "general-purpose"))
            (should (equal (claude-session-log-subagent-description sub) "Review Task 1"))
            (should (equal (claude-session-log-subagent-tool-use-id sub) "toolu_01ABC"))
            (should (equal (claude-session-log-subagent-spawn-depth sub) 1))
            (should (equal (claude-session-log-subagent-model sub) "sonnet"))
            (should (equal (cdr (assoc "claude-sonnet-5"
                                       (claude-session-log-subagent-usage-by-model sub)))
                           '(:input 5 :output 2 :cache-write-5m 0 :cache-write-1h 0 :cache-read 0)))
            (should (null (claude-session-log-subagent-total-cost sub)))))
      (delete-directory dir t))))
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: the 21 earlier tests still pass; the 2 new tests fail with
`void-function claude-session-log--find-subagent-meta-files`.

- [ ] **Step 3: Write the implementation**

Add to `claude-session-log.el` (before `(provide 'claude-session-log)`):

```elisp
(defun claude-session-log--read-json-file (path)
  "Read and parse the single JSON object in PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (json-parse-string (buffer-string)
                        :object-type 'plist :array-type 'list
                        :null-object nil :false-object nil)))

(defun claude-session-log--find-subagent-meta-files (source-path)
  "Return the list of `.meta.json' paths in SOURCE-PATH's sibling
`subagents/' directory (same basename as SOURCE-PATH, minus its
extension), or nil if that directory doesn't exist. This is a flat,
single-level listing -- verified against real session data, subagent
directories are not recursively nested despite subagent metadata
carrying a `spawnDepth' field."
  (let ((dir (expand-file-name "subagents" (file-name-sans-extension source-path))))
    (when (file-directory-p dir)
      (directory-files dir t "\\.meta\\.json\\'"))))

(defun claude-session-log--parse-subagent (meta-path)
  "Parse a subagent's META-PATH (\"agent-X.meta.json\") and its sibling
\"agent-X.jsonl\" into a `claude-session-log-subagent' struct.
`total-cost' is left nil -- see `claude-session-log--apply-costs'."
  (let* ((meta (claude-session-log--read-json-file meta-path))
         ;; Strip both ".json" and ".meta" to get "agent-X", then add
         ;; ".jsonl" -- matches this dir's real naming convention.
         (jsonl-path (concat (file-name-sans-extension
                               (file-name-sans-extension meta-path))
                              ".jsonl"))
         (agent-id (file-name-base jsonl-path))
         (parsed (claude-session-log--parse-lines
                  agent-id jsonl-path
                  (claude-session-log--read-jsonl-lines jsonl-path))))
    (make-claude-session-log-subagent
     :agent-type (plist-get meta :agentType)
     :description (plist-get meta :description)
     :model (plist-get meta :model)
     :spawn-depth (plist-get meta :spawnDepth)
     :tool-use-id (plist-get meta :toolUseId)
     :usage-by-model (claude-session-log-session-usage-by-model parsed))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 23 tests, 23 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-log.el tests/claude-session-log-test.el
git commit -m "Add claude-session-log subagent discovery and parsing"
```

---

### Task 6: Cost computation

**Files:**
- Modify: `claude-session-log.el`
- Test: `tests/claude-session-log-test.el`

**Interfaces:**
- Consumes: `claude-session-log--price-per-million` (Task 1),
  `claude-session-log-session`/`claude-session-log-subagent` structs
  (Task 1, with `usage-by-model` populated by Tasks 4/5).
- Produces: `claude-session-log--cost-for-usage (usage prices)` -> float
  dollars; `claude-session-log--cost-for-usage-by-model (usage-by-model)`
  -> `(cost-by-model . unpriced-models)`; `claude-session-log--apply-costs
  (session)` -> the same SESSION struct, mutated in place, with
  `cost-by-model`, `total-cost` (including every subagent's own cost),
  and `unpriced-models` filled in, and each subagent's `total-cost` filled in.

- [ ] **Step 1: Write the failing tests**

Append to `tests/claude-session-log-test.el`:

```elisp
(ert-deftest claude-session-log-test-cost-for-usage ()
  ;; claude-sonnet-5: $2/$10 per 1M. 1000 input, 1000 output tokens.
  ;; Plus 1000 cache-write-5m (x1.25), 1000 cache-write-1h (x2),
  ;; 1000 cache-read (x0.1), all priced off the $2 input rate.
  (let ((usage '(:input 1000 :output 1000 :cache-write-5m 1000
                 :cache-write-1h 1000 :cache-read 1000))
        (prices '(2.00 . 10.00)))
    (should (= (claude-session-log--cost-for-usage usage prices)
               (+ (* (/ 1000 1000000.0) 2.00)
                  (* (/ 1000 1000000.0) 10.00)
                  (* (/ 1000 1000000.0) 2.00 1.25)
                  (* (/ 1000 1000000.0) 2.00 2.0)
                  (* (/ 1000 1000000.0) 2.00 0.1))))))

(ert-deftest claude-session-log-test-cost-for-usage-by-model-unpriced ()
  (let* ((usage-by-model
          (list (cons "claude-sonnet-5"
                      '(:input 1000000 :output 1000000 :cache-write-5m 0
                        :cache-write-1h 0 :cache-read 0))
                (cons "some-future-model"
                      '(:input 1000000 :output 0 :cache-write-5m 0
                        :cache-write-1h 0 :cache-read 0))))
         (result (claude-session-log--cost-for-usage-by-model usage-by-model))
         (cost-by-model (car result))
         (unpriced (cdr result)))
    (should (= (cdr (assoc "claude-sonnet-5" cost-by-model)) 12.00))
    (should (= (cdr (assoc "some-future-model" cost-by-model)) 0.0))
    (should (equal unpriced '("some-future-model")))))

(ert-deftest claude-session-log-test-apply-costs-folds-subagents ()
  (let* ((session (make-claude-session-log-session
                   :usage-by-model
                   (list (cons "claude-sonnet-5"
                               '(:input 1000000 :output 0 :cache-write-5m 0
                                 :cache-write-1h 0 :cache-read 0)))
                   :subagents
                   (list (make-claude-session-log-subagent
                          :model "claude-haiku-4-5"
                          :usage-by-model
                          (list (cons "claude-haiku-4-5"
                                      '(:input 1000000 :output 0 :cache-write-5m 0
                                        :cache-write-1h 0 :cache-read 0)))))))
         (result (claude-session-log--apply-costs session)))
    (should (eq result session))
    (should (= (cdr (assoc "claude-sonnet-5" (claude-session-log-session-cost-by-model session)))
               2.00))
    (should (= (claude-session-log-subagent-total-cost
                (car (claude-session-log-session-subagents session)))
               1.00))
    ;; total-cost is the session's own cost PLUS the subagent's.
    (should (= (claude-session-log-session-total-cost session) 3.00))
    (should (null (claude-session-log-session-unpriced-models session)))))
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: the 23 earlier tests still pass; the 3 new tests fail with
`void-function claude-session-log--cost-for-usage`.

- [ ] **Step 3: Write the implementation**

Add to `claude-session-log.el` (before `(provide 'claude-session-log)`):

```elisp
(defun claude-session-log--cost-for-usage (usage prices)
  "Return the dollar cost of usage plist USAGE given PRICES = (input-price
. output-price), dollars per 1M tokens."
  (let ((input-price (car prices))
        (output-price (cdr prices)))
    (+ (* (/ (plist-get usage :input) 1000000.0) input-price)
       (* (/ (plist-get usage :output) 1000000.0) output-price)
       (* (/ (plist-get usage :cache-write-5m) 1000000.0) input-price
          claude-session-log-cache-write-5m-multiplier)
       (* (/ (plist-get usage :cache-write-1h) 1000000.0) input-price
          claude-session-log-cache-write-1h-multiplier)
       (* (/ (plist-get usage :cache-read) 1000000.0) input-price
          claude-session-log-cache-read-multiplier))))

(defun claude-session-log--cost-for-usage-by-model (usage-by-model)
  "Return (COST-BY-MODEL . UNPRICED-MODELS) for USAGE-BY-MODEL.
COST-BY-MODEL is an alist of model -> dollars (float). UNPRICED-MODELS
is the list of models present in USAGE-BY-MODEL with no
`claude-session-log-model-prices' entry -- their usage still counts
toward the totals, but contributes $0."
  (let (cost-by-model unpriced)
    (dolist (entry usage-by-model)
      (let* ((model (car entry))
             (usage (cdr entry))
             (prices (claude-session-log--price-per-million model)))
        (if prices
            (push (cons model (claude-session-log--cost-for-usage usage prices))
                  cost-by-model)
          (progn (push model unpriced)
                 (push (cons model 0.0) cost-by-model)))))
    (cons (nreverse cost-by-model) (nreverse unpriced))))

(defun claude-session-log--apply-costs (session)
  "Fill SESSION's `cost-by-model', `total-cost', and `unpriced-models',
folding every subagent's own cost into `total-cost' (this is \"real
cost\": everything the session spent, including what it spawned).
Also fills each subagent's own `total-cost'. Mutates and returns
SESSION."
  (let* ((result (claude-session-log--cost-for-usage-by-model
                  (claude-session-log-session-usage-by-model session)))
         (cost-by-model (car result))
         (unpriced (cdr result))
         (total (apply #'+ (mapcar #'cdr cost-by-model))))
    (dolist (sub (claude-session-log-session-subagents session))
      (let* ((sub-result (claude-session-log--cost-for-usage-by-model
                          (claude-session-log-subagent-usage-by-model sub)))
             (sub-cost-by-model (car sub-result))
             (sub-total (apply #'+ (mapcar #'cdr sub-cost-by-model))))
        (setf (claude-session-log-subagent-total-cost sub) sub-total)
        (setq total (+ total sub-total))
        (setq unpriced (append unpriced (cdr sub-result)))))
    (setf (claude-session-log-session-cost-by-model session) cost-by-model)
    (setf (claude-session-log-session-total-cost session) total)
    (setf (claude-session-log-session-unpriced-models session) (delete-dups unpriced))
    session))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 26 tests, 26 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-log.el tests/claude-session-log-test.el
git commit -m "Add claude-session-log cost computation"
```

---

### Task 7: Top-level entry point and end-to-end integration test

**Files:**
- Modify: `claude-session-log.el`
- Test: `tests/claude-session-log-test.el`

**Interfaces:**
- Consumes: `claude-session-log--read-jsonl-lines` (Task 2),
  `claude-session-log--parse-lines` (Task 4),
  `claude-session-log--find-subagent-meta-files`,
  `claude-session-log--parse-subagent` (Task 5),
  `claude-session-log--apply-costs` (Task 6).
- Produces: `claude-session-log-parse-file (path)` -> a fully-populated
  `claude-session-log-session` struct. This is the module's public
  entry point.

- [ ] **Step 1: Write the failing test**

Append to `tests/claude-session-log-test.el`:

```elisp
(ert-deftest claude-session-log-test-parse-file-end-to-end ()
  (let* ((dir (make-temp-file "claude-session-log-test" t))
         (source-path (expand-file-name "291b7031-test.jsonl" dir))
         (subagents-dir (expand-file-name "subagents" (file-name-sans-extension source-path)))
         (meta-path (expand-file-name "agent-1.meta.json" subagents-dir))
         (agent-jsonl-path (expand-file-name "agent-1.jsonl" subagents-dir)))
    (unwind-protect
        (progn
          (make-directory subagents-dir t)
          (claude-session-log-test--write-jsonl
           source-path
           (list
            (concat "{\"type\":\"user\",\"timestamp\":\"2026-07-21T10:00:00.000Z\","
                    "\"cwd\":\"/home/hoooo/.emacs.d\",\"gitBranch\":\"main\","
                    "\"message\":{\"role\":\"user\",\"content\":\"go\"}}")
            (concat "{\"type\":\"assistant\",\"timestamp\":\"2026-07-21T10:00:05.000Z\","
                    "\"cwd\":\"/home/hoooo/.emacs.d\",\"gitBranch\":\"main\","
                    "\"message\":{\"role\":\"assistant\",\"model\":\"claude-sonnet-5\","
                    "\"content\":[{\"type\":\"tool_use\",\"id\":\"tu1\",\"name\":\"Edit\","
                    "\"input\":{\"file_path\":\"/home/hoooo/.emacs.d/init.el\"}}],"
                    "\"usage\":{\"input_tokens\":1000000,\"output_tokens\":0}}}")
            (concat "{\"type\":\"attachment\",\"timestamp\":\"2026-07-21T10:00:06.000Z\","
                    "\"attachment\":{\"type\":\"task_reminder\",\"itemCount\":1,"
                    "\"content\":[{\"id\":\"1\",\"subject\":\"T1\",\"description\":\"d\","
                    "\"status\":\"pending\",\"blocks\":[],\"blockedBy\":[]}]}}")))
          (with-temp-file meta-path
            (insert "{\"agentType\":\"general-purpose\",\"description\":\"help\","
                    "\"toolUseId\":\"toolu_1\",\"spawnDepth\":1,\"model\":\"haiku\"}"))
          (claude-session-log-test--write-jsonl
           agent-jsonl-path
           (list (concat "{\"type\":\"assistant\",\"timestamp\":\"2026-07-21T10:00:02.000Z\","
                         "\"message\":{\"role\":\"assistant\",\"model\":\"claude-haiku-4-5\","
                         "\"content\":[],\"usage\":{\"input_tokens\":1000000,\"output_tokens\":0}}}")))
          (let ((s (claude-session-log-parse-file source-path)))
            (should (equal (claude-session-log-session-session-id s) "291b7031-test"))
            (should (equal (claude-session-log-session-source-path s) source-path))
            (should (equal (claude-session-log-session-models s) '("claude-sonnet-5")))
            (should (equal (claude-session-log-session-files-touched s)
                           '("/home/hoooo/.emacs.d/init.el")))
            (should (equal (claude-session-log-session-cwds s) '("/home/hoooo/.emacs.d")))
            (should (equal (claude-session-log-session-branches s) '("main")))
            (should (equal (plist-get (car (plist-get
                                             (claude-session-log-session-task-list s)
                                             :content))
                                       :status)
                           "pending"))
            (should (= (length (claude-session-log-session-subagents s)) 1))
            (should (equal (claude-session-log-subagent-agent-type
                            (car (claude-session-log-session-subagents s)))
                           "general-purpose"))
            ;; claude-sonnet-5: $2/1M input * 1M tokens = $2.00 (own cost).
            (should (= (cdr (assoc "claude-sonnet-5" (claude-session-log-session-cost-by-model s)))
                       2.00))
            ;; claude-haiku-4-5: $1/1M input * 1M tokens = $1.00 (subagent).
            (should (= (claude-session-log-subagent-total-cost
                        (car (claude-session-log-session-subagents s)))
                       1.00))
            ;; total-cost includes the subagent: $2.00 + $1.00 = $3.00.
            (should (= (claude-session-log-session-total-cost s) 3.00))
            (should (null (claude-session-log-session-unpriced-models s)))))
      (delete-directory dir t))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: the 26 earlier tests still pass; the new test fails with
`void-function claude-session-log-parse-file`.

- [ ] **Step 3: Write the implementation**

Add to `claude-session-log.el` (before `(provide 'claude-session-log)`):

```elisp
;;;###autoload
(defun claude-session-log-parse-file (path)
  "Parse the Claude Code session JSONL file at PATH into a
`claude-session-log-session' struct, including its subagents (if any,
via a sibling `subagents/' directory) and computed per-model and total
costs. This does one full synchronous parse of PATH -- call it again
to see any lines appended since the last call."
  (let* ((session-id (file-name-base path))
         (session (claude-session-log--parse-lines
                   session-id path (claude-session-log--read-jsonl-lines path)))
         (subagents (mapcar #'claude-session-log--parse-subagent
                             (claude-session-log--find-subagent-meta-files path))))
    (setf (claude-session-log-session-subagents session) subagents)
    (claude-session-log--apply-costs session)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `emacs -Q --batch -L . -l claude-session-log.el -l tests/claude-session-log-test.el -f ert-run-tests-batch-and-exit`

Expected: `Ran 27 tests, 27 results as expected, 0 unexpected`

- [ ] **Step 5: Commit**

```bash
git add claude-session-log.el tests/claude-session-log-test.el
git commit -m "Add claude-session-log-parse-file entry point"
```

---

## Self-review notes

- **Spec coverage:** start/end/duration (Task 4), per-model usage incl.
  cache split/fallback (Tasks 3-4), cost table + cache multipliers + $0
  unpriced fallback (Tasks 1, 6), files-touched flat-list decision
  (Task 3-4, commented in code per the spec's explicit call-out),
  cwds/branches (Task 4), task-list last-wins (Task 4), subagents
  discovered flat and folded into `total-cost` (Tasks 5-6), retained
  `events` skeletons for future bucketing (Task 4), single synchronous
  entry point with no live-watching (Task 7) — every spec section maps
  to a task.
- **Placeholder scan:** no TBD/TODO; every step has complete, runnable
  code and an exact expected-output line.
- **Type consistency:** checked struct slot names and function
  signatures are used identically across all 7 tasks (e.g.
  `usage-by-model` never renamed to `usage`, `cost-by-model` never
  renamed to `costs`, `--parse-lines` signature `(session-id
  source-path lines)` unchanged from Task 4 through Task 7's reuse in
  Task 5's subagent parsing).

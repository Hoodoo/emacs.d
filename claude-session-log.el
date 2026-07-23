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

(provide 'claude-session-log)
;;; claude-session-log.el ends here

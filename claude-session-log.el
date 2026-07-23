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
  total-cost
  models
  files-touched)

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
     :usage-by-model (claude-session-log-session-usage-by-model parsed)
     :models (claude-session-log-session-models parsed)
     :files-touched (claude-session-log-session-files-touched parsed))))

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

;;;###autoload
(defun claude-session-log-parse-file (path)
  "Parse the Claude Code session JSONL file at PATH into a
`claude-session-log-session' struct, including its subagents (if any,
via a sibling `subagents/' directory) and computed per-model and total
costs. This does one full synchronous parse of PATH -- call it again
to see any lines appended since the last call. Subagent `models' and
`files-touched' are merged into the session's own fields, since those
two fields span main + subagents."
  (let* ((session-id (file-name-base path))
         (session (claude-session-log--parse-lines
                   session-id path (claude-session-log--read-jsonl-lines path)))
         (subagents (mapcar #'claude-session-log--parse-subagent
                             (claude-session-log--find-subagent-meta-files path))))
    (setf (claude-session-log-session-subagents session) subagents)
    ;; models/files-touched span "main + subagents" per the design doc --
    ;; merge each subagent's contribution in, deduped, main-session
    ;; entries first (seq-uniq keeps first occurrence).
    (setf (claude-session-log-session-models session)
          (seq-uniq (append (claude-session-log-session-models session)
                             (apply #'append (mapcar #'claude-session-log-subagent-models subagents)))
                     #'equal))
    (setf (claude-session-log-session-files-touched session)
          (seq-uniq (append (claude-session-log-session-files-touched session)
                             (apply #'append (mapcar #'claude-session-log-subagent-files-touched subagents)))
                     #'equal))
    (claude-session-log--apply-costs session)))

(provide 'claude-session-log)
;;; claude-session-log.el ends here

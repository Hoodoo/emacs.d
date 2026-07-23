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

(provide 'claude-session-log-test)
;;; claude-session-log-test.el ends here

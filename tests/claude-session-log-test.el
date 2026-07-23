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

(provide 'claude-session-log-test)
;;; claude-session-log-test.el ends here

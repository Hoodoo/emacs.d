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

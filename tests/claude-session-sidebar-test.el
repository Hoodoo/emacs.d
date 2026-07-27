;;; claude-session-sidebar-test.el --- Tests for claude-session-sidebar -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(ert-deftest claude-session-sidebar-test-find-agent-shell-buffer-in-side-window ()
  "Regression test: this repo's own config (auto-side-windows-bottom-
buffer-modes in init.el) routes agent-shell-mode buffers into a side
window -- resolution must not exclude side windows, or an agent-shell
buffer can never be found at all. Discovered via live testing in a
real Emacs session, not caught by batch tests until this regression
test was added."
  (let ((buf (generate-new-buffer "agent")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer buf (setq major-mode 'agent-shell-mode))
          (let ((side-win (display-buffer-in-side-window
                            buf '((side . bottom) (slot . 0)))))
            (should (eq (claude-session-sidebar--find-agent-shell-buffer) buf))
            (ignore side-win)))
      (kill-buffer buf)
      (delete-other-windows))))

(ert-deftest claude-session-sidebar-test-find-agent-shell-buffer-none ()
  (let ((buf (generate-new-buffer "plain")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer buf)
          (should (null (claude-session-sidebar--find-agent-shell-buffer))))
      (kill-buffer buf)
      (delete-other-windows))))

(ert-deftest claude-session-sidebar-test-find-agent-shell-buffer-ambiguous ()
  (let ((buf-1 (generate-new-buffer "agent-1"))
        (buf-2 (generate-new-buffer "agent-2")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer buf-1 (setq major-mode 'agent-shell-mode))
          (with-current-buffer buf-2 (setq major-mode 'agent-shell-mode))
          (switch-to-buffer buf-1)
          (set-window-buffer (split-window) buf-2)
          (should (null (claude-session-sidebar--find-agent-shell-buffer))))
      (mapc #'kill-buffer (list buf-1 buf-2))
      (delete-other-windows))))

(ert-deftest claude-session-sidebar-test-find-agent-shell-buffer-same-buffer-two-windows ()
  "The same buffer shown in two windows (e.g. after `C-x 2') is still
exactly one candidate, not an ambiguous pair."
  (let ((buf (generate-new-buffer "agent")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer buf (setq major-mode 'agent-shell-mode))
          (switch-to-buffer buf)
          (set-window-buffer (split-window) buf)
          (should (eq (claude-session-sidebar--find-agent-shell-buffer) buf)))
      (kill-buffer buf)
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
                     (lambda () (list :session (list :id "abc-123"))))
                    ((symbol-function 'agent-shell-cwd)
                     (lambda () default-directory)))
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

(ert-deftest claude-session-sidebar-test-encode-cwd-trailing-slash ()
  "Regression test: `agent-shell-cwd' returns directories in Emacs's
`default-directory' convention (always slash-terminated) -- e.g.
\"/home/hoooo/.emacs.d/\", not \"/home/hoooo/.emacs.d\". Encoding must
strip that trailing slash first, or it turns into a spurious trailing
dash that never matches the CLI's own directory name (discovered via
live `emacsclient' introspection: `claude-session-sidebar-toggle' could
never resolve a session in this very repo)."
  (should (equal (claude-session-sidebar--encode-cwd "/home/hoooo/.emacs.d/")
                 "-home-hoooo--emacs-d")))

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
                     (lambda () (list :session (list :id "no-such-session-id-xyz"))))
                    ((symbol-function 'agent-shell-cwd)
                     (lambda () default-directory)))
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
                       (lambda () (list :session (list :id "session-xyz"))))
                      ((symbol-function 'agent-shell-cwd)
                       (lambda () default-directory)))
              (should (equal (claude-session-sidebar--resolve-session-path) jsonl-path)))))
      (kill-buffer buf)
      (delete-other-windows)
      (when (file-exists-p jsonl-path) (delete-file jsonl-path))
      (when (file-directory-p claude-dir) (delete-directory claude-dir))
      (when (file-directory-p project-dir) (delete-directory project-dir t)))))

(ert-deftest claude-session-sidebar-test-resolve-session-path-agent-shell-in-side-window ()
  "End-to-end regression test for the reported bug: an agent-shell
buffer displayed in a side window (as this repo's own init.el config
does for every agent-shell-mode buffer) must still resolve, not be
silently treated as \"no session\"."
  (let* ((buf (generate-new-buffer "agent"))
         (project-dir (make-temp-file "claude-session-sidebar-test" t))
         (claude-dir (expand-file-name
                      (claude-session-sidebar--encode-cwd project-dir)
                      "~/.claude/projects/"))
         (jsonl-path (expand-file-name "session-xyz.jsonl" claude-dir))
         side-win)
    (unwind-protect
        (progn
          (make-directory claude-dir t)
          (with-temp-file jsonl-path (insert "{\"type\":\"user\"}\n"))
          (with-current-buffer buf
            (setq major-mode 'agent-shell-mode)
            (setq default-directory project-dir))
          (delete-other-windows)
          (setq side-win (display-buffer-in-side-window
                          buf '((side . bottom) (slot . 0))))
          (cl-letf (((symbol-function 'agent-shell--state)
                     (lambda () (list :session (list :id "session-xyz"))))
                    ((symbol-function 'agent-shell-cwd)
                     (lambda () default-directory)))
            (should (equal (claude-session-sidebar--resolve-session-path) jsonl-path))))
      (when (window-live-p side-win) (ignore-errors (delete-window side-win)))
      (kill-buffer buf)
      (delete-other-windows)
      (when (file-exists-p jsonl-path) (delete-file jsonl-path))
      (when (file-directory-p claude-dir) (delete-directory claude-dir))
      (when (file-directory-p project-dir) (delete-directory project-dir t)))))

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

(ert-deftest claude-session-sidebar-test-stats-widget-registered-by-default ()
  "Regression test for the whole-branch-review finding: the stats
widget must be registered at load time, not just inside tests that
register it manually via a `let'-bound `claude-session-sidebar--widgets'."
  (should (assq 'stats claude-session-sidebar--widgets))
  (should (eq (plist-get (cdr (assq 'stats claude-session-sidebar--widgets)) :component)
              'claude-session-sidebar-widget-stats)))

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

(provide 'claude-session-sidebar-test)
;;; claude-session-sidebar-test.el ends here

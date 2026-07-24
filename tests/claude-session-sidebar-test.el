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

(provide 'claude-session-sidebar-test)
;;; claude-session-sidebar-test.el ends here

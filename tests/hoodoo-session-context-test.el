;;; hoodoo-session-context-test.el --- Tests for hoodoo-session-context -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(ert-deftest hoodoo/session-test-default-label ()
  (should (equal (hoodoo/session--default-label "/home/hoooo/proj/") "proj"))
  (should (equal (hoodoo/session--default-label "/home/hoooo/proj") "proj"))
  (should (equal (hoodoo/session--default-label "/home/hoooo/") "hoooo")))

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
          ;; is still exactly one session buffer, not an ambiguous pair.
          (switch-to-buffer agent-buf)
          (set-window-buffer (split-window) agent-buf)
          (should (eq (hoodoo/session--current-session-buffer) agent-buf)))
      (kill-buffer agent-buf)
      (delete-other-windows))))

(provide 'hoodoo-session-context-test)
;;; hoodoo-session-context-test.el ends here

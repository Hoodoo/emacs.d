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

(provide 'hoodoo-session-context-test)
;;; hoodoo-session-context-test.el ends here

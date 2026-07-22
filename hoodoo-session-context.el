;;; hoodoo-session-context.el --- Session-scoped context buffers for agent-shell -*- lexical-binding: t; -*-

;;; Commentary:
;; Ties eat/magit/dired buffers to the agent-shell session (buffer) they
;; support, and manages one tab-bar tab per session so switching between
;; concurrent agent-driven tasks restores the right set of windows.
;; See docs/superpowers/specs/2026-07-21-agent-shell-session-context-design.md

;;; Code:

(require 'seq)
(require 'tab-bar)

;; Forward declarations so this file loads standalone (e.g. under test,
;; without the real `agent-shell' package present) and so the dynamic
;; `let' bindings of `agent-shell-cwd-function' added in later tasks
;; actually bind dynamically rather than lexically. A value-less
;; `defvar' only takes effect for forms *after* it in the same file,
;; so these must come before any function that `let'-binds
;; `agent-shell-cwd-function' or relies on `agent-shell-mode-hook'.
;; When the real `agent-shell' / `agent-shell-project' are loaded,
;; their own `defvar'/`defcustom' take over (harmless to declare twice).
(unless (boundp 'agent-shell-mode-hook)
  (defvar agent-shell-mode-hook nil))
(defvar agent-shell-cwd-function)

(defun hoodoo/session--default-label (dir)
  "Compute the default session label for DIR: its basename."
  (file-name-nondirectory (directory-file-name dir)))

(defvar-local hoodoo/session-buffer nil
  "The agent-shell buffer this buffer is attached to, or nil.")

(defun hoodoo/session--tag-buffer (buffer session-buffer)
  "Attach BUFFER to SESSION-BUFFER."
  (with-current-buffer buffer
    (setq-local hoodoo/session-buffer session-buffer)))

(defun hoodoo/session--attached-buffers (session-buffer)
  "Return live buffers attached to SESSION-BUFFER."
  (seq-filter (lambda (buf)
                (eq (buffer-local-value 'hoodoo/session-buffer buf)
                    session-buffer))
              (buffer-list)))

(defun hoodoo/session--current-session-buffer (&optional frame)
  "Return the agent-shell buffer displayed in a window of FRAME, or nil
unless there is exactly one."
  (let ((candidates
         (seq-uniq
          (seq-filter (lambda (buf)
                        (eq (buffer-local-value 'major-mode buf) 'agent-shell-mode))
                      (mapcar #'window-buffer (window-list frame 'no-mini)))
          #'eq)))
    (when (= (length candidates) 1)
      (car candidates))))

(defun hoodoo/session--require-current-session-buffer ()
  "Like `hoodoo/session--current-session-buffer', but signal `user-error'
instead of returning nil."
  (or (hoodoo/session--current-session-buffer)
      (user-error "No agent-shell session in this tab")))

(defun hoodoo/session--default-checked-p (buffer)
  "Whether BUFFER should be pre-checked for killing when its session ends."
  (memq (buffer-local-value 'major-mode buffer) '(eat-mode magit-status-mode)))

(defun hoodoo/session--close-current-tab-safely ()
  "Close the current tab, tolerating tab-bar being off or there being
only one tab left."
  (when (and (bound-and-true-p tab-bar-mode)
             (> (length (tab-bar-tabs)) 1))
    (ignore-errors (tab-bar-close-tab))))

(defun hoodoo/session--on-session-kill ()
  "Buffer-local `kill-buffer-hook' for agent-shell buffers.  Offers to
kill attached context buffers, then closes the session's tab."
  (let ((attached (hoodoo/session--attached-buffers (current-buffer))))
    (when attached
      (let* ((default-buffers (seq-filter #'hoodoo/session--default-checked-p attached))
             (default-names (mapcar #'buffer-name default-buffers))
             (chosen (completing-read-multiple
                      (format "Kill attached buffers (default: %s): "
                              (string-join default-names ", "))
                      (mapcar #'buffer-name attached)
                      nil t nil nil (string-join default-names ","))))
        (dolist (name chosen)
          (when-let ((buf (get-buffer name)))
            (kill-buffer buf))))))
  (hoodoo/session--close-current-tab-safely))

(defvar-local hoodoo/session-label nil
  "The user-chosen label for this agent-shell session, or nil.
Set on agent-shell buffers only; also used as the session's tab name.")

(defvar hoodoo/session--pending-label nil
  "Dynamically bound to a label while starting a new agent-shell session.
Read by `hoodoo/session-mode-hook-fn' once the new buffer's
`agent-shell-mode' has finished initializing.")

(defun hoodoo/session--make-tab (label)
  "Create a new tab-bar tab named LABEL and switch to it."
  (tab-bar-new-tab)
  (tab-bar-rename-tab label))

(defun hoodoo/session-mode-hook-fn ()
  "Added to `agent-shell-mode-hook'.  Tags a newly started session buffer
with the pending label (if any) and installs its cleanup hook."
  (when hoodoo/session--pending-label
    (setq-local hoodoo/session-label hoodoo/session--pending-label)
    (add-hook 'kill-buffer-hook #'hoodoo/session--on-session-kill nil t)))

(defun hoodoo/session--start-in-tab (label start-function)
  "Create a tab named LABEL, switch to it, and call START-FUNCTION
inside it with `hoodoo/session--pending-label' bound to LABEL."
  (hoodoo/session--make-tab label)
  (let ((hoodoo/session--pending-label label))
    (funcall start-function)))

(add-hook 'agent-shell-mode-hook #'hoodoo/session-mode-hook-fn)

(provide 'hoodoo-session-context)
;;; hoodoo-session-context.el ends here

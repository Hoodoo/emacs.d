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

(provide 'hoodoo-session-context)
;;; hoodoo-session-context.el ends here

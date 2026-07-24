;;; claude-session-sidebar.el --- Sidebar for claude-session-log -*- lexical-binding: t; -*-

;;; Commentary:
;; A `vui.el' sidebar showing `claude-session-log' stats for the
;; agent-shell session at point. Ported from `vulpea-ui.el''s window
;; chrome and auto-show/hide/refresh pattern, with `vulpea-ui''s "note"
;; concept replaced by "resolved session JSONL path."
;; See docs/superpowers/specs/2026-07-24-claude-session-sidebar-design.md

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'claude-session-log)

;; Forward declarations so this file loads standalone (e.g. under test,
;; without the real `agent-shell' package present), mirroring the same
;; pattern already used by `hoodoo-session-context.el' in this repo.
(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell-cwd "agent-shell-project")
(unless (boundp 'agent-shell-mode)
  (defvar agent-shell-mode nil))

;; Task 2 will replace this stub with the real sidebar-window lookup.
;; A nil return is indistinguishable from "no sidebar exists yet", which
;; is correct for this task.
(defun claude-session-sidebar--get-sidebar-window (&optional _frame)
  nil)

(defun claude-session-sidebar--get-main-window (&optional frame)
  "Get the most recently used main window in FRAME.
A main window is a live, non-minibuffer window that is neither this
sidebar nor any other side window. Ported from
`vulpea-ui--get-main-window'."
  (let* ((frame (or frame (selected-frame)))
         (sidebar-win (claude-session-sidebar--get-sidebar-window frame))
         (selected (frame-selected-window frame))
         (mainp (lambda (win)
                  (and (not (eq win sidebar-win))
                       (not (window-parameter win 'window-side))
                       (not (window-minibuffer-p win))))))
    (if (and selected (funcall mainp selected))
        selected
      (or (car (sort (seq-filter mainp (window-list frame nil))
                     (lambda (a b)
                       (> (window-use-time a) (window-use-time b)))))
          (frame-first-window frame)))))

(defun claude-session-sidebar--session-info-from-buffer (buffer)
  "Return (SESSION-ID . CWD) for BUFFER, or nil.
Nil when BUFFER isn't `agent-shell-mode'-derived, or when
`agent-shell--state' has no session id (including when it signals --
that signal is swallowed here, never allowed to escape)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-shell-mode)
        (when-let* ((state (ignore-errors (agent-shell--state)))
                    (session-id (map-nested-elt state '(:session :id))))
          (cons session-id (agent-shell-cwd)))))))

(defun claude-session-sidebar--encode-cwd (cwd)
  "Encode CWD the way Claude Code's CLI names its project directories:
every `/' and `.' in the expanded path becomes `-', independently (no
collapsing of resulting repeated dashes)."
  (replace-regexp-in-string "[/.]" "-" (expand-file-name cwd)))

(defun claude-session-sidebar--session-jsonl-path (session-id encoded-cwd)
  "Return the JSONL path for SESSION-ID under Claude's ENCODED-CWD dir."
  (expand-file-name (concat session-id ".jsonl")
                     (expand-file-name encoded-cwd "~/.claude/projects/")))

(defun claude-session-sidebar--resolve-session-path (&optional frame)
  "Return the JSONL path for the session at point in FRAME, or nil.
Nil when the main window's buffer isn't an agent-shell session, or when
the constructed path doesn't exist on disk yet (session not flushed,
or a non-Claude-Code agent-shell backend)."
  (when-let* ((main-win (claude-session-sidebar--get-main-window frame))
              (buf (window-buffer main-win))
              (info (claude-session-sidebar--session-info-from-buffer buf))
              (path (claude-session-sidebar--session-jsonl-path
                     (car info)
                     (claude-session-sidebar--encode-cwd (cdr info)))))
    (when (file-exists-p path)
      path)))

(provide 'claude-session-sidebar)
;;; claude-session-sidebar.el ends here

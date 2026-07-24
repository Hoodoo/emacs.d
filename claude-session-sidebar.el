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
(require 'vui)

(declare-function claude-session-sidebar-close "claude-session-sidebar")
(declare-function claude-session-sidebar-refresh "claude-session-sidebar")

;; Forward declarations so this file loads standalone (e.g. under test,
;; without the real `agent-shell' package present), mirroring the same
;; pattern already used by `hoodoo-session-context.el' in this repo.
(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell-cwd "agent-shell-project")
(unless (boundp 'agent-shell-mode)
  (defvar agent-shell-mode nil))

(defgroup claude-session-sidebar nil
  "Sidebar showing claude-session-log stats for the session at point."
  :group 'convenience)

(defcustom claude-session-sidebar-position 'right
  "Position of the sidebar in the frame.
One of `left', `right', `top', or `bottom'."
  :type '(choice (const :tag "Left" left)
          (const :tag "Right" right)
          (const :tag "Top" top)
          (const :tag "Bottom" bottom))
  :group 'claude-session-sidebar)

(defcustom claude-session-sidebar-size 0.33
  "Size of the sidebar window (width if left/right, height if top/bottom)."
  :type 'number
  :group 'claude-session-sidebar)

(defun claude-session-sidebar--sidebar-buffer-name (&optional frame)
  "Return the sidebar buffer name for FRAME."
  (let ((frame (or frame (selected-frame))))
    (format "*claude-session-sidebar:%s*" (or (frame-parameter frame 'window-id) ""))))

(defun claude-session-sidebar--get-sidebar-buffer (&optional frame)
  "Get the sidebar buffer for FRAME, or nil if it doesn't exist."
  (get-buffer (claude-session-sidebar--sidebar-buffer-name frame)))

(defun claude-session-sidebar--get-sidebar-window (&optional frame)
  "Get the sidebar window for FRAME, or nil if it doesn't exist."
  (let ((buf (claude-session-sidebar--get-sidebar-buffer frame)))
    (when buf (get-buffer-window buf frame))))

(defun claude-session-sidebar--sidebar-visible-p (&optional frame)
  "Return non-nil if the sidebar is visible in FRAME."
  (claude-session-sidebar--get-sidebar-window frame))

(defun claude-session-sidebar--display-buffer-params ()
  "Return `display-buffer' parameters for the sidebar."
  (let ((side claude-session-sidebar-position)
        (size claude-session-sidebar-size))
    `((side . ,side)
      (slot . 0)
      (window-width . ,(if (memq side '(left right)) size nil))
      (window-height . ,(if (memq side '(top bottom)) size nil))
      (window-parameters . ((no-delete-other-windows . t)
                            (dedicated . t)
                            (no-other-window . nil))))))

(defun claude-session-sidebar--ensure-side-slot (slots side)
  "Return SLOTS with SIDE guaranteed at least one available slot.
Ported from `vulpea-ui--ensure-side-slot'."
  (let ((idx (pcase side
               ('left 0) ('top 1) ('right 2) ('bottom 3)
               (_ (error "Invalid side: %S" side))))
        (slots (copy-sequence slots)))
    (let ((cur (nth idx slots)))
      (when (and (numberp cur) (< cur 1))
        (setf (nth idx slots) 1)))
    slots))

(defun claude-session-sidebar--create-sidebar-window (buffer)
  "Create a sidebar window for BUFFER using side window mechanics.
Ported from `vulpea-ui--create-sidebar-window'."
  (let ((window-sides-slots
         (claude-session-sidebar--ensure-side-slot
          window-sides-slots claude-session-sidebar-position)))
    (display-buffer-in-side-window buffer (claude-session-sidebar--display-buffer-params))))

(defun claude-session-sidebar--hide-sidebar-window (&optional frame)
  "Hide the sidebar window in FRAME without killing the buffer.
Only an actual side window is deleted, mirroring
`vulpea-ui--hide-sidebar-window'."
  (let ((win (claude-session-sidebar--get-sidebar-window frame)))
    (when (and (window-live-p win) (window-parameter win 'window-side))
      (delete-window win))))

(defun claude-session-sidebar--show-sidebar-window (&optional frame)
  "Show the sidebar window in FRAME."
  (let ((buf (claude-session-sidebar--get-sidebar-buffer frame)))
    (when (and buf (not (claude-session-sidebar--sidebar-visible-p frame)))
      (claude-session-sidebar--create-sidebar-window buf))))

(defvar claude-session-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'claude-session-sidebar-close)
    (define-key map (kbd "g") #'claude-session-sidebar-refresh)
    map)
  "Keymap for `claude-session-sidebar-mode'.")

(define-derived-mode claude-session-sidebar-mode vui-mode "claude-session-sidebar"
  "Major mode for the claude-session-sidebar buffer.
\\{claude-session-sidebar-mode-map}"
  :group 'claude-session-sidebar
  (setq-local truncate-lines t))

(defvar claude-session-sidebar--widgets nil
  "Alist of (ID :component SYMBOL :order NUMBER).")

(defun claude-session-sidebar-register-widget (id &rest props)
  "Register a sidebar widget under ID.
PROPS is a plist: :component (a `vui-defcomponent' symbol taking a
single :path prop) and :order (a number; lower renders earlier).
Registering under an existing ID replaces its entry."
  (setf (alist-get id claude-session-sidebar--widgets) props))

(defun claude-session-sidebar--ordered-widgets ()
  "Return `claude-session-sidebar--widgets' sorted by :order, ascending."
  (sort (copy-alist claude-session-sidebar--widgets)
        (lambda (a b) (< (or (plist-get (cdr a) :order) 0)
                          (or (plist-get (cdr b) :order) 0)))))

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

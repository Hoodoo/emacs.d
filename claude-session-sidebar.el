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
(require 'vui-components)

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

(defun claude-session-sidebar--aggregate-tokens (session)
  "Return (INPUT . OUTPUT) token totals summed across every model in SESSION."
  (let ((input 0) (output 0))
    (dolist (entry (claude-session-log-session-usage-by-model session))
      (setq input (+ input (plist-get (cdr entry) :input)))
      (setq output (+ output (plist-get (cdr entry) :output))))
    (cons input output)))

(defun claude-session-sidebar--render-stats (session)
  "Render SESSION (a `claude-session-log-session') as a stats vnode."
  (let ((tokens (claude-session-sidebar--aggregate-tokens session)))
    (vui-vstack
     (vui-text (format "Models: %s"
                       (string-join (claude-session-log-session-models session) ", "))
       :face 'bold)
     (vui-text (format "Duration: %.0fs"
                       (or (claude-session-log-session-duration-seconds session) 0)))
     (vui-text (format "Tokens: %d in / %d out" (car tokens) (cdr tokens)))
     (vui-text (format "Total cost: $%.4f"
                       (or (claude-session-log-session-total-cost session) 0.0))))))

(defun claude-session-sidebar--stats-display-data (status path fresh last-ref)
  "Decide which session struct to render and keep LAST-REF in sync.

STATUS is the `vui-use-async' status for PATH. FRESH is the freshly
loaded `claude-session-log-session', meaningful when STATUS is `ready'.
LAST-REF is a ref (see `vui-use-ref') holding (PATH . SESSION) from the
previous successful load. Mirrors `vulpea-ui--mentions-display-data'.

Returns one of:
  (shown . SESSION)  render SESSION -- fresh on `ready', or the cached
                     struct for the same PATH while pending/errored, so
                     the sidebar doesn't blank out on a transient hiccup;
  (error)            render the error state (nothing cached for PATH);
  (loading)          render the loading state (nothing cached for PATH)."
  (pcase status
    ('ready (setcar last-ref (cons path fresh)) (cons 'shown fresh))
    ('error
     (let ((prev (car last-ref)))
       (if (and prev (equal (car prev) path))
           (cons 'shown (cdr prev))
         (cons 'error nil))))
    (_ (let ((prev (car last-ref)))
         (if (and prev (equal (car prev) path))
             (cons 'shown (cdr prev))
           (cons 'loading nil))))))

(defun claude-session-sidebar--file-mtime (path)
  "Return PATH's modification time, or nil if it doesn't exist."
  (file-attribute-modification-time (file-attributes path)))

(vui-defcomponent claude-session-sidebar-widget-stats (path)
  "Stats widget: models, duration, token totals, total cost for PATH."
  :render
  (let* ((last-ref (vui-use-ref nil))
         (mtime (claude-session-sidebar--file-mtime path))
         (result (vui-use-async (list path mtime)
                   (lambda (resolve reject)
                     (condition-case err
                         (funcall resolve (claude-session-log-parse-file path))
                       (error (funcall reject (error-message-string err)))))))
         (status (plist-get result :status))
         (decision (claude-session-sidebar--stats-display-data
                    status path (plist-get result :data) last-ref))
         (state (car decision))
         (session (cdr decision)))
    (pcase state
      ('shown (claude-session-sidebar--render-stats session))
      ('error (vui-muted (format "Unavailable: %s" (plist-get result :error))))
      (_ (vui-muted "Loading…")))))

(vui-defcomponent claude-session-sidebar-root (path)
  "Root sidebar component: no-session message, or every registered
widget in `:order', each passed PATH."
  :render
  (if (null path)
      (vui-muted "No Claude Code session at point.")
    (apply #'vui-vstack
           (mapcar (lambda (entry)
                     (vui-component (plist-get (cdr entry) :component) :path path))
                   (claude-session-sidebar--ordered-widgets)))))

(defvar claude-session-sidebar--instances (make-hash-table :test 'eq)
  "Hash table of frame -> `vui-instance' for the sidebar root component.")

(defvar claude-session-sidebar--rendering nil
  "Non-nil while the sidebar is rendering. Guards against hook re-entry.")

(defvar-local claude-session-sidebar--current-path nil
  "The session path currently rendered in this sidebar buffer.")

(defun claude-session-sidebar--render-sidebar (path &optional frame)
  "Render PATH into FRAME's sidebar, reusing its `vui-instance' if live.
Ported from `vulpea-ui--render-sidebar': selects the sidebar window
before mounting (since `vui-mount' ends with `switch-to-buffer'), then
restores the originally-selected window."
  (let* ((claude-session-sidebar--rendering t)
         (frame (or frame (selected-frame)))
         (sidebar-win (claude-session-sidebar--get-sidebar-window frame)))
    (when (window-live-p sidebar-win)
      (let* ((buf-name (claude-session-sidebar--sidebar-buffer-name frame))
             (buf (get-buffer-create buf-name))
             (original-window (selected-window))
             (existing-instance (gethash frame claude-session-sidebar--instances)))
        (select-window sidebar-win t)
        (with-current-buffer buf
          (if (and existing-instance
                   (vui-instance-buffer existing-instance)
                   (buffer-live-p (vui-instance-buffer existing-instance)))
              (vui-update-props existing-instance (list :path path))
            (let ((new-instance
                   (vui-mount
                    (vui-component 'claude-session-sidebar-root :path path)
                    buf-name)))
              (puthash frame new-instance claude-session-sidebar--instances)))
          (setq claude-session-sidebar--current-path path)
          (goto-char (point-min)))
        (when (window-live-p original-window)
          (select-window original-window t))))))

(defcustom claude-session-sidebar-auto-hide t
  "When non-nil, automatically hide the sidebar when there's no session at point."
  :type 'boolean
  :group 'claude-session-sidebar)

(defcustom claude-session-sidebar-auto-refresh-delay 1.5
  "Idle seconds before auto-refreshing the sidebar."
  :type 'number
  :group 'claude-session-sidebar)

(defvar claude-session-sidebar--auto-hidden (make-hash-table :test 'eq)
  "Hash table tracking frames where the sidebar was auto-hidden.")

(defun claude-session-sidebar--on-buffer-change (&optional _frame)
  "Auto-show/hide the sidebar and re-render on session change.
Ported from `vulpea-ui--on-buffer-change', with `vulpea-ui''s \"note\"
replaced by \"resolved session path\", compared with `equal' rather
than a note-id lookup."
  (unless (or (minibufferp) claude-session-sidebar--rendering)
    (let* ((frame (selected-frame))
           (sidebar-buf (claude-session-sidebar--get-sidebar-buffer frame))
           (auto-hidden-p (gethash frame claude-session-sidebar--auto-hidden)))
      (when sidebar-buf
        (let* ((path (claude-session-sidebar--resolve-session-path frame))
               (had-path (buffer-local-value 'claude-session-sidebar--current-path sidebar-buf))
               (visible (claude-session-sidebar--sidebar-visible-p frame))
               (same-path (and path had-path (equal path had-path))))
          (cond
           ((and (null path) had-path claude-session-sidebar-auto-hide visible)
            (claude-session-sidebar--hide-sidebar-window frame)
            (puthash frame t claude-session-sidebar--auto-hidden))
           ((and path auto-hidden-p)
            (remhash frame claude-session-sidebar--auto-hidden)
            (claude-session-sidebar--show-sidebar-window frame)
            (unless same-path (claude-session-sidebar--render-sidebar path frame)))
           ((and path visible (not same-path))
            (claude-session-sidebar--render-sidebar path frame))))))))

(defvar claude-session-sidebar--idle-timer nil
  "Timer for auto-refreshing the sidebar on idle.")

(defun claude-session-sidebar--on-idle ()
  "Soft-refresh the visible sidebar on idle: re-render without
invalidating widget memos (`vui-use-async' handles its own
mtime-keyed staleness check internally)."
  (when (claude-session-sidebar--sidebar-visible-p)
    (claude-session-sidebar--render-sidebar
     (claude-session-sidebar--resolve-session-path))))

(defun claude-session-sidebar--start-idle-timer ()
  "Start the idle timer for auto-refresh."
  (claude-session-sidebar--stop-idle-timer)
  (setq claude-session-sidebar--idle-timer
        (run-with-idle-timer claude-session-sidebar-auto-refresh-delay t
                             #'claude-session-sidebar--on-idle)))

(defun claude-session-sidebar--stop-idle-timer ()
  "Stop the idle timer for auto-refresh."
  (when claude-session-sidebar--idle-timer
    (cancel-timer claude-session-sidebar--idle-timer)
    (setq claude-session-sidebar--idle-timer nil)))

(defun claude-session-sidebar--setup-hooks ()
  "Set up hooks and the idle timer for sidebar auto-show/hide/refresh."
  (add-hook 'window-buffer-change-functions #'claude-session-sidebar--on-buffer-change)
  (add-hook 'window-selection-change-functions #'claude-session-sidebar--on-buffer-change)
  (claude-session-sidebar--start-idle-timer))

(defun claude-session-sidebar--teardown-hooks ()
  "Remove hooks and stop the idle timer."
  (remove-hook 'window-buffer-change-functions #'claude-session-sidebar--on-buffer-change)
  (remove-hook 'window-selection-change-functions #'claude-session-sidebar--on-buffer-change)
  (claude-session-sidebar--stop-idle-timer))

;;;###autoload
(defun claude-session-sidebar-open ()
  "Open or show the claude-session-sidebar in the current frame."
  (interactive)
  (let* ((frame (selected-frame))
         (buf-name (claude-session-sidebar--sidebar-buffer-name frame))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'claude-session-sidebar-mode)
        (claude-session-sidebar-mode)))
    (unless (claude-session-sidebar--sidebar-visible-p frame)
      (claude-session-sidebar--create-sidebar-window buf))
    (claude-session-sidebar--setup-hooks)
    (claude-session-sidebar--render-sidebar
     (claude-session-sidebar--resolve-session-path frame) frame)))

;;;###autoload
(defun claude-session-sidebar-close ()
  "Close the claude-session-sidebar in the current frame."
  (interactive)
  (let* ((frame (selected-frame))
         (buf (claude-session-sidebar--get-sidebar-buffer frame)))
    (claude-session-sidebar--hide-sidebar-window frame)
    (when buf (kill-buffer buf))
    (remhash frame claude-session-sidebar--instances)
    (remhash frame claude-session-sidebar--auto-hidden)
    (when (zerop (hash-table-count claude-session-sidebar--instances))
      (claude-session-sidebar--teardown-hooks))))

;;;###autoload
(defun claude-session-sidebar-toggle ()
  "Toggle the claude-session-sidebar visibility in the current frame."
  (interactive)
  (if (claude-session-sidebar--sidebar-visible-p)
      (claude-session-sidebar-close)
    (claude-session-sidebar-open)))

;;;###autoload
(defun claude-session-sidebar-refresh ()
  "Force refresh the sidebar, invalidating widget memos."
  (interactive)
  (let* ((frame (selected-frame))
         (path (claude-session-sidebar--resolve-session-path frame))
         (instance (gethash frame claude-session-sidebar--instances)))
    (when (and instance (vui-instance-buffer instance)
               (buffer-live-p (vui-instance-buffer instance)))
      (vui-update instance (list :path path)))))

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

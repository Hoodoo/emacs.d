;; This is only needed once, near the top of the file
;;(eval-when-compile
;;  ;; Following line is not needed if use-package.el is in ~/.emacs.d
;;  (require 'use-package))

;; (require 'package)

;; (add-to-list 'package-archives
;;             '("melpa" . "https://melpa.org/packages/") t)

;; (package-initialize)

(setq package-enable-at-startup nil)

;; Home for our own homemade packages (hoodoo-session-context.el,
;; claude-session-log.el, claude-session-sidebar.el, ...) so they're
;; plain `require'-able instead of each needing an explicit file path.
(add-to-list 'load-path user-emacs-directory)

;; Bootstrap straight.el - for certain agent related packages
;; which get developed too fast to land on (m)elpa
;; NB: straight seems to conflict with package

(defvar bootstrap-version)
(let ((bootstrap-file
       (expand-file-name
        "straight/repos/straight.el/bootstrap.el"
        (or (bound-and-true-p straight-base-dir)
            user-emacs-directory)))
      (bootstrap-version 7))
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
        (url-retrieve-synchronously
         "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
         'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

;; Apparently this is for brew installed
;; binaries to work?
(use-package exec-path-from-shell
  :straight t)

(use-package org
  :straight t
  :config
  (setq org-directory (expand-file-name "~/Org")
        org-agenda-files (list org-directory)))

;; Journaling and KB using Vulpea
;; https://github.com/d12frosted/vulpea
;; External dependencies:
;; - elpa-emacsql (through apt)
;; - fd-find (through apt)
;; - fswatch (through apt)
(use-package vulpea
  :straight t
  :config
  ;; Build database (first time only)
  (vulpea-db-sync-full-scan)
  ;; Enable auto-sync
  (vulpea-db-autosync-mode +1)
  ;; Parse and write in a background process: saving a note - even a
  ;; 100MB one - blocks Emacs for about a millisecond.
  (setq vulpea-db-async-extraction 'full))

(use-package vulpea-ui
  :straight t
  :ensure t)

(use-package vulpea-journal
  :straight t
  :config
  (global-set-key (kbd "C-c j") #'vulpea-journal))

;; Magit

(use-package magit
    :straight t)

;; Terminal (through eat)

(use-package eat
  :straight t
  ;; Helper functions for ssh and tramp
  :config
  (defun hoodoo/completing-read-known-hosts ()
    "Use .ssh/known_hosts to generate a list for completing-read."
    (completing-read
     "Connect to a host: "
     (--map (car (s-split "," (car (s-split " " it))))
	    (s-split "\n" (f-read "~/.ssh/known_hosts") t))
     nil nil ""))

  (defun hoodoo/eat-ssh-to-host (ssh-hostname ssh-buffername)
    "Run an ssh session to a remote machine in a dedicated eat buffer"
    (eat-other-window)
    (with-current-buffer "*eat*"
      (rename-buffer ssh-buffername)
      (eat-term-send-string eat-terminal (concat "ssh " ssh-hostname "\n"))
      (switch-to-buffer ssh-buffername)))

  (defun hoodoo/eat-ssh-wrapper ()
    "Open a terminal emulator and log in to a remote"
    (interactive)
    ;;(let (ssh-hostname ssh-buffername)
    (setq ssh-hostname (hoodoo/completing-read-known-hosts))
    (setq ssh-buffername (concat "ssh-" ssh-hostname))
    (if (get-buffer ssh-buffername)
	(switch-to-buffer ssh-buffername)
      (hoodoo/eat-ssh-to-host ssh-hostname ssh-buffername)))

  (defun hoodoo/make-tramp-path ()
    "Being in an eat window, build a path in tramp compatible format and visit current directory."
    (interactive)
    (eat-line-mode)
    (eat-term-send-string eat-terminal "L=`logname`; U=`whoami`; H=`hostname -f`; if [[ ${U} == ${L} ]]; then echo \"/ssh:${L}@${H}:${PWD}\"; else echo \"/ssh:${L}@${H}|sudo::/${PWD}\"; fi\n"))

  (defun hoodoo/eat-cd-tramp ()
    "Send command to print TRAMP path, grab it from EAT buffer, and open it."
    (interactive)
    (let ((command
           "L=`logname`; U=`whoami`; H=`hostname -f`; if [[ ${U} == ${L} ]]; then echo \"/ssh:${L}@${H}:${PWD}\"; else echo \"/ssh:${L}@${H}|sudo::/${PWD}\"; fi\n"))
      ;; Send the shell command
      (eat-term-send-string eat-terminal command)
      ;; Wait a moment for output
      (run-at-time
       "0.2 sec" nil
       (lambda ()
	 (let ((path (with-current-buffer (current-buffer)
                       (save-excursion
			 (goto-char (point-max))
			 (forward-line -1)
			 (buffer-substring-no-properties
                          (line-beginning-position)
                          (line-end-position))))))
           (when (string-match-p "^/ssh:" path)
             (message "Opening: %s" path)
             (dired path)))))))
  (defun hoodoo/eat-full-exit-and-close ()
    "Send multiple 'exit' commands, catch terminal shutdown, and close the buffer cleanly."
    (interactive)
    (when (eq major-mode 'eat-mode)
      ;; Switch to semi-char if needed
      (when (bound-and-true-p eat-emacs-mode)
	(eat-semi-char-mode 1))

      ;; Try to send a few 'exit' commands, stop if terminal dies
      (let ((exit-count 3)
            (done nil))
	(while (and (not done) (> exit-count 0))
          (setq exit-count (1- exit-count))
          (condition-case err
              (progn
		(eat-term-send-string eat-terminal "exit\n")
		(sleep-for 0.1))
            (error
             (when (string-match "not a live Eat terminal" (error-message-string err))
               ;; We've exited all shell layers
               (setq done t))))))
      
      ;; Wait a bit just in case
      (sleep-for 0.2)

      ;; Kill the buffer
      (when (buffer-live-p (current-buffer))
	(kill-buffer (current-buffer))))))

;; Agent-shell
;; For Claude, requires npm install -g @agentclientprotocol/claude-agent-acp
;; For Codex, requires npm install -g @agentclientprotocol/codex-acp

(use-package agent-shell
  :straight t
  :commands (agent-shell
             agent-shell-resume-session
             agent-shell-fork
             agent-shell-anthropic-start-claude-code
	     agent-shell-openai-start-codex)
  :custom
  (agent-shell-session-strategy 'prompt)
  (agent-shell-prefer-session-resume t)
  :bind
  (("C-c a c" . hoodoo/claude-start-in)
   ("C-c a d" . hoodoo/claude-start-in)
   ("C-c a l" . agent-shell)
   ("C-c a r" . agent-shell-resume-session)
   ("C-c a f" . agent-shell-fork)
   ("C-c a e" . hoodoo/session-eat)
   ("C-c a m" . hoodoo/session-magit-status)
   ("C-c a j" . hoodoo/session-dired)
   ("C-c a a" . hoodoo/session-attach-buffer)
   ("C-c a s" . claude-session-sidebar-toggle))
  :config
  ;; Ties eat/magit/dired buffers to the agent-shell session (buffer)
  ;; they support, and gives each session its own tab-bar tab.
  ;; See hoodoo-session-context.el and
  ;; docs/superpowers/specs/2026-07-21-agent-shell-session-context-design.md
  (require 'hoodoo-session-context
           (expand-file-name "hoodoo-session-context.el" user-emacs-directory))
  ;; Sidebar showing claude-session-log stats for the session at point.
  ;; See docs/superpowers/specs/2026-07-24-claude-session-sidebar-design.md
  (require 'claude-session-sidebar))

;; Store the transcripts centrally
(use-package agent-shell-org-transcript
  :straight (:host github :repo "lllShamanlll/agent-shell-org-transcript")
  :after agent-shell
  :config
  (setq agent-shell-org-transcript-directory "~/agent-shell-transcripts/"))

(use-package emacs
  :custom
  (scroll-bar-mode nil)
  (tool-bar-mode nil)
  ;; I think it's OK on Mac...
  (menu-bar-mode nil)
  :config
  (setq backup-directory-alist
        `(("." . ,(concat user-emacs-directory "backups"))))
  (setq frame-resize-pixelwise t)

  ;; Thank God I was going to go insane because of this
  ;; https://stackoverflow.com/questions/45697790/how-to-enter-special-symbols-with-alt-in-emacs-under-mac-os-x

  ;;(setq ns-alternate-modifier 'meta)
  ;;(setq ns-right-alternate-modifier 'none)

  (setq word-wrap-by-category t)

  (defun hoodoo/open-init ()
    "Open the main Emacs config file at ~/.emacs.d/init.el."
    (interactive)
    (find-file (expand-file-name "init.el" user-emacs-directory)))
  
  (defun hoodoo/bw-unlock-and-store-session ()
    "Prompt for Bitwarden master password, unlock and set BW_SESSION."
    (interactive)
    (let* ((password (read-passwd "Bitwarden master password: "))
           (cmd (format "bw unlock %s --raw" (shell-quote-argument password)))
           (session (string-trim (shell-command-to-string cmd))))
      (setenv "BW_SESSION" session)
      (message "Bitwarden unlocked.")))

  (defun hoodoo/read-secret (secret-link)
    "Fetch a secret from Bitwarden or 1Password using dot-separated field paths.
Examples:
  op://vault/item/field
  bw://github.com/login.password"
    (let* ((parsed (url-generic-parse-url secret-link))
           (scheme (url-type parsed))
           (item-name (url-host parsed))
           (filename (url-filename parsed))
           (field-path-str (string-trim-left filename "/")))
      (pcase scheme
	("op"
	 (unless (executable-find "op")
           (error "op CLI not found in PATH"))
	 (let ((result (shell-command-to-string
			(format "op read %s"
				(shell-quote-argument (concat "op:/" filename))))))
           (string-trim result)))

	("bw"
	 (unless (executable-find "bw")
           (error "Bitwarden CLI (bw) not found in PATH"))
	 (unless (getenv "BW_SESSION")
           (hoodoo/bw-unlock-and-store-session))
	 (when (or (not item-name)
                   (string-empty-p field-path-str))
           (error "bw:// links must be in the form bw://item/field.path"))
	 (let* ((field-path (mapcar #'intern (split-string field-path-str "\\.")))
		(cmd (format "bw get item %s --session %s"
                             (shell-quote-argument item-name)
                             (shell-quote-argument (getenv "BW_SESSION"))))
		(json (json-parse-string (shell-command-to-string cmd)
					 :object-type 'alist :array-type 'list)))
           (let ((value json))
             (dolist (key field-path)
               (setq value
                     (cond
                      ((and (integerp key) (vectorp value)) (aref value key))
                      ((and (integerp key) (listp value)) (nth key value))
                      ((assoc key value) (alist-get key value))
                      (t (error "Field not found: %s" key)))))
             value)))

	(_
	 (error "Unknown secret backend scheme: %s" scheme)))))

  (defun hoodoo/collapse-blank-lines ()
    "Collapse multiple blank lines in the buffer to a single blank line."
    (interactive)
    (save-excursion
      (goto-char (point-min))
      ;; Replace 2 or more blank lines with just one
      (while (re-search-forward "\n\\{3,\\}" nil t)
	(replace-match "\n\n"))))
  (defun hoodoo/org-wrap-region-in-block (block-type)
    "Wrap the selected region in an Org block of type BLOCK-TYPE."
    (interactive
     (list (completing-read "Block type: " '("src" "quote" "example" "verse" "center" "latex" "html" "ascii" "comment" "export"))))
    (unless (use-region-p)
      (error "No region selected"))
    (let ((begin (region-beginning))
          (end (region-end)))
      (save-excursion
	;; Ensure block ends on its own line
	(goto-char end)
	(unless (bolp) (insert "\n"))
	(insert (format "#+end_%s\n" block-type)))))

  :bind
  ("C-c o" . org-open-at-point))

;; QOL: More predictable undo

(use-package undo-fu
  :straight t
  :init
  (setq undo-limit 67108864) ; 64mb.
  (setq undo-strong-limit 100663296) ; 96mb.
  (setq undo-outer-limit 1006632960) ; 960mb.
  :config
  (global-unset-key (kbd "s-z"))
  (global-set-key (kbd "s-z")   'undo-fu-only-undo)
  (global-set-key (kbd "s-S-z") 'undo-fu-only-redo))
;; Is this the correct method to install and configure undo-fu?
(use-package undo-fu-session
  :straight t
  :config
  (undo-fu-session-global-mode)
  (setq undo-fu-session-incompatible-files '("/COMMIT_EDITMSG\\'" "/git-rebase-todo\\'")))

;; QOL: Modern completion stack

(use-package vertico
  :straight t
  :config
  (setq vertico-cycle t)
  (setq vertico-resize nil)
  (vertico-mode 1))

(use-package marginalia
  :straight t
  :config
  (marginalia-mode 1))

(use-package orderless
  :straight t
  :config
  (setq completion-styles '(orderless basic)))

(use-package consult
  :straight t
  :bind
  ("C-x M-:" . consult-complex-command)     ;; orig. repeat-complex-command
  ("C-x b" . consult-buffer)                ;; orig. switch-to-buffer
  ("C-s" . consult-line)                    ;; orig. isearch-forward
  ("C-x 4 b" . consult-buffer-other-window) ;; orig. switch-to-buffer-other-window
  ("C-x 5 b" . consult-buffer-other-frame)  ;; orig. switch-to-buffer-other-frame
  ("C-x t b" . consult-buffer-other-tab)    ;; orig. switch-to-buffer-other-tab
  ("C-x r b" . consult-bookmark)            ;; orig. bookmark-jump
  ("C-x p b" . consult-project-buffer)      ;; orig. project-switch-to-buffer
  ("M-y" . consult-yank-pop)                ;; orig. yank-pop
  ("M-g g" . consult-goto-line)             ;; orig. goto-line
  ("M-g M-g" . consult-goto-line)           ;; orig. goto-line
  )

;; QOL: pickable other-window

(use-package ace-window
  :straight t
  :demand t
  :config
  (setq aw-keys '(?a ?s ?d ?f ?g ?h ?j ?k ?l)
        aw-char-position 'left
        aw-ignore-current nil
        aw-leading-char-style 'char
        aw-scope 'frame
        aw-dispatch-always t)

  :bind (("M-O" . ace-swap-window)
	 ("C-x o" . ace-window))
  :custom
  (display-buffer-base-action '(display-buffer-reuse-window
                                display-buffer-in-previous-window
                                ace-display-buffer)))

;; This is massive, will be testing this behavior to see
;; if I like it, but there's something there

(use-package auto-side-windows
  ;;:load-path "~/.emacs.d/auto-side-windows"
  :straight (auto-side-windows :type git
			       :host github
			       :repo "MArpogaus/auto-side-windows")
  :config
  (defun hoodoo/toggle-side-windows-based-on-frame-size (frame)
    "Collapse or restore left/right side windows based on FRAME's width.
Top and bottom side windows are left alone regardless of frame width;
only the left/right sides (treemacs, help, info, magit diffs, ...) are
auto-collapsed when there isn't enough room."
    (if (>= (frame-width frame) 140)
	;; Wide: restore whatever we collapsed earlier.
	(let ((buffers (frame-parameter frame 'hoodoo-collapsed-side-buffers)))
	  (when buffers
	    (set-frame-parameter frame 'hoodoo-collapsed-side-buffers nil)
	    (dolist (buffer buffers)
	      (when (buffer-live-p buffer)
		(display-buffer buffer)))))
      ;; Narrow: collapse left/right side windows, remembering their buffers.
      (let (buffers)
	(dolist (win (window-list frame 'no-mini))
	  (when (memq (window-parameter win 'window-side) '(left right))
	    (push (window-buffer win) buffers)
	    (delete-window win)))
	(when buffers
	  (set-frame-parameter
	   frame 'hoodoo-collapsed-side-buffers
	   (append buffers (frame-parameter frame 'hoodoo-collapsed-side-buffers)))))))

  (add-hook 'window-size-change-functions #'hoodoo/toggle-side-windows-based-on-frame-size)

  :custom
  (org-src-window-setup 'plain)
  ;; Top side window configurations
  (auto-side-windows-top-buffer-names
   '("^\\*Backtrace\\*$" "^\\*Compile-Log\\*$" "^COMMIT_EDITMSG$"
     "^\\*Org Src.*\\*" "^\\*Agenda Commands\\*$" "^\\*Org Agenda\\*$"
     "^\\*Quick Help\\*$" "^\\*Multiple Choice Help\\*$" "^\\*TeX Help\\*$"
     "^\\*TeX errors\\*$" "^\\*Warnings\\*$" "^\\*diff-hl\\*$"
     "^\\*Process List\\*$"))
  (auto-side-windows-top-buffer-modes
   '(flymake-diagnostics-buffer-mode locate-mode occur-mode grep-mode
                                     xref--xref-buffer-mode))

  ;; Bottom side window configurations
  (auto-side-windows-bottom-buffer-names
   '("^\\*.*eshell.*\\*$" "^\\*.*shell.*\\*$" "^\\*.*term.*\\*$"
     "^\\*.*vterm.*\\*$"))
  (auto-side-windows-bottom-buffer-modes
   '(eshell-mode shell-mode term-mode vterm-mode comint-mode debugger-mode eat-mode agent-shell-mode))

  ;; Right side window configurations
  (auto-side-windows-right-buffer-names
   '("^\\*eldoc.*\\*$" "^\\*info\\*$" "^\\*Metahelp\\*$" "^magit-diff:.*$" "^magit-process:.*$"))
  (auto-side-windows-right-buffer-modes
   '(Info-mode TeX-output-mode pdf-view-mode eldoc-mode help-mode
               helpful-mode shortdoc-mode magit-status-mode magit-log-mode magit-diff-mode
	       magit-process-mode org-node-context-mode))

  (auto-side-windows-left-buffer-modes '(treemacs-mode))
  ;; Example: Custom parameters for top windows (e.g., fit height to buffer)
  ;; (auto-side-windows-top-alist '((window-height . fit-window-to-buffer)))
  ;; (auto-side-windows-top-window-parameters '((mode-line-format . ...))) ;; Adjust mode-line

  ;; Maximum number of side windows on the left, top, right and bottom
  (window-sides-slots '(1 1 1 2)) ; Example: Allow one window per side

  ;; Force left and right side windows to occupy full frame height
  (window-sides-vertical t)

  ;; Make changes to tab-/header- and mode-line-format persistent when toggleling windows visibility
  (window-persistent-parameters
   (append window-persistent-parameters
           '((tab-line-format . t)
             (header-line-format . t)
             (mode-line-format . t))))

  ;; Magit and org compatibility
    
  :bind ;; Example keybindings (adjust prefix as needed)
  (("C-c w t" . auto-side-windows-display-buffer-top)
   ("C-c w b" . auto-side-windows-display-buffer-bottom)
   ("C-c w l" . auto-side-windows-display-buffer-left)
   ("C-c w r" . auto-side-windows-display-buffer-right)
   ("C-c w T" . auto-side-windows-toggle-side-window)) ; Toggle current buffer in/out of side window
  :hook
  (after-init . auto-side-windows-mode))

(use-package ef-themes
  :straight t
  :config
  (setq ef-themes-mixed-fonts t
	ef-themes-variable-pitch-ui t)
  (mapc #'disable-theme custom-enabled-themes)
  (ef-themes-load-theme 'ef-maris-light))

(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages
   '(agent-shell-org-transcript agent-shell eat ef-themes magit vulpea-journal vulpea quelpa-use-package)))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )

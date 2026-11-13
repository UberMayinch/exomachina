;;; exo-modal.el --- Vim-modal editing and the leader tree  -*- lexical-binding: t; -*-

;;; Commentary:
;; evil + evil-collection for vim defaults, which-key for discoverability,
;; and one leader map (SPC in normal/visual/motion, C-c e everywhere).
;; The leader map is also what `exo-scan' walks for BCI/switch input, so
;; every binding added here is reachable from every modality.

;;; Code:

(defvar exo-leader-map (make-sparse-keymap) "The exomachina leader map.")

(defun exo-leader-def (&rest bindings)
  "Bind pairs of KEY DEF in `exo-leader-map'.  KEY is a `keymap-set' string."
  (while bindings
    (keymap-set exo-leader-map (pop bindings) (pop bindings))))

(defun exo-leader-label (key label)
  "Give prefix KEY in the leader map a LABEL (shown by which-key and scan)."
  (let ((def (keymap-lookup exo-leader-map key)))
    (when (and (consp def) (stringp (car def))) (setq def (cdr def)))
    (when (keymapp def)
      (define-key exo-leader-map (key-parse key) (cons label def)))))

(defun exo-modal-default-leader ()
  "Install the default leader tree."
  (exo-leader-def
   "SPC" #'execute-extended-command
   "f f" #'find-file  "f s" #'save-buffer  "f r" #'recentf-open
   "b b" #'switch-to-buffer  "b k" #'kill-current-buffer
   "w w" #'other-window  "w v" #'split-window-right  "w s" #'split-window-below
   "w d" #'delete-window
   "a a" #'exo-agent-chat  "a k" #'exo-agent-ask  "a r" #'exo-agent-rewrite
   "a i" #'exo-inline-mode
   "m r" #'exo-memory-remember  "m i" #'exo-memory-remember-file  "m s" #'exo-memory-recall  "m f" #'exo-memory-forget
   "m c" #'exo-chords-remember
   "i v" #'exo-voice-toggle  "i b" #'exo-input-toggle  "i s" #'exo-scan
   "e e" #'exo-evolve  "e a" #'exo-evolve-ask-agent
   "e s" (lambda () (interactive) (find-file (exo-self-file)))
   "h k" #'describe-key  "h f" #'describe-function  "h v" #'describe-variable
   "q q" #'save-buffers-kill-terminal)
  (dolist (l '(("f" . "file") ("b" . "buffer") ("w" . "window") ("a" . "agent")
               ("m" . "memory") ("i" . "input") ("e" . "evolve") ("h" . "help")
               ("q" . "quit") ("o" . "yours")))
    (unless (keymap-lookup exo-leader-map (car l))
      (keymap-set exo-leader-map (car l) (make-sparse-keymap)))
    (exo-leader-label (car l) (cdr l))))

(defvar evil-want-keybinding)
(defvar evil-want-integration)
(defvar evil-undo-system)
(defvar evil-want-C-u-scroll)
(defvar which-key-idle-delay)
(declare-function evil-mode "evil-core")
(declare-function evil-define-key* "evil-core")
(declare-function evil-collection-init "evil-collection")

(defun exo-modal-setup ()
  "Turn on evil, evil-collection, which-key and the leader."
  (exo-modal-default-leader)
  (keymap-global-set "C-c e" exo-leader-map)
  (setq evil-want-keybinding nil
        evil-want-integration t
        evil-undo-system 'undo-redo
        evil-want-C-u-scroll t)
  (if (not (require 'evil nil t))
      (message "exo: evil not installed; leader is on C-c e")
    (evil-mode 1)
    (when (require 'evil-collection nil t) (evil-collection-init))
    (evil-define-key* '(normal visual motion) 'global (kbd "SPC") exo-leader-map))
  (when (require 'which-key nil t)
    (setq which-key-idle-delay 0.4)
    (which-key-mode 1)))

(provide 'exo-modal)
;;; exo-modal.el ends here

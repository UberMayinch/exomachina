;;; init.el --- exomachina  -*- lexical-binding: t; -*-

;; Run with:  bin/exomachina   (or emacs --init-directory=<repo>/emacs)

;; evil reads these at load time, and installing packages can load it early.
(setq evil-want-keybinding nil
      evil-want-integration t)

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)

(defun exo--ensure-packages (pkgs)
  "Install missing PKGS.  Offline startup still works without them."
  (let ((missing (seq-remove #'package-installed-p pkgs)))
    (when missing
      (condition-case err
          (progn (package-refresh-contents)
                 (mapc #'package-install missing))
        (error (message "exo: could not install %s: %s" missing
                        (error-message-string err)))))))

(exo--ensure-packages
 (append '(evil evil-collection gptel)
         (unless (locate-library "which-key") '(which-key))))

(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

;; Your settings and self layer live outside the repo.
(require 'exo-core)
(setq custom-file (exo-data-file "custom.el"))
(when (file-exists-p custom-file) (load custom-file nil t))

(setq initial-scratch-message
      ";; exomachina
;;
;; SPC          leader (C-c e outside normal state)
;; SPC a a/k/r  agent: chat / ask here / rewrite      TAB accepts ghost text
;; SPC m r/s    memory: remember / recall
;; SPC i v      voice (push to talk)   SPC i s  scan (BCI / switch)
;; SPC e e      evolve: see your habits, adapt the environment
;;
;; External devices: bin/exo-send pen gesture circle

")

(require 'exomachina)
(exomachina-setup)

;;; init.el ends here

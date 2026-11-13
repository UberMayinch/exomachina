;;; exo-evolve.el --- Let the environment grow with you  -*- lexical-binding: t; -*-

;;; Commentary:
;; Your adaptations live in self.el in `exo-data-directory'.  It loads
;; last at startup and is plain elisp you own.
;;
;; `exo-evolve' shows what you actually do (from exo-chords) and offers
;; changes: bind the commands you keep running through M-x, look at the
;; progressions you repeat.  Adopting a suggestion appends one line to
;; self.el and evaluates it.
;;
;; `exo-evolve-ask-agent' hands the same report to the local model and
;; shows its proposed elisp for you to review.  Nothing it writes is
;; evaluated unless you do it.

;;; Code:

(require 'exo-core)
(require 'exo-chords)

(declare-function exo-agent--require "exo-agent")
(declare-function gptel-request "gptel-request")

(defun exo-self-file () (exo-data-file "self.el"))

(defun exo-self-load ()
  "Load your self layer if it exists."
  (let ((f (exo-self-file)))
    (when (file-exists-p f)
      (condition-case err (load f nil t)
        (error (message "exo: error in %s: %s" f (error-message-string err)))))))

(defun exo-self-append (form)
  "Append FORM to self.el and evaluate it."
  (exo-append-line (exo-self-file) (prin1-to-string form))
  (eval form t))

(defun exo-evolve--bind (cmd)
  "Ask for a key under SPC o and bind CMD there in self.el."
  (let ((key (read-key-sequence (format "Bind %s to SPC o … (press a key): " cmd))))
    (exo-self-append `(exo-leader-def ,(concat "o " (key-description key)) #',cmd))
    (message "exo: SPC o %s → %s (saved to self.el)" (key-description key) cmd)))

(defvar exo-leader-map)

(defun exo-evolve ()
  "Show how you work and what could adapt to it."
  (interactive)
  (with-current-buffer (get-buffer-create "*exo-evolve*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (exo-chords-summary 15) "\n\n")
      (insert "Commands you run through M-x (bind them?):\n")
      (let ((mx (cl-remove-if (lambda (c) (and (boundp 'exo-leader-map)
                                                (where-is-internal (car c) exo-leader-map t)))
                              (exo-chords-top 'mx 15))))
        (if (null mx) (insert "  (none yet)\n")
          (dolist (c mx)
            (insert (format "  %-40s %3d×  " (car c) (cdr c)))
            (let ((cmd (car c)))
              (insert-text-button "[bind]" 'action (lambda (_) (exo-evolve--bind cmd))))
            (insert "\n"))))
      (insert "\nYour self layer: ")
      (let ((f (exo-self-file)))
        (insert-text-button f 'action (lambda (_) (find-file f))))
      (insert "\n")
      (special-mode)
      (goto-char (point-min)))
    (pop-to-buffer (current-buffer))))

(defun exo-evolve-ask-agent ()
  "Ask the local model to propose self.el changes from your habits."
  (interactive)
  (require 'exo-agent)
  (exo-agent--require)
  (let ((buf (get-buffer-create "*exo-evolve-proposal*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert ";; Proposed by your local agent.  Review before evaluating anything.\n\n")
      (emacs-lisp-mode))
    (pop-to-buffer buf)
    (gptel-request
        (concat "Here is how I use Emacs (evil mode, leader key SPC, helper "
                "(exo-leader-def \"KEYS\" #'command)):\n\n" (exo-chords-summary 25)
                "\n\nPropose at most 5 small elisp forms for my self.el that would "
                "save me keystrokes. One comment line above each explaining why. "
                "Output only elisp.")
      :buffer buf :position (with-current-buffer buf (point-max-marker)) :stream t
      :system "You tune a user's Emacs config. Output valid, minimal Emacs Lisp only.")))

(provide 'exo-evolve)
;;; exo-evolve.el ends here

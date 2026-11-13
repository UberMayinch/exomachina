;;; exo-chords.el --- See and learn your key chords  -*- lexical-binding: t; -*-

;;; Commentary:
;; `exo-chords-mode' does two things:
;;   1. Shows the chord you just played (and any voice/pen/BCI event) at
;;      the front of the mode line, with how often you've played it.
;;   2. Counts chords and chord progressions (2- and 3-command n-grams)
;;      in chords.eld, so the environment can adapt (see exo-evolve) and
;;      the agent can remember how you work (`exo-chords-remember').
;;
;; Privacy: typed text is never logged.  Keys without a modifier count
;; only when evil was in a command state (normal/visual/motion/operator)
;; as the command started; elsewhere a chord needs C-/M-/s-/H-.  isearch,
;; the minibuffer and self-insert commands are always skipped.

;;; Code:

(require 'exo-core)
(require 'exo-input)

(defgroup exo-chords nil
  "Chord display and learning."
  :group 'exomachina)

(defcustom exo-chords-ignore-commands
  '(self-insert-command org-self-insert-command ignore handle-switch-frame
    keyboard-quit evil-normal-state evil-force-normal-state
    exo-inline-accept exo-inline-accept-word)
  "Commands never counted or displayed."
  :type '(repeat symbol))

(defcustom exo-chords-ignore-regexp "self-insert\\|mouse\\|scroll-bar\\|^exo-chords-"
  "Commands whose names match this are never counted or displayed."
  :type 'regexp)

(defcustom exo-chords-display-seconds 4
  "How long the last chord stays visible in the mode line."
  :type 'number)

(defface exo-chords-key '((t :inherit help-key-binding))
  "Face for the chord keys in the mode line.")

(defface exo-chords-event '((t :inherit font-lock-string-face :weight bold))
  "Face for non-keyboard input events in the mode line.")

(defvar exo-chords--counts (make-hash-table :test 'equal)
  "\"KEYS\\tCOMMAND\" -> count.")
(defvar exo-chords--ngrams (make-hash-table :test 'equal)
  "\"KEYS1 → KEYS2[ → KEYS3]\" -> count.")
(defvar exo-chords--mx (make-hash-table :test 'eq)
  "Command -> times run through M-x.")
(defvar exo-chords--recent nil "Last few chord key descriptions, newest first.")
(defvar exo-chords--last nil "(TIME . DISPLAY-STRING) of the last chord or event.")
(defvar exo-chords--dirty nil)
(defvar exo-chords--save-timer nil)

(defun exo-chords--file () (exo-data-file "chords.eld"))

(defun exo-chords--plain-keys-p (keys)
  "Non-nil if every event in KEYS lacks control/meta/super/hyper modifiers."
  (cl-every (lambda (ev) (null (cl-intersection (event-modifiers ev)
                                                 '(control meta super hyper alt))))
            keys))

(defvar exo-chords--pre-state nil "Evil state when the command started.")

(defun exo-chords--command-state-p (state)
  "Non-nil if evil STATE interprets plain keys as commands."
  (memq state '(normal visual motion operator)))

(defun exo-chords--interesting-p (cmd keys &optional state)
  "Non-nil if running CMD via KEYS, started in evil STATE, should be counted."
  (and cmd (symbolp cmd) (> (length keys) 0)
       (not (minibufferp))
       (not (bound-and-true-p isearch-mode))
       (not (memq cmd exo-chords-ignore-commands))
       (not (string-match-p exo-chords-ignore-regexp (symbol-name cmd)))
       (or (exo-chords--command-state-p state)
           (not (exo-chords--plain-keys-p keys)))))

(defun exo-chords-record (cmd keys &optional via-mx)
  "Count CMD run by KEYS.  VIA-MX non-nil means it came through M-x."
  (let* ((desc (if via-mx "M-x" (key-description keys)))
         (k (concat desc "\t" (symbol-name cmd)))
         (n (cl-incf (gethash k exo-chords--counts 0))))
    (when via-mx (cl-incf (gethash cmd exo-chords--mx 0)))
    (push desc exo-chords--recent)
    (when (nthcdr 3 exo-chords--recent) (setcdr (nthcdr 2 exo-chords--recent) nil))
    (dolist (len '(2 3))
      (when (>= (length exo-chords--recent) len)
        (cl-incf (gethash (mapconcat #'identity (reverse (seq-take exo-chords--recent len)) " → ")
                          exo-chords--ngrams 0))))
    (setq exo-chords--dirty t
          exo-chords--last
          (cons (float-time)
                (concat (propertize (format " %s " desc) 'face 'exo-chords-key)
                        (format " %s" cmd)
                        (if (> n 1) (format " ×%d" n) "")
                        "  ")))))

(defvar exo-chords--via-mx nil "Non-nil while a command started from M-x is running.")

;; Evil operators read their motion with `read-key-sequence', which resets
;; `this-command-keys': "d i w" would be seen as "i w" and "d d" as "d".
;; So we note the keys and the input-event counter when a command starts,
;; and append the few events it read itself.  Never when it used the
;; minibuffer: those events are typed text.
(defvar exo-chords--pre-keys nil "Keys seen when the command started.")
(defvar exo-chords--pre-count 0 "`num-nonmacro-input-events' at command start.")
(defvar exo-chords--used-minibuffer nil "Non-nil if the command opened a minibuffer.")

(defun exo-chords--pre-command ()
  "Note the starting keys, and whether M-x started this command."
  (unless (minibufferp)
    (setq exo-chords--pre-keys (this-command-keys-vector)
          exo-chords--pre-state (and (bound-and-true-p evil-local-mode)
                                     (bound-and-true-p evil-state))
          exo-chords--pre-count num-nonmacro-input-events
          exo-chords--used-minibuffer nil))
  (when (eq this-command 'execute-extended-command)
    (setq exo-chords--via-mx t)))

(defun exo-chords--note-minibuffer ()
  (setq exo-chords--used-minibuffer t))

(defun exo-chords-full-keys (pre post extra recent)
  "Chord from PRE keys, POST keys, EXTRA events read mid-command, RECENT events."
  (cond ((and (<= 1 extra 4) (>= (length recent) extra))
         (vconcat pre (substring recent (- (length recent) extra))))
        ((and (> (length pre) 0)
              (not (and (>= (length post) (length pre))
                        (equal pre (substring post 0 (length pre))))))
         (vconcat pre post))
        (t post)))

(defun exo-chords--post-command ()
  "Record the command that just ran."
  (unless (minibufferp)
    (let* ((cmd this-command) (mx exo-chords--via-mx)
           (extra (if exo-chords--used-minibuffer 0
                    (- num-nonmacro-input-events exo-chords--pre-count)))
           (keys (exo-chords-full-keys exo-chords--pre-keys (this-command-keys-vector)
                                       extra (if (> extra 0) (recent-keys) []))))
      (setq exo-chords--via-mx nil)
      (when mx (setq keys (kbd "M-x")))
      (when (exo-chords--interesting-p cmd keys exo-chords--pre-state)
        (exo-chords-record cmd keys mx)))))

(defun exo-chords--observe-event (event)
  "Show a non-keyboard input EVENT in the mode line."
  (setq exo-chords--last
        (cons (float-time)
              (concat (propertize (format " %s " (plist-get event :modality))
                                  'face 'exo-chords-event)
                      (format " %s: %s  " (plist-get event :kind)
                              (truncate-string-to-width
                               (format "%s" (plist-get event :value)) 40 nil nil "…")))))
  (force-mode-line-update t))

(defun exo-chords-mode-line ()
  "Mode line string for the last chord, while it is fresh."
  (when (and exo-chords--last
             (< (- (float-time) (car exo-chords--last)) exo-chords-display-seconds))
    (cdr exo-chords--last)))

(defvar exo-chords--mode-line-entry '(:eval (exo-chords-mode-line)))

;;;; Persistence

(defun exo-chords--hash->alist (h)
  (let (out) (maphash (lambda (k v) (push (cons k v) out)) h) out))

(defun exo-chords--alist->hash (alist test)
  (let ((h (make-hash-table :test test)))
    (dolist (c alist h) (puthash (car c) (cdr c) h))))

(defun exo-chords-save ()
  "Write chord stats to disk if they changed."
  (when exo-chords--dirty
    (exo-write-file (exo-chords--file)
                    (prin1-to-string
                     (list :counts (exo-chords--hash->alist exo-chords--counts)
                           :ngrams (exo-chords--hash->alist exo-chords--ngrams)
                           :mx (exo-chords--hash->alist exo-chords--mx))))
    (setq exo-chords--dirty nil)))

(defun exo-chords-load ()
  "Read chord stats from disk."
  (let ((f (exo-chords--file)))
    (when (file-exists-p f)
      (let ((data (with-temp-buffer (insert-file-contents f) (read (current-buffer)))))
        (setq exo-chords--counts (exo-chords--alist->hash (plist-get data :counts) 'equal)
              exo-chords--ngrams (exo-chords--alist->hash (plist-get data :ngrams) 'equal)
              exo-chords--mx (exo-chords--alist->hash (plist-get data :mx) 'eq))))))

(defun exo-chords-top (table n)
  "Top N (KEY . COUNT) pairs of TABLE (`counts', `ngrams' or `mx')."
  (seq-take (sort (exo-chords--hash->alist
                   (pcase table ('counts exo-chords--counts) ('ngrams exo-chords--ngrams)
                          ('mx exo-chords--mx)))
                  (lambda (a b) (> (cdr a) (cdr b))))
            n))

(declare-function exo-memory-add "exo-memory")

(defun exo-chords-summary (&optional n)
  "Plain-text summary of your top N chords and progressions."
  (let ((n (or n 15)))
    (concat "Most played chords:\n"
            (mapconcat (lambda (c) (format "  %s  (%d×)" (string-replace "\t" " → " (car c)) (cdr c)))
                       (exo-chords-top 'counts n) "\n")
            "\nMost played progressions:\n"
            (mapconcat (lambda (c) (format "  %s  (%d×)" (car c) (cdr c)))
                       (exo-chords-top 'ngrams n) "\n"))))

(defun exo-chords-remember ()
  "Store your current chord habits in memory (replaces the last snapshot)."
  (interactive)
  (require 'exo-memory)
  (exo-memory-add (exo-chords-summary) :kind 'chords :key "chords/summary"
                  :callback (lambda (_) (message "exo: chord habits remembered"))))

;;;; Mode

;;;###autoload
(define-minor-mode exo-chords-mode
  "Show and learn the chords you play."
  :global t
  (if exo-chords-mode
      (progn
        (exo-chords-load)
        (add-hook 'pre-command-hook #'exo-chords--pre-command)
        (add-hook 'minibuffer-setup-hook #'exo-chords--note-minibuffer)
        (add-hook 'post-command-hook #'exo-chords--post-command)
        (add-hook 'exo-input-observe-functions #'exo-chords--observe-event)
        (add-hook 'kill-emacs-hook #'exo-chords-save)
        (setq exo-chords--save-timer (run-with-idle-timer 120 t #'exo-chords-save))
        (unless (member exo-chords--mode-line-entry (default-value 'mode-line-format))
          (setq-default mode-line-format
                        (cons exo-chords--mode-line-entry (default-value 'mode-line-format)))))
    (exo-chords-save)
    (remove-hook 'pre-command-hook #'exo-chords--pre-command)
    (remove-hook 'minibuffer-setup-hook #'exo-chords--note-minibuffer)
    (remove-hook 'post-command-hook #'exo-chords--post-command)
    (remove-hook 'exo-input-observe-functions #'exo-chords--observe-event)
    (remove-hook 'kill-emacs-hook #'exo-chords-save)
    (when exo-chords--save-timer (cancel-timer exo-chords--save-timer))
    (setq-default mode-line-format (delete exo-chords--mode-line-entry
                                           (default-value 'mode-line-format)))))

(provide 'exo-chords)
;;; exo-chords.el ends here

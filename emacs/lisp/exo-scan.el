;;; exo-scan.el --- Drive the whole leader tree with 1-3 signals  -*- lexical-binding: t; -*-

;;; Commentary:
;; Low-bandwidth inputs (a BCI classifier, a single switch, a blink, a
;; pen tap) give a few discrete signals, not a keyboard.  `exo-scan'
;; turns those into full access: it walks a keymap (the leader map by
;; default), highlighting one entry at a time.
;;
;;   gesture "next"   -> move highlight
;;   gesture "select" -> run the entry, or descend into a prefix
;;   gesture "back"   -> go up a level (exit at top)
;;
;; With `exo-scan-interval' set, the highlight advances by itself, so a
;; single "select" signal is enough.  Gestures may come from any modality.

;;; Code:

(require 'exo-input)

(defgroup exo-scan nil
  "Scanning access for low-bandwidth input."
  :group 'exomachina)

(defcustom exo-scan-interval nil
  "Seconds between automatic advances, or nil for manual \"next\"."
  :type '(choice (const nil) number))

(defface exo-scan-current '((t :inherit highlight :weight bold))
  "Face for the highlighted scan entry.")

(defvar exo-scan--stack nil "Keymaps from root to current level.")
(defvar exo-scan--index 0)
(defvar exo-scan--timer nil)

(defun exo-scan-items (map)
  "List of (LABEL . DEF) for bindings in MAP that are commands or prefixes."
  (let (items)
    (map-keymap
     (lambda (ev def)
       (let ((label nil))
         (when (and (consp def) (stringp (car def)))
           (setq label (car def) def (cdr def)))
         (when (or (keymapp def) (commandp def))
           (push (cons (format "%s %s" (key-description (vector ev))
                               (or label (if (keymapp def) "+" def)))
                       def)
                 items))))
     map)
    (sort items (lambda (a b) (string< (car a) (car b))))))

(defun exo-scan--current-items ()
  (exo-scan-items (car exo-scan--stack)))

(defun exo-scan--show ()
  "Display the current level with the highlight."
  (let ((items (exo-scan--current-items)) (i -1))
    (message "scan: %s"
             (mapconcat (lambda (it)
                          (cl-incf i)
                          (if (= i exo-scan--index)
                              (propertize (format "[%s]" (car it)) 'face 'exo-scan-current)
                            (car it)))
                        items "  "))))

(defun exo-scan-next ()
  "Advance the highlight."
  (let ((n (length (exo-scan--current-items))))
    (setq exo-scan--index (if (zerop n) 0 (mod (1+ exo-scan--index) n)))
    (exo-scan--show)))

(defun exo-scan-select ()
  "Run or enter the highlighted entry."
  (let ((def (cdr (nth exo-scan--index (exo-scan--current-items)))))
    (cond ((keymapp def)
           (push (if (symbolp def) (symbol-function def) def) exo-scan--stack)
           (setq exo-scan--index 0)
           (exo-scan--show))
          (def (exo-scan-stop)
               (exo-input-run-action def)))))

(defun exo-scan-back ()
  "Go up one level, or stop at the top."
  (pop exo-scan--stack)
  (setq exo-scan--index 0)
  (if exo-scan--stack (exo-scan--show) (exo-scan-stop)))

(defun exo-scan--handle (event)
  "Consume scan gestures from EVENT while scanning."
  (when (and exo-scan--stack (eq (plist-get event :kind) 'gesture))
    (pcase (format "%s" (plist-get event :value))
      ("next" (exo-scan-next) t)
      ("select" (exo-scan-select) t)
      ("back" (exo-scan-back) t))))

(defvar exo-leader-map)

(defun exo-scan (&optional map)
  "Start scanning MAP (default: the leader map)."
  (interactive)
  (setq exo-scan--stack (list (or map exo-leader-map)) exo-scan--index 0)
  (add-hook 'exo-input-event-functions #'exo-scan--handle)
  (when exo-scan-interval
    (setq exo-scan--timer (run-with-timer exo-scan-interval exo-scan-interval #'exo-scan-next)))
  (exo-scan--show))

(defun exo-scan-stop ()
  "Stop scanning."
  (interactive)
  (setq exo-scan--stack nil)
  (when exo-scan--timer (cancel-timer exo-scan--timer) (setq exo-scan--timer nil))
  (remove-hook 'exo-input-event-functions #'exo-scan--handle))

;; A "scan" gesture from any modality opens the scanner.
(exo-input-bind-gesture 'any "scan" #'exo-scan)

(provide 'exo-scan)
;;; exo-scan.el ends here

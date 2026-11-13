;;; exo-input.el --- Modality-agnostic input model  -*- lexical-binding: t; -*-

;;; Commentary:
;; Every input device is a *source*.  A source turns raw signal (audio,
;; pen strokes, EEG classifier output, foot pedals ...) into *events* and
;; hands them to `exo-input-emit'.  The keyboard stays native Emacs/evil;
;; everything else comes through here.
;;
;; An event is a plist:
;;
;;   (:modality voice :kind text    :value "a minor seventh")
;;   (:modality pen   :kind gesture :value "circle")
;;   (:modality bci   :kind gesture :value "select")
;;   (:modality pedal :kind keys    :value "u")          ; replay vim keys
;;   (:modality any   :kind command :value save-buffer)
;;
;; Kinds:
;;   text     insert at point
;;   keys     run as a keyboard macro (so any modality can speak vim)
;;   command  call an interactive command
;;   gesture  look up (MODALITY . NAME) in `exo-input-gestures'
;;
;; New modality = register a source and emit events.  Nothing else changes.

;;; Code:

(require 'exo-core)

(defvar exo-input-sources nil
  "Alist of NAME -> plist (:start FN :stop FN :doc STRING).")

(defvar exo-input--active nil
  "Names of sources currently started.")

(defvar exo-input-event-functions nil
  "Abnormal hook run with each EVENT before default handling.
A function returning non-nil consumes the event.")

(defvar exo-input-observe-functions nil
  "Functions called with each EVENT after it is handled.
For display and logging; return value ignored.")

(defgroup exo-input nil
  "Modality-agnostic input."
  :group 'exomachina)

(defcustom exo-input-gestures
  '(((any . "undo") . undo)
    ((any . "save") . save-buffer)
    ((any . "escape") . "<escape>"))
  "Alist mapping (MODALITY . GESTURE) to an action.
MODALITY `any' matches every modality.  ACTION is a command symbol,
a key string for `kbd', or a function of no arguments."
  :type '(alist :key-type (cons symbol string) :value-type sexp))

(cl-defun exo-input-register-source (name &key start stop doc)
  "Register input source NAME with START and STOP functions and DOC."
  (setf (alist-get name exo-input-sources) (list :start start :stop stop :doc doc))
  name)

(defun exo-input--read-source (prompt)
  "Read a registered source name with PROMPT."
  (intern (completing-read prompt (mapcar #'car exo-input-sources) nil t)))

(defun exo-input-start (name)
  "Start input source NAME."
  (interactive (list (exo-input--read-source "Start input source: ")))
  (let ((src (alist-get name exo-input-sources)))
    (unless src (user-error "No input source %s" name))
    (when-let* ((f (plist-get src :start))) (funcall f))
    (cl-pushnew name exo-input--active)
    (message "exo: %s on" name)))

(defun exo-input-stop (name)
  "Stop input source NAME."
  (interactive (list (exo-input--read-source "Stop input source: ")))
  (when-let* ((f (plist-get (alist-get name exo-input-sources) :stop))) (funcall f))
  (setq exo-input--active (delq name exo-input--active))
  (message "exo: %s off" name))

(defun exo-input-toggle (name)
  "Toggle input source NAME."
  (interactive (list (exo-input--read-source "Toggle input source: ")))
  (if (memq name exo-input--active) (exo-input-stop name) (exo-input-start name)))

(defun exo-input-bind-gesture (modality gesture action)
  "Bind GESTURE from MODALITY (or `any') to ACTION."
  (setf (alist-get (cons modality gesture) exo-input-gestures nil nil #'equal) action))

(defun exo-input-gesture-action (modality gesture)
  "Return action bound to GESTURE for MODALITY, falling back to `any'."
  (or (alist-get (cons modality gesture) exo-input-gestures nil nil #'equal)
      (alist-get (cons 'any gesture) exo-input-gestures nil nil #'equal)))

(defun exo-input--sym (x)
  "Coerce X to a symbol."
  (if (stringp x) (intern x) x))

(defun exo-input--normalize (event)
  "Return EVENT with symbol :modality/:kind and a :time stamp."
  (let ((e (copy-sequence event)))
    (setq e (plist-put e :modality (exo-input--sym (or (plist-get e :modality) 'unknown))))
    (setq e (plist-put e :kind (exo-input--sym (or (plist-get e :kind) 'text))))
    (unless (plist-get e :time) (setq e (plist-put e :time (float-time))))
    e))

(defun exo-input-run-action (action)
  "Run ACTION: a command symbol, a key string, or a function."
  (cond ((and (symbolp action) (commandp action)) (call-interactively action))
        ((stringp action) (execute-kbd-macro (kbd action)))
        ((functionp action) (funcall action))
        (t (message "exo-input: cannot run %S" action))))

(defcustom exo-input-insert-function #'exo-input-insert-text
  "Function called with a string to insert text from non-keyboard input."
  :type 'function)

(defun exo-input-insert-text (text)
  "Insert TEXT at point, adding a space after a preceding word."
  (if buffer-read-only
      (message "exo-input: buffer is read-only, dropped: %s" text)
    (when (and (> (point) (line-beginning-position))
               (memq (char-syntax (char-before)) '(?w ?_ ?.))
               (not (string-prefix-p " " text)))
      (insert " "))
    (insert text)))

(defun exo-input--default (event)
  "Default handling of EVENT by its :kind."
  (let ((kind (plist-get event :kind))
        (value (plist-get event :value)))
    (pcase kind
      ('text (funcall exo-input-insert-function (format "%s" value)))
      ('keys (exo-input-run-action (format "%s" value)))
      ('command (let ((cmd (exo-input--sym value)))
                  (if (commandp cmd) (exo-input-run-action cmd)
                    (message "exo-input: not a command: %s" value))))
      ('gesture (if-let* ((a (exo-input-gesture-action (plist-get event :modality)
                                                       (format "%s" value))))
                    (exo-input-run-action a)
                  (message "exo-input: unbound gesture %s/%s"
                           (plist-get event :modality) value)))
      (_ (message "exo-input: unknown kind %S" kind)))))

(defun exo-input-emit (event)
  "Dispatch EVENT from any modality into the selected window's buffer.
Returns the normalized event."
  (let ((event (exo-input--normalize event)))
    (with-current-buffer (window-buffer (selected-window))
      (condition-case err
          (unless (run-hook-with-args-until-success 'exo-input-event-functions event)
            (exo-input--default event))
        (error (message "exo-input: %s" (error-message-string err)))))
    (run-hook-with-args 'exo-input-observe-functions event)
    event))

(provide 'exo-input)
;;; exo-input.el ends here

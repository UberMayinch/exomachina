;;; exo-inline.el --- Ghost-text completions from your local model  -*- lexical-binding: t; -*-

;;; Commentary:
;; After you pause typing, asks the local model for a continuation and
;; shows it as dim ghost text at point.  TAB accepts, M-l accepts one word,
;; anything else dismisses.  Requests are async and stale replies are
;; dropped, so typing never blocks.
;;
;; Default backend: Ollama /api/generate with `suffix' (fill-in-the-middle),
;; which needs a FIM-capable model (e.g. a coder model).  For prose models
;; set `exo-inline-use-suffix' to nil.
;;
;; Accepted completions (with up to 300 chars of preceding context) are
;; appended to feedback.jsonl in your data directory: seed data for
;; post-training your own adapter.  Never in buffers matching
;; `exo-inline-private-regexp'.  Turn off with `exo-inline-record-feedback'.

;;; Code:

(require 'exo-core)

(defgroup exo-inline nil
  "Ghost-text completions."
  :group 'exomachina)

(defcustom exo-inline-model "qwen2.5-coder:1.5b"
  "Ollama model for inline completions."
  :type 'string)

(defcustom exo-inline-use-suffix t
  "Send text after point as `suffix' (fill-in-the-middle)."
  :type 'boolean)

(defcustom exo-inline-delay 0.6
  "Idle seconds after an edit before asking for a completion."
  :type 'number)

(defcustom exo-inline-context-chars 2000
  "Characters of text before point sent as context."
  :type 'integer)

(defcustom exo-inline-max-tokens 48
  "Maximum tokens per completion."
  :type 'integer)

(defcustom exo-inline-record-feedback t
  "Log accepted completions with a little context to feedback.jsonl (local only)."
  :type 'boolean)

(defcustom exo-inline-private-regexp
  "\\.env\\|authinfo\\|\\.gpg\\'\\|secret\\|password\\|\\.netrc\\|id_[a-z0-9]+\\'"
  "Buffers whose file name matches get no completions and no feedback log."
  :type 'regexp)

(defface exo-inline-ghost '((t :inherit shadow :slant italic))
  "Face for ghost text.")

(defvar exo-inline-request-function #'exo-inline-ollama-request
  "Function (PREFIX SUFFIX CALLBACK); CALLBACK gets a string or nil.")

(defvar-local exo-inline--overlay nil)
(defvar-local exo-inline--text nil "Completion currently shown.")
(defvar-local exo-inline--visible nil "Non-nil while ghost text is shown.")
(defvar-local exo-inline--tick nil "Modification tick seen by the last command.")
(defvar exo-inline--timer nil)
(defvar exo-inline--seq 0 "Request counter; only the latest reply is shown.")
(defvar exo-inline--down-until 0 "Skip requests until this time after a failure.")

(defvar exo-inline-active-map
  (let ((m (make-sparse-keymap)))
    (keymap-set m "TAB" #'exo-inline-accept)
    (keymap-set m "<tab>" #'exo-inline-accept)
    (keymap-set m "M-l" #'exo-inline-accept-word)
    m)
  "Keys active only while ghost text is visible.")

(defvar exo-inline--emulation-alist `((exo-inline--visible . ,exo-inline-active-map)))

;;;; Backend

(defun exo-inline--clean (s)
  "Trim trailing whitespace from completion S; nil if empty."
  (when (stringp s)
    (let ((s (string-trim-right s)))
      (unless (string-empty-p s) s))))

(defun exo-inline-ollama-request (prefix suffix callback)
  "Ask Ollama to continue PREFIX (before SUFFIX); CALLBACK gets text or nil."
  (exo-http-post-json
   (concat exo-ollama-host "/api/generate")
   `(:model ,exo-inline-model :prompt ,prefix
     ;; An empty suffix makes Ollama drop the FIM template and chat instead.
     ,@(when exo-inline-use-suffix
         (list :suffix (if (string-empty-p suffix) "\n" suffix)))
     :stream :false
     :options (:num_predict ,exo-inline-max-tokens :temperature 0.2 :stop ["\n\n"]))
   (lambda (data err)
     (when err (setq exo-inline--down-until (+ (float-time) 30)))
     (funcall callback (and (not err) (plist-get data :response))))))

;;;; Display

(defun exo-inline--show (text)
  "Show TEXT as ghost text at point."
  (exo-inline--clear)
  (let ((s (propertize text 'face 'exo-inline-ghost)))
    (put-text-property 0 1 'cursor t s)
    (setq exo-inline--overlay (make-overlay (point) (point) nil nil t)
          exo-inline--text text
          exo-inline--visible t)
    (overlay-put exo-inline--overlay 'after-string s)
    (overlay-put exo-inline--overlay 'priority 1000)))

(defun exo-inline--clear ()
  "Remove ghost text without logging."
  (when exo-inline--overlay (delete-overlay exo-inline--overlay))
  (setq exo-inline--overlay nil exo-inline--text nil exo-inline--visible nil))

(defun exo-inline--private-p ()
  "Non-nil if this buffer looks like it holds secrets."
  (let ((f (or buffer-file-name (buffer-name))))
    (string-match-p exo-inline-private-regexp f)))

(defun exo-inline--feedback (accepted text)
  "Log ACCEPTED (t/nil) for completion TEXT with a little context."
  (when (and exo-inline-record-feedback (not (exo-inline--private-p)))
    (exo-append-line
     (exo-data-file "feedback.jsonl")
     (json-serialize
      (list :ts (float-time) :model exo-inline-model :accepted (if accepted t :false)
            :mode (symbol-name major-mode)
            :context (buffer-substring-no-properties (max (point-min) (- (point) 300)) (point))
            :completion text)))))

(defun exo-inline-dismiss ()
  "Dismiss ghost text."
  (interactive)
  (exo-inline--clear))

(defun exo-inline-accept ()
  "Insert the whole ghost completion."
  (interactive)
  (when-let* ((text exo-inline--text))
    (exo-inline--feedback t text)
    (exo-inline--clear)
    (insert text)))

(defun exo-inline-accept-word ()
  "Insert the next word of the ghost completion; keep the rest."
  (interactive)
  (when-let* ((text exo-inline--text))
    (let* ((end (if (string-match "\\W*\\w+" text) (match-end 0) (length text)))
           (word (substring text 0 end))
           (rest (substring text end)))
      (exo-inline--clear)
      (insert word)
      (if (string-empty-p rest) (exo-inline--feedback t text) (exo-inline--show rest)))))

;;;; Triggering

(defun exo-inline--eligible-p ()
  "Non-nil if a completion makes sense here."
  (and (not buffer-read-only) (not (minibufferp)) (not (exo-inline--private-p))
       (or (not (bound-and-true-p evil-local-mode))
           (and (fboundp 'evil-insert-state-p) (evil-insert-state-p)))
       (> (float-time) exo-inline--down-until)))

(defun exo-inline--trigger (buf)
  "Request a completion for point in BUF."
  (when (and (buffer-live-p buf) (eq buf (window-buffer (selected-window))))
    (with-current-buffer buf
      (when (exo-inline--eligible-p)
        (let* ((seq (cl-incf exo-inline--seq))
               (pt (point))
               (tick (buffer-chars-modified-tick))
               (prefix (buffer-substring-no-properties
                        (max (point-min) (- pt exo-inline-context-chars)) pt))
               (suffix (buffer-substring-no-properties
                        pt (min (point-max) (+ pt (/ exo-inline-context-chars 4))))))
          (funcall exo-inline-request-function prefix suffix
                   (lambda (raw)
                     (when-let* ((text (exo-inline--clean raw))
                                 ((= seq exo-inline--seq))
                                 ((buffer-live-p buf)))
                       (with-current-buffer buf
                         (when (and (= (point) pt)
                                    (= tick (buffer-chars-modified-tick)))
                           (exo-inline--show text)))))))))))

(defun exo-inline--post-command ()
  "Dismiss stale ghost text; schedule a request after edits."
  (unless (memq this-command '(exo-inline-accept-word))
    (exo-inline-dismiss))
  (when exo-inline--timer (cancel-timer exo-inline--timer) (setq exo-inline--timer nil))
  (let ((tick (buffer-chars-modified-tick)))
    (when (and (not (eql tick exo-inline--tick)) (exo-inline--eligible-p))
      (setq exo-inline--timer
            (run-with-idle-timer exo-inline-delay nil #'exo-inline--trigger (current-buffer))))
    (setq exo-inline--tick tick)))

;;;###autoload
(define-minor-mode exo-inline-mode
  "Ghost-text completions from your local model."
  :lighter " ⋯"
  (if exo-inline-mode
      (progn
        (add-to-list 'emulation-mode-map-alists 'exo-inline--emulation-alist)
        (setq exo-inline--tick (buffer-chars-modified-tick))
        (add-hook 'post-command-hook #'exo-inline--post-command nil t))
    (remove-hook 'post-command-hook #'exo-inline--post-command t)
    (exo-inline--clear)))

(defun exo-inline--maybe-enable ()
  (when (derived-mode-p 'prog-mode 'text-mode 'conf-mode)
    (exo-inline-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-exo-inline-mode exo-inline-mode exo-inline--maybe-enable)

(provide 'exo-inline)
;;; exo-inline.el ends here

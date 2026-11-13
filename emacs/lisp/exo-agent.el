;;; exo-agent.el --- The agent that works next to you  -*- lexical-binding: t; -*-

;;; Commentary:
;; Three ways to work with the agent, all on your local Ollama model:
;;
;;   `exo-agent-chat'     a gptel chat buffer
;;   `exo-agent-ask'      ask about the region/line; the answer streams in
;;                        right below it, in the buffer you are working in
;;   `exo-agent-rewrite'  gptel's region rewrite (diff/accept/reject)
;;
;; `exo-agent-ask' first recalls the closest memories and hands them to
;; the model as context, so the agent knows what you have taught it.
;; No cloud backend is configured.

;;; Code:

(require 'exo-core)
(require 'exo-memory)

(defgroup exo-agent nil
  "Local agent: chat, ask, rewrite."
  :group 'exomachina)

(defcustom exo-agent-chat-model "qwen3:8b"
  "Ollama model for chat and inline asks."
  :type 'string)

(defcustom exo-agent-system-prompt
  "You are exomachina, a creative partner working inside the user's editor. \
Be brief and concrete. Match the user's medium and vocabulary. \
Use the memories below when they are relevant; ignore them when not."
  "Base system prompt."
  :type 'string)

(defcustom exo-agent-think nil
  "Non-nil lets thinking models (qwen3, deepseek-r1) reason before answering.
Better answers, much slower on small GPUs.  Reasoning is never inserted
into your buffers.  Re-run `exo-agent-setup' after changing."
  :type 'boolean)

(defcustom exo-agent-memory-k 5
  "How many memories to recall into each ask."
  :type 'integer)

(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-default-mode)
(declare-function gptel-make-ollama "gptel-ollama")
(declare-function gptel-request "gptel-request")
(declare-function gptel "gptel")
(declare-function gptel-rewrite "gptel-rewrite")

(defvar exo-agent-backend nil "The gptel backend pointing at local Ollama.")

(defun exo-agent-setup ()
  "Point gptel at local Ollama.  No-op if gptel is not installed."
  (when (require 'gptel nil t)
    (let ((u (url-generic-parse-url exo-ollama-host)))
      (setq exo-agent-backend
            (gptel-make-ollama "exomachina"
              :host (format "%s:%s" (url-host u) (url-port u))
              :protocol (url-type u)
              :stream t
              :request-params (unless exo-agent-think '(:think :json-false))
              :models (list (intern exo-agent-chat-model)))))
    (setq gptel-backend exo-agent-backend
          gptel-model (intern exo-agent-chat-model)
          gptel-default-mode 'org-mode
          gptel-include-reasoning nil)))

(defun exo-agent--require ()
  (unless (and (featurep 'gptel) exo-agent-backend)
    (exo-agent-setup))
  (unless exo-agent-backend (user-error "gptel is not installed")))

(defun exo-agent-system-with-memories (hits)
  "System prompt with memory HITS ((SCORE . ENTRY) ...) appended."
  (if (null hits) exo-agent-system-prompt
    (concat exo-agent-system-prompt "\n\nMemories:\n"
            (mapconcat (lambda (h) (format "- [%s] %s" (plist-get (cdr h) :kind)
                                           (plist-get (cdr h) :text)))
                       hits "\n"))))

(defun exo-agent-chat ()
  "Open a chat with the local agent."
  (interactive)
  (exo-agent--require)
  (call-interactively #'gptel))

(defun exo-agent-rewrite ()
  "Rewrite the region with the local agent."
  (interactive)
  (exo-agent--require)
  (call-interactively #'gptel-rewrite))

(defun exo-agent-ask (question)
  "Ask QUESTION about the region (or current line); answer streams in below."
  (interactive (list (read-string "Ask: ")))
  (exo-agent--require)
  (let* ((beg (if (use-region-p) (region-beginning) (line-beginning-position)))
         (end (if (use-region-p) (region-end) (line-end-position)))
         (context (buffer-substring-no-properties beg end))
         (buf (current-buffer))
         (pos (save-excursion (goto-char end) (end-of-line) (point-marker)))
         (prompt (if (string-blank-p context) question
                   (format "%s\n\n---\n%s" question context))))
    (when (use-region-p) (deactivate-mark))
    (exo-memory-search
     (concat question " " context) exo-agent-memory-k
     (lambda (hits)
       (with-current-buffer buf
         (save-excursion (goto-char pos) (insert "\n\n") (set-marker pos (point)))
         (gptel-request prompt
           :buffer buf :position pos :stream t
           :system (exo-agent-system-with-memories hits)))))))

(provide 'exo-agent)
;;; exo-agent.el ends here

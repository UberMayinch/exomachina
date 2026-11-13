;;; exo-voice.el --- Push-to-talk voice input  -*- lexical-binding: t; -*-

;;; Commentary:
;; `exo-voice-toggle' records from the mic, then transcribes locally and
;; emits the result as an exo-input event.  Audio never leaves the machine
;; and the wav is deleted after transcription.
;;
;; Transcription defaults to bin/exo-transcribe (faster-whisper via uv).
;; Any command printing the transcript works, e.g. whisper.cpp:
;;   (setq exo-voice-transcribe-command
;;         '("whisper-cli" "-m" "~/models/ggml-base.en.bin" "-nt" "-np" "-f" "%f"))
;;
;; Utterances starting with `exo-voice-command-word' are commands:
;;   "computer save"         -> `exo-voice-commands' lookup
;;   "computer delete word"  -> keys "diw"
;;   "computer org agenda"   -> M-x org-agenda (if it is a command)
;; Everything else is dictated text.

;;; Code:

(require 'exo-core)
(require 'exo-input)

(defgroup exo-voice nil
  "Voice input."
  :group 'exomachina)

(defcustom exo-voice-record-command
  '("arecord" "-q" "-f" "S16_LE" "-r" "16000" "-c" "1" "-t" "wav" "%f")
  "Recording command; %f is replaced by the wav path.  Stopped with SIGINT."
  :type '(repeat string))

(defcustom exo-voice-transcribe-command
  (let ((script (expand-file-name "../bin/exo-transcribe"
                                  (file-name-directory (or load-file-name buffer-file-name)))))
    (and (executable-find "uv") (file-executable-p script) (list script "%f")))
  "Speech-to-text command; %f is the wav path.  Prints the transcript.
Default: bin/exo-transcribe (faster-whisper, local) when uv is installed."
  :type '(choice (const nil) (repeat string)))

(defcustom exo-voice-command-word "computer"
  "Leading word that turns an utterance into a command."
  :type 'string)

(defcustom exo-voice-commands
  '(("save" . save-buffer)
    ("undo" . undo)
    ("delete word" . "diw")
    ("delete line" . "dd")
    ("new line" . "o")
    ("escape" . "<escape>")
    ("chat" . exo-agent-chat)
    ("ask" . exo-agent-ask)
    ("remember" . exo-memory-remember)
    ("recall" . exo-memory-recall))
  "Spoken phrase -> action (command symbol or key string)."
  :type '(alist :key-type string :value-type sexp))

(defvar exo-voice--proc nil "Running recorder process.")
(defvar exo-voice--wav nil "Path of the current recording.")

(defun exo-voice--subst (cmd file)
  "Replace %f in CMD with FILE."
  (mapcar (lambda (a) (string-replace "%f" file (exo-voice--expand a))) cmd))

(defun exo-voice--expand (arg)
  "Expand ARG if it starts with ~/."
  (if (string-prefix-p "~/" arg) (expand-file-name arg) arg))

(defun exo-voice--normalize (s)
  "Downcase S, strip punctuation and extra spaces."
  (string-trim (replace-regexp-in-string
                "[[:space:]]+" " "
                (replace-regexp-in-string "[^[:alnum:][:space:]-]" "" (downcase s)))))

(defun exo-voice-utterance->event (transcript)
  "Turn TRANSCRIPT into an exo-input event plist."
  (let* ((norm (exo-voice--normalize transcript))
         (prefix (concat (downcase exo-voice-command-word) " ")))
    (if (not (string-prefix-p prefix norm))
        (list :modality 'voice :kind 'text :value (string-trim transcript))
      (let* ((phrase (substring norm (length prefix)))
             (action (cdr (assoc phrase exo-voice-commands)))
             (cmd (intern-soft (string-replace " " "-" phrase))))
        (cond ((stringp action) (list :modality 'voice :kind 'keys :value action))
              (action (list :modality 'voice :kind 'command :value action))
              ((commandp cmd) (list :modality 'voice :kind 'command :value cmd))
              (t (list :modality 'voice :kind 'text :value (string-trim transcript))))))))

(defun exo-voice-start ()
  "Start recording."
  (when (process-live-p exo-voice--proc) (user-error "Already recording"))
  (setq exo-voice--wav (make-temp-file "exo-voice-" nil ".wav"))
  (setq exo-voice--proc
        (make-process :name "exo-voice-rec" :noquery t
                      :command (exo-voice--subst exo-voice-record-command exo-voice--wav)
                      :sentinel #'exo-voice--recorded))
  (message "exo: ● listening (toggle again to stop)"))

(defun exo-voice-stop ()
  "Stop recording; transcription follows."
  (when (process-live-p exo-voice--proc)
    (interrupt-process exo-voice--proc)))

(defun exo-voice--recorded (proc _event)
  "Sentinel: recording PROC finished, transcribe it."
  (unless (process-live-p proc)
    (setq exo-input--active (delq 'voice exo-input--active))
    (let ((wav exo-voice--wav))
      (if (not exo-voice-transcribe-command)
          (progn (ignore-errors (delete-file wav))
                 (message "exo: set `exo-voice-transcribe-command' (e.g. whisper.cpp) to transcribe"))
        (message "exo: transcribing…")
        (let ((out (generate-new-buffer " *exo-voice-out*")))
          (make-process
           :name "exo-voice-stt" :noquery t :buffer out
           :command (exo-voice--subst exo-voice-transcribe-command wav)
           :stderr (get-buffer-create " *exo-voice-err*")
           :sentinel
           (lambda (p _e)
             (unless (process-live-p p)
               (ignore-errors (delete-file wav))
               (let ((text (string-trim (with-current-buffer out (buffer-string)))))
                 (kill-buffer out)
                 (if (string-empty-p text) (message "exo: heard nothing")
                   (exo-input-emit (exo-voice-utterance->event
                                    (string-join (split-string text "\n" t "[ \t]+") " ")))))))))))))

(defun exo-voice-toggle ()
  "Push-to-talk: start recording, or stop and transcribe."
  (interactive)
  (exo-input-toggle 'voice))

(exo-input-register-source 'voice :start #'exo-voice-start :stop #'exo-voice-stop
                           :doc "Microphone -> local speech-to-text")

(provide 'exo-voice)
;;; exo-voice.el ends here

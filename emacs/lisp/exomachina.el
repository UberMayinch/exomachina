;;; exomachina.el --- An Emacs that grows with you  -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (evil "1.15") (evil-collection "0.0.10") (gptel "0.9.8"))
;; Keywords: convenience, ai, accessibility

;;; Commentary:
;; One package, several layers:
;;
;;   exo-input   modality-agnostic input: every device is a source of events
;;   exo-voice   push-to-talk, local speech-to-text
;;   exo-bridge  Unix socket for pen / BCI / MIDI / gesture drivers
;;   exo-scan    full leader access from 1-3 discrete signals (BCI, switch)
;;   exo-modal   evil (vim) defaults + leader tree + which-key
;;   exo-chords  shows your chords on screen and learns your progressions
;;   exo-memory  local embedding memory: text/image/audio/video, one space
;;   exo-agent   local agent: chat, inline ask with memory, rewrite
;;   exo-inline  ghost-text completions + accept/reject feedback log
;;   exo-evolve  your self.el layer and suggestions from your habits

;;; Code:

(require 'exo-core)
(require 'exo-input)
(require 'exo-memory)
(require 'exo-chords)
(require 'exo-voice)
(require 'exo-bridge)
(require 'exo-scan)
(require 'exo-modal)
(require 'exo-agent)
(require 'exo-inline)
(require 'exo-evolve)

(defgroup exo-setup nil
  "Startup options."
  :group 'exomachina)

(defcustom exo-start-bridge t
  "Start the input bridge socket at startup."
  :type 'boolean)

(defcustom exo-inline-enable t
  "Enable ghost-text completions in prog/text buffers at startup."
  :type 'boolean)

;;;###autoload
(defun exomachina-setup ()
  "Turn exomachina on."
  (exo-modal-setup)
  (exo-agent-setup)
  (exo-chords-mode 1)
  (when exo-inline-enable (global-exo-inline-mode 1))
  (when exo-start-bridge
    (condition-case err (exo-input-start 'bridge)
      (error (message "exo: bridge not started: %s" (error-message-string err)))))
  (exo-self-load))

(provide 'exomachina)
;;; exomachina.el ends here

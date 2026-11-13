;;; exo-bridge.el --- Local socket for external input drivers  -*- lexical-binding: t; -*-

;;; Commentary:
;; Pen tablets, BCI headsets, MIDI controllers, foot pedals, eye trackers:
;; any driver that can classify its signal can drive Emacs by writing JSON
;; lines to a Unix socket:
;;
;;   {"modality": "pen", "kind": "gesture", "value": "circle"}
;;   {"modality": "bci", "kind": "gesture", "value": "select"}
;;   {"modality": "midi", "kind": "text", "value": "Cmaj7"}
;;
;; Each line becomes an exo-input event.  Replies {"ok": true} per line.
;; See bin/exo-send for a reference client.
;;
;; The socket lives in a 0700 directory under $XDG_RUNTIME_DIR, so only
;; your user can connect.  Restrict what drivers may do with
;; `exo-bridge-allowed-kinds'.

;;; Code:

(require 'exo-core)
(require 'exo-input)
(declare-function exo-voice-utterance->event "exo-voice")

(defgroup exo-bridge nil
  "Socket bridge for external input drivers."
  :group 'exomachina)

(defcustom exo-bridge-socket
  (expand-file-name "exomachina/input.sock"
                    (or (getenv "XDG_RUNTIME_DIR") temporary-file-directory))
  "Path of the input bridge Unix socket."
  :type 'file)

(defcustom exo-bridge-allowed-kinds '(text keys gesture command utterance)
  "Event kinds external drivers may send.
`utterance' is a spoken transcript transcribed elsewhere (e.g. on your
laptop by bin/exo-remote voice); it gets the same command-word parsing
as local voice input."
  :type '(repeat symbol))

(defvar exo-bridge--server nil "Listening server process.")

(defun exo-bridge--handle-line (proc line)
  "Parse LINE from PROC and emit it as an event."
  (let* ((obj (exo-json-read-line line))
         (kind (and obj (intern (or (plist-get obj :kind) "text")))))
    (cond ((null obj) (process-send-string proc "{\"ok\":false,\"error\":\"bad json\"}\n"))
          ((not (memq kind exo-bridge-allowed-kinds))
           (process-send-string proc "{\"ok\":false,\"error\":\"kind not allowed\"}\n"))
          ((eq kind 'utterance)
           (require 'exo-voice)
           (exo-input-emit (exo-voice-utterance->event (format "%s" (plist-get obj :value))))
           (process-send-string proc "{\"ok\":true}\n"))
          (t (exo-input-emit obj)
             (process-send-string proc "{\"ok\":true}\n")))))

(defun exo-bridge--filter (proc string)
  "Split STRING from PROC into lines and handle each complete line."
  (let ((buf (concat (or (process-get proc :exo-pending) "") string)))
    (while (string-match "\n" buf)
      (let ((line (string-trim (substring buf 0 (match-beginning 0)))))
        (setq buf (substring buf (match-end 0)))
        (unless (string-empty-p line)
          (exo-bridge--handle-line proc line))))
    (process-put proc :exo-pending buf)))

(defun exo-bridge-start ()
  "Listen on `exo-bridge-socket'."
  (unless (process-live-p exo-bridge--server)
    (let ((dir (file-name-directory exo-bridge-socket)))
      (with-file-modes #o700 (make-directory dir t))
      (set-file-modes dir #o700)
      (when (file-exists-p exo-bridge-socket) (delete-file exo-bridge-socket))
      (setq exo-bridge--server
            (make-network-process
             :name "exo-bridge" :server t :family 'local :service exo-bridge-socket
             :coding 'utf-8 :noquery t
             :filter #'exo-bridge--filter :sentinel #'ignore))
      (add-hook 'kill-emacs-hook #'exo-bridge-stop))))

(defun exo-bridge-stop ()
  "Stop listening and remove the socket."
  (when (process-live-p exo-bridge--server) (delete-process exo-bridge--server))
  (setq exo-bridge--server nil)
  (when (file-exists-p exo-bridge-socket) (ignore-errors (delete-file exo-bridge-socket))))

(exo-input-register-source 'bridge :start #'exo-bridge-start :stop #'exo-bridge-stop
                           :doc "Unix socket for pen/BCI/MIDI/gesture drivers")

(provide 'exo-bridge)
;;; exo-bridge.el ends here

;;; exo-core.el --- Shared core for exomachina  -*- lexical-binding: t; -*-

;;; Commentary:
;; Customization group, data directory, and small async helpers that the
;; other exo-* modules share.  Nothing here talks to the network except
;; `exo-http-post-json', and the default host is your local Ollama.

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'url-http)

(defgroup exomachina nil
  "Exomachina: an Emacs that grows with you."
  :group 'convenience
  :prefix "exo-")

(defcustom exo-data-directory
  (file-name-as-directory
   (expand-file-name (or (getenv "EXO_VAULT")
                         (expand-file-name "exomachina/"
                                           (or (getenv "XDG_DATA_HOME") "~/.local/share/")))))
  "The vault: memory, chord stats, feedback, settings and your self layer.
Set with $EXO_VAULT (or `bin/exomachina --vault DIR'); defaults to
$XDG_DATA_HOME/exomachina/.  Lives outside the repo, created owner-only."
  :type 'directory)

(defcustom exo-ollama-host "http://localhost:11434"
  "Base URL of the local Ollama server."
  :type 'string)

(defun exo-data-file (name)
  "Return absolute path of NAME inside `exo-data-directory', creating it."
  (unless (file-directory-p exo-data-directory)
    (with-file-modes #o700
      (make-directory exo-data-directory t)))
  (expand-file-name name exo-data-directory))

(defun exo-append-line (file line)
  "Append LINE and a newline to FILE, creating FILE owner-only."
  (with-file-modes #o600
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (concat line "\n") nil file t 'silent))))

(defun exo-write-file (file string)
  "Replace FILE contents with STRING, owner-only."
  (with-file-modes #o600
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region string nil file nil 'silent))))

(defun exo-json-read-line (line)
  "Parse LINE as JSON into a plist, or nil when it is not valid JSON."
  (condition-case nil
      (json-parse-string line :object-type 'plist :array-type 'array
                         :null-object nil :false-object nil)
    (error nil)))

(defun exo-http-post-json (url payload callback)
  "POST PAYLOAD (a plist) as JSON to URL asynchronously.
CALLBACK is called with (DATA ERROR): DATA is the parsed JSON body
as a plist, ERROR is non-nil on any failure.  Never signals."
  (let* ((done nil)
         (callback (lambda (data err)
                     ;; url.el can report one failure twice; answer once.
                     (unless done (setq done t) (funcall callback data err))))
         (url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data (encode-coding-string (json-serialize payload) 'utf-8)))
    (condition-case err
        (url-retrieve
         url
         (lambda (status)
           (let ((buf (current-buffer)) data e)
             (unwind-protect
                 (if-let* ((se (plist-get status :error)))
                     (setq e se)
                   (goto-char (point-min))
                   (if (not (re-search-forward "\r?\n\r?\n" nil t))
                       (setq e 'no-body)
                     (decode-coding-region (point) (point-max) 'utf-8)
                     (condition-case pe
                         (setq data (json-parse-buffer
                                     :object-type 'plist :array-type 'array
                                     :null-object nil :false-object nil))
                       (error (setq e pe)))))
               (kill-buffer buf))
             (funcall callback data e)))
         nil 'silent 'inhibit-cookies)
      (error (funcall callback nil err)))))

(provide 'exo-core)
;;; exo-core.el ends here

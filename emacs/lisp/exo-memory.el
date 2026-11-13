;;; exo-memory.el --- Embedding memory that stays on your machine  -*- lexical-binding: t; -*-

;;; Commentary:
;; Append-only JSONL store in `exo-data-directory' (memory.jsonl, 0600).
;; Each entry: id, key, kind, text, meta, ts, model, vec.
;;
;; Encoder: EmbeddingGemma 2 (Google, Apache 2.0, Oct 2026).  One model
;; maps text, images, audio and video into a single 768-d space, so a
;; sketch, a voice memo, a clip and a sentence about them can find each
;; other.  Two ways to run it (`exo-memory-backend'):
;;
;;   ollama   `ollama pull embeddinggemma-2'.  Text only from Emacs.
;;   sidecar  bin/exo-embed (full HF weights via sentence-transformers):
;;            text + image + audio + video.  Starts on first use
;;            (or `exo-memory-sidecar-start'); needs uv.
;;
;; Entries remember which model embedded them; search only compares
;; vectors from the same model.  Switching backend?  Run
;; `exo-memory-reembed' so everything lives in one space again.
;; Without embeddings, search falls back to keyword overlap.
;;
;; Text gets the model's task prefixes (documents vs queries); media is
;; embedded as-is.  Not yet encrypted at rest: that is the vault's job.

;;; Code:

(require 'exo-core)

(defgroup exo-memory nil
  "Local embedding memory."
  :group 'exomachina)

(defcustom exo-memory-backend (if (executable-find "uv") 'sidecar 'ollama)
  "Embedding backend.  Default `sidecar' when uv is installed.
`ollama': text only, model `exo-memory-embed-model' on local Ollama.
`sidecar': text, image, audio and video via bin/exo-embed."
  :type '(choice (const ollama) (const sidecar)))

(defcustom exo-memory-embed-model "embeddinggemma-2"
  "Ollama embedding model (backend `ollama')."
  :type 'string)

(defcustom exo-memory-sidecar-model "google/embeddinggemma-2"
  "Model the sidecar serves (backend `sidecar')."
  :type 'string)

(defcustom exo-memory-sidecar-url "http://127.0.0.1:11435/api/embed"
  "Embed endpoint of the sidecar."
  :type 'string)

(defcustom exo-memory-sidecar-command
  (list (expand-file-name "../bin/exo-embed"
                          (file-name-directory (or load-file-name buffer-file-name))))
  "Command that starts the sidecar."
  :type '(repeat string))

(defcustom exo-memory-query-prefix "task: search result | query: "
  "Prefix for search queries (EmbeddingGemma task prompt)."
  :type 'string)

(defcustom exo-memory-document-prefix "title: none | text: "
  "Prefix for stored text (EmbeddingGemma document prompt)."
  :type 'string)

(defcustom exo-memory-media-types
  '(("png" . image) ("jpg" . image) ("jpeg" . image) ("webp" . image) ("gif" . image)
    ("wav" . audio) ("mp3" . audio) ("flac" . audio) ("ogg" . audio) ("m4a" . audio)
    ("mp4" . video) ("mov" . video) ("webm" . video) ("mkv" . video))
  "File extension -> media kind."
  :type '(alist :key-type string :value-type symbol))

(defcustom exo-memory-file-name "memory.jsonl"
  "File name of the memory store inside `exo-data-directory'."
  :type 'string)

(defvar exo-memory-embed-function nil
  "Override: function (ITEMS CALLBACK).  CALLBACK gets vectors or nil.
ITEMS are strings or plists like (:image \"/path.png\").
Nil means use `exo-memory-backend'.")

(defvar exo-memory--entries nil "Cached entries, newest first.")
(defvar exo-memory--loaded-file nil "File the cache was loaded from.")
(defvar exo-memory--sidecar nil "Sidecar process, if we started it.")

(defun exo-memory--file ()
  "Absolute path of the memory store."
  (exo-data-file exo-memory-file-name))

(defun exo-memory-model ()
  "Label of the model that embeds right now."
  (if (eq exo-memory-backend 'sidecar) exo-memory-sidecar-model exo-memory-embed-model))

;;;; Embedding backends

(defun exo-memory-http-embedder (url model)
  "Return an embed function that POSTs to URL in Ollama /api/embed shape."
  (lambda (items callback)
    (exo-http-post-json
     url (list :model model :input (vconcat items))
     (lambda (data err)
       (funcall callback
                (and (not err) data (plist-get data :embeddings)
                     (append (plist-get data :embeddings) nil)))))))

;; The sidecar starts on first use, not with Emacs: torch + weights cost
;; RAM and VRAM you may want for the chat model.  Requests that arrive
;; while it loads wait in a queue instead of being stored unembedded.
(defvar exo-memory--sidecar-ready nil "Non-nil once our sidecar printed its ready line.")
(defvar exo-memory--sidecar-queue nil "Thunks to run when the sidecar is ready (or died).")

(defcustom exo-memory-sidecar-wait 600
  "Seconds to wait for the sidecar to load before giving up on queued requests.
The first start downloads its dependencies and the model weights."
  :type 'integer)

(defun exo-memory--sidecar-flush ()
  (let ((q (nreverse exo-memory--sidecar-queue)))
    (setq exo-memory--sidecar-queue nil)
    (mapc #'funcall q)))

(defun exo-memory--sidecar-filter (proc string)
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max)) (insert string)))
  (when (and (not exo-memory--sidecar-ready) (string-match-p "exo-embed: .* on 127" string))
    (setq exo-memory--sidecar-ready t)
    (message "exo: embedding sidecar ready")
    (exo-memory--sidecar-flush)))

(defun exo-memory-sidecar-start ()
  "Start bin/exo-embed.  First run downloads its deps and the model weights."
  (interactive)
  (unless (process-live-p exo-memory--sidecar)
    (setq exo-memory--sidecar-ready nil
          exo-memory--sidecar
          (make-process :name "exo-embed" :noquery t
                        :buffer (get-buffer-create " *exo-embed*")
                        :command exo-memory-sidecar-command
                        :filter #'exo-memory--sidecar-filter
                        :sentinel (lambda (p _e)
                                    (unless (process-live-p p)
                                      (setq exo-memory--sidecar-ready nil)
                                      (exo-memory--sidecar-flush)))))
    (run-at-time exo-memory-sidecar-wait nil
                 (lambda () (unless exo-memory--sidecar-ready (exo-memory--sidecar-flush))))
    (message "exo: starting embedding sidecar (see buffer \" *exo-embed*\")")))

(defun exo-memory--sidecar-embed (items callback &optional retried)
  "Embed ITEMS via the sidecar, starting it and waiting if it is not up."
  (funcall (exo-memory-http-embedder exo-memory-sidecar-url exo-memory-sidecar-model)
           items
           (lambda (vecs)
             (cond (vecs (funcall callback vecs))
                   ;; Reachable but refused (bad file?), or already retried.
                   ((or retried exo-memory--sidecar-ready) (funcall callback nil))
                   (t (unless (process-live-p exo-memory--sidecar)
                        (exo-memory-sidecar-start))
                      (push (lambda () (exo-memory--sidecar-embed items callback t))
                            exo-memory--sidecar-queue))))))

(defun exo-memory--embed (items callback)
  "Embed ITEMS via the configured backend; CALLBACK gets vectors or nil."
  (cond (exo-memory-embed-function (funcall exo-memory-embed-function items callback))
        ((eq exo-memory-backend 'sidecar) (exo-memory--sidecar-embed items callback))
        ((cl-every #'stringp items)
         (funcall (exo-memory-http-embedder (concat exo-ollama-host "/api/embed")
                                            exo-memory-embed-model)
                  items callback))
        (t (message "exo: images/audio/video need the sidecar (exo-memory-backend 'sidecar)")
           (funcall callback nil))))

(defun exo-memory-media-kind (file)
  "Media kind of FILE (image, audio, video) or nil."
  (cdr (assoc (downcase (or (file-name-extension file) "")) exo-memory-media-types)))

(defun exo-memory--item (e)
  "What to send the encoder for entry E."
  (if-let* ((path (plist-get (plist-get e :meta) :path))
            (kind (exo-memory-media-kind path)))
      (list (intern (format ":%s" kind)) path)
    (concat exo-memory-document-prefix (plist-get e :text))))

;;;; Store

(defun exo-memory--entry-ident (e)
  "Identity of entry E: its :key if set, else its :id."
  (or (plist-get e :key) (plist-get e :id)))

(defun exo-memory-load (&optional force)
  "Load entries from disk into the cache (once, unless FORCE)."
  (let ((file (exo-memory--file)))
    (when (or force (not (equal file exo-memory--loaded-file)))
      (let ((seen (make-hash-table :test 'equal)) out)
        (when (file-exists-p file)
          (with-temp-buffer
            (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
            (dolist (line (split-string (buffer-string) "\n" t))
              (when-let* ((e (exo-json-read-line line)))
                (setq e (plist-put e :kind (intern (or (plist-get e :kind) "note"))))
                (puthash (exo-memory--entry-ident e) e seen)))))
        ;; later lines win; rebuild newest-first
        (maphash (lambda (_ e) (push e out)) seen)
        (setq exo-memory--entries
              (sort out (lambda (a b) (> (or (plist-get a :ts) 0) (or (plist-get b :ts) 0)))))
        (setq exo-memory--loaded-file file))))
  exo-memory--entries)

(defun exo-memory--serialize (e)
  "JSON line for entry E."
  (json-serialize
   (cl-loop for (k v) on e by #'cddr
            when v append (list k (if (and (eq k :kind) (symbolp v)) (symbol-name v) v)))))

(defun exo-memory--rewrite ()
  "Rewrite the store from the cache (drops superseded and forgotten lines)."
  (exo-write-file (exo-memory--file)
                  (mapconcat (lambda (e) (concat (exo-memory--serialize e) "\n"))
                             (reverse exo-memory--entries) "")))

(defun exo-memory--store (entry)
  "Append ENTRY to disk and cache, replacing any entry with the same key."
  (exo-memory-load)
  (let ((ident (exo-memory--entry-ident entry)))
    (setq exo-memory--entries
          (cons entry (cl-remove-if (lambda (e) (equal (exo-memory--entry-ident e) ident))
                                    exo-memory--entries))))
  (exo-append-line (exo-memory--file) (exo-memory--serialize entry))
  entry)

(defun exo-memory--add-entry (entry callback)
  "Embed ENTRY, store it (with or without a vector), then call CALLBACK."
  (let ((model (exo-memory-model)))
    (exo-memory--embed
     (list (exo-memory--item entry))
     (lambda (vecs)
       (let ((entry (append (list :id (format "%x-%04x" (floor (* 1000 (float-time)))
                                              (random 65536))
                                  :ts (float-time)
                                  :model (and vecs model)
                                  :vec (car vecs))
                            entry)))
         (exo-memory--store entry)
         (when callback (funcall callback entry)))))))

(cl-defun exo-memory-add (text &key (kind 'note) key meta callback)
  "Remember TEXT asynchronously.
KIND tags it, KEY makes it an upsert (same key replaces), META is a
plist saved alongside.  CALLBACK, if given, gets the stored entry."
  (exo-memory--add-entry (list :key key :kind kind :text text :meta meta) callback))

(cl-defun exo-memory-add-file (file &key note key callback)
  "Remember media FILE (image, audio or video) with an optional NOTE.
Embedded by content in the same space as text (needs the sidecar)."
  (let* ((path (expand-file-name file))
         (kind (or (exo-memory-media-kind path)
                   (user-error "Not an image/audio/video file: %s" path))))
    (exo-memory--add-entry
     (list :key key :kind kind
           :text (if (and note (not (string-empty-p note))) note (file-name-nondirectory path))
           :meta (list :path path))
     callback)))

(defun exo-memory-forget-entry (ident)
  "Delete the entry with key or id IDENT and rewrite the store."
  (exo-memory-load)
  (setq exo-memory--entries
        (cl-remove-if (lambda (e) (equal (exo-memory--entry-ident e) ident))
                      exo-memory--entries))
  (exo-memory--rewrite))

;;;; Search

(defun exo-memory-cosine (a b)
  "Cosine similarity of vectors A and B."
  (let ((dot 0.0) (na 0.0) (nb 0.0))
    (dotimes (i (min (length a) (length b)))
      (let ((x (aref a i)) (y (aref b i)))
        (setq dot (+ dot (* x y)) na (+ na (* x x)) nb (+ nb (* y y)))))
    (if (or (zerop na) (zerop nb)) 0.0 (/ dot (sqrt (* na nb))))))

(defun exo-memory--top (scored k)
  "Top K of SCORED, a list of (SCORE . ENTRY), dropping zero scores."
  (seq-take (sort (cl-remove-if-not (lambda (s) (> (car s) 0)) scored)
                  (lambda (a b) (> (car a) (car b))))
            k))

(defun exo-memory--rank-vec (qvec k &optional model)
  "Rank cached entries embedded by MODEL against QVEC by cosine; top K."
  (let ((model (or model (exo-memory-model))))
    (exo-memory--top
     (cl-loop for e in (exo-memory-load)
              for v = (plist-get e :vec)
              when (and v (equal (plist-get e :model) model)
                        (= (length v) (length qvec)))
              collect (cons (exo-memory-cosine qvec v) e))
     k)))

(defun exo-memory--rank-text (query k)
  "Rank cached entries by fraction of QUERY words they contain; top K."
  (let ((words (split-string (downcase query) "[^[:alnum:]]+" t)))
    (exo-memory--top
     (cl-loop for e in (exo-memory-load)
              for text = (downcase (plist-get e :text))
              collect (cons (/ (float (cl-count-if (lambda (w) (string-search w text)) words))
                               (max 1 (length words)))
                            e))
     k)))

(defun exo-memory-search (query k callback)
  "Find the K memories closest to QUERY; CALLBACK gets ((SCORE . ENTRY) ...).
QUERY is text, or a media file path to search by example."
  (let ((model (exo-memory-model))
        (kind (and (file-exists-p query) (exo-memory-media-kind query))))
    (exo-memory--embed
     (list (if kind (list (intern (format ":%s" kind)) (expand-file-name query))
             (concat exo-memory-query-prefix query)))
     (lambda (vecs)
       (let ((found (and vecs (exo-memory--rank-vec (car vecs) k model))))
         (funcall callback (or found (exo-memory--rank-text query k))))))))

;;;; Commands

(defun exo-memory-remember (text)
  "Remember TEXT (the region, or prompted)."
  (interactive
   (list (if (use-region-p)
             (buffer-substring-no-properties (region-beginning) (region-end))
           (read-string "Remember: "))))
  (exo-memory-add text :callback
                  (lambda (e) (message "exo: remembered%s"
                                       (if (plist-get e :vec) "" " (no embedding: model offline)")))))

(declare-function dired-get-filename "dired")

(defun exo-memory-remember-file (file note)
  "Remember media FILE (image/audio/video), with an optional NOTE."
  (interactive
   (let ((f (read-file-name "Remember file: " nil nil t
                            (and (derived-mode-p 'dired-mode) (dired-get-filename nil t)))))
     (list f (read-string "Note (optional): "))))
  (exo-memory-add-file file :note note :callback
                       (lambda (e) (message "exo: remembered %s%s" (plist-get e :kind)
                                            (if (plist-get e :vec) ""
                                              " (no embedding: start the sidecar)")))))

(defun exo-memory-recall (query)
  "Show memories closest to QUERY (text, or a media file to match)."
  (interactive "sRecall (text or file path): ")
  (exo-memory-search
   query 10
   (lambda (hits)
     (with-current-buffer (get-buffer-create "*exo-memory*")
       (let ((inhibit-read-only t))
         (erase-buffer)
         (insert (format "Recall: %s\n\n" query))
         (if (null hits) (insert "(nothing yet)\n")
           (dolist (h hits)
             (let ((e (cdr h)))
               (insert (format "%.3f  [%s]  %s" (car h) (plist-get e :kind)
                               (string-replace "\n" " " (plist-get e :text))))
               (when-let* ((path (plist-get (plist-get e :meta) :path)))
                 (insert "  ")
                 (insert-text-button "[open]" 'action (lambda (_) (find-file path))))
               (insert "\n"))))
         (special-mode))
       (display-buffer (current-buffer))))))

(defun exo-memory-forget ()
  "Pick a memory and delete it from disk."
  (interactive)
  (let* ((cands (mapcar (lambda (e)
                          (cons (format "[%s] %s" (plist-get e :kind)
                                        (truncate-string-to-width
                                         (string-replace "\n" " " (plist-get e :text)) 80))
                                (exo-memory--entry-ident e)))
                        (exo-memory-load)))
         (pick (completing-read "Forget: " cands nil t)))
    (exo-memory-forget-entry (cdr (assoc pick cands)))
    (message "exo: forgotten")))

(defun exo-memory-reembed ()
  "Embed entries stored without a vector or by another model."
  (interactive)
  (let* ((model (exo-memory-model))
         (todo (cl-remove-if (lambda (e) (equal (plist-get e :model) model))
                             (exo-memory-load))))
    (if (null todo) (message "exo: all memories embedded by %s" model)
      (exo-memory--embed
       (mapcar #'exo-memory--item todo)
       (lambda (vecs)
         (if (not vecs) (message "exo: embed backend unreachable")
           (cl-loop for e in todo for v in vecs
                    do (plist-put e :vec v)
                    do (plist-put e :model model))
           (exo-memory--rewrite)
           (message "exo: re-embedded %d memories with %s" (length todo) model)))))))

(provide 'exo-memory)
;;; exo-memory.el ends here

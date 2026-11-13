;;; exo-test.el --- Tests for exomachina  -*- lexical-binding: t; -*-

;; Run: emacs --batch -Q -L lisp -l test/exo-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'exo-core)
(require 'exo-input)
(require 'exo-memory)
(require 'exo-chords)
(require 'exo-voice)
(require 'exo-bridge)
(require 'exo-scan)
(require 'exo-modal)
(require 'exo-inline)

(defvar evil-local-mode)
(defconst exo-test--dir (file-name-directory (or load-file-name buffer-file-name)))

(defmacro exo-test-with-data-dir (&rest body)
  "Run BODY with a fresh data directory and empty memory cache."
  `(let* ((exo-data-directory (file-name-as-directory (make-temp-file "exo-test-" t)))
          (exo-memory--entries nil)
          (exo-memory--loaded-file nil)
          (exo-memory-backend 'ollama)
          (exo-memory-query-prefix "")
          (exo-memory-document-prefix ""))
     (unwind-protect (progn ,@body)
       (delete-directory exo-data-directory t))))

(defun exo-test-fake-embed (texts callback)
  "Deterministic 3-d embedding: counts of the letters a, b, c."
  (funcall callback
           (mapcar (lambda (s) (vector (float (cl-count ?a s)) (float (cl-count ?b s))
                                       (float (cl-count ?c s))))
                   texts)))

;;;; memory

(ert-deftest exo-test-cosine ()
  (should (< (abs (- (exo-memory-cosine [1 0] [1 0]) 1.0)) 1e-9))
  (should (< (abs (exo-memory-cosine [1 0] [0 1])) 1e-9))
  (should (= (exo-memory-cosine [0 0] [1 1]) 0.0)))

(ert-deftest exo-test-memory-roundtrip-and-rank ()
  (exo-test-with-data-dir
   (let ((exo-memory-embed-function #'exo-test-fake-embed)
         (exo-memory-embed-model "fake"))
     (exo-memory-add "aaaa" :kind 'note)
     (exo-memory-add "bbbb" :kind 'note)
     (exo-memory-add "cccc first" :key "k1")
     (exo-memory-add "cccc second" :key "k1")      ; upsert replaces
     ;; reload from disk
     (setq exo-memory--entries nil exo-memory--loaded-file nil)
     (should (= (length (exo-memory-load)) 3))
     (should (equal (plist-get (cl-find "k1" (exo-memory-load)
                                        :key (lambda (e) (plist-get e :key)) :test #'equal)
                               :text)
                    "cccc second"))
     (let (hits)
       (exo-memory-search "bb" 2 (lambda (h) (setq hits h)))
       (should (equal (plist-get (cdar hits) :text) "bbbb")))
     (should (= (file-modes (exo-memory--file)) #o600)))))

(ert-deftest exo-test-memory-offline-falls-back-to-keywords ()
  (exo-test-with-data-dir
   (let ((exo-memory-embed-function (lambda (_ cb) (funcall cb nil))))
     (exo-memory-add "the bass line in D dorian")
     (exo-memory-add "grocery list")
     (should-not (plist-get (car (exo-memory-load)) :vec))
     (let (hits)
       (exo-memory-search "dorian bass" 5 (lambda (h) (setq hits h)))
       (should (= (length hits) 1))
       (should (string-match-p "dorian" (plist-get (cdar hits) :text)))))))

(ert-deftest exo-test-memory-forget-removes-from-disk ()
  (exo-test-with-data-dir
   (let ((exo-memory-embed-function (lambda (_ cb) (funcall cb nil))))
     (exo-memory-add "secret thing" :key "s")
     (exo-memory-add "keep me")
     (exo-memory-forget-entry "s")
     (should-not (string-search "secret" (with-temp-buffer
                                           (insert-file-contents (exo-memory--file))
                                           (buffer-string)))))))

;; media items are plists; the fake encoder treats them by path text
(defun exo-test-fake-embed-any (items callback)
  (exo-test-fake-embed (mapcar (lambda (i) (if (stringp i) i (format "%S" i))) items) callback))

(ert-deftest exo-test-memory-media-and-prefixes ()
  (exo-test-with-data-dir
   (let* ((sent nil)
          (exo-memory-embed-function (lambda (items cb) (setq sent (append sent items))
                                       (exo-test-fake-embed-any items cb)))
          (exo-memory-embed-model "fake")
          (exo-memory-query-prefix "Q: ")
          (exo-memory-document-prefix "D: ")
          (img (expand-file-name "bbb.png" exo-data-directory))
          got)
     (write-region "" nil img)
     (exo-memory-add "aaa")
     (exo-memory-add-file img :note "sketch" :callback (lambda (e) (setq got e)))
     (should (eq (plist-get got :kind) 'image))
     (should (equal (plist-get got :text) "sketch"))
     (should (equal (plist-get (plist-get got :meta) :path) img))
     (exo-memory-search "ccc" 1 #'ignore)
     (should (equal (nth 0 sent) "D: aaa"))
     (should (equal (nth 1 sent) (list :image img)))      ; media: no prefix
     (should (equal (nth 2 sent) "Q: ccc"))
     ;; search by example with a media file
     (let (hits)
       (exo-memory-search img 1 (lambda (h) (setq hits h)))
       (should (equal (nth 3 sent) (list :image img)))
       (should (eq (plist-get (cdar hits) :kind) 'image)))
     ;; reembed sends media as media, text with the document prefix
     (setq sent nil)
     (let ((exo-memory-embed-model "fake2")) (exo-memory-reembed))
     (should (member (list :image img) sent))
     (should (member "D: aaa" sent)))))

(ert-deftest exo-test-memory-ollama-refuses-media ()
  (exo-test-with-data-dir
   (let ((exo-memory-embed-function nil) got)
     (exo-memory--embed (list (list :image "/x.png")) (lambda (v) (setq got (list v))))
     (should (equal got '(nil))))))

;;;; input

(ert-deftest exo-test-input-text-and-gesture ()
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (exo-input-emit '(:modality voice :kind text :value "hello"))
    (exo-input-emit '(:modality "voice" :kind "text" :value "world"))
    (should (equal (buffer-string) "hello world"))
    (let* ((ran nil)
           (exo-input-gestures `(((pen . "circle") . ,(lambda () (setq ran 'pen)))
                                 ((any . "tap") . ,(lambda () (setq ran 'any))))))
      (exo-input-emit '(:modality pen :kind gesture :value "circle"))
      (should (eq ran 'pen))
      (exo-input-emit '(:modality bci :kind gesture :value "tap"))
      (should (eq ran 'any)))))

(ert-deftest exo-test-input-hooks-consume-and-observe ()
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (let* (seen
           (exo-input-event-functions (list (lambda (e) (equal (plist-get e :value) "eat"))))
           (exo-input-observe-functions (list (lambda (e) (push (plist-get e :value) seen)))))
      (exo-input-emit '(:modality x :kind text :value "eat"))
      (exo-input-emit '(:modality x :kind text :value "keep"))
      (should (equal (buffer-string) "keep"))
      (should (equal seen '("keep" "eat"))))))

(ert-deftest exo-test-voice-utterances ()
  (should (equal (exo-voice-utterance->event "Hello there.")
                 '(:modality voice :kind text :value "Hello there.")))
  (should (equal (exo-voice-utterance->event "Computer, save.")
                 '(:modality voice :kind command :value save-buffer)))
  (should (equal (exo-voice-utterance->event "computer delete word")
                 '(:modality voice :kind keys :value "diw")))
  (should (equal (exo-voice-utterance->event "computer describe key")
                 '(:modality voice :kind command :value describe-key))))

(ert-deftest exo-test-bridge-socket ()
  (let* ((dir (make-temp-file "exo-sock-" t))
         (exo-bridge-socket (expand-file-name "s/input.sock" dir))
         (got nil)
         (exo-input-event-functions (list (lambda (e) (push e got) t)))
         (reply ""))
    (unwind-protect
        (progn
          (exo-bridge-start)
          (should (= (file-modes (file-name-directory exo-bridge-socket)) #o700))
          (let ((c (make-network-process :name "exo-test-client" :family 'local
                                         :service exo-bridge-socket :noquery t
                                         :filter (lambda (_ s) (setq reply (concat reply s))))))
            (process-send-string c "{\"modality\":\"pen\",\"kind\":\"gesture\",")
            (process-send-string c "\"value\":\"circle\"}\nnot json\n")
            (with-timeout (3 nil)
              (while (< (cl-count ?\n reply) 2) (accept-process-output nil 0.05)))
            (delete-process c))
          (should (= (length got) 1))
          (should (eq (plist-get (car got) :modality) 'pen))
          (should (equal (plist-get (car got) :value) "circle"))
          (should (string-match-p "\"ok\":true" reply))
          (should (string-match-p "bad json" reply)))
      (exo-bridge-stop)
      (delete-directory dir t))))

;;;; scan

(ert-deftest exo-test-scan-walks-keymap ()
  (let* ((ran nil)
         (sub (make-sparse-keymap))
         (root (make-sparse-keymap)))
    (keymap-set sub "x" (lambda () (interactive) (setq ran 'x)))
    (keymap-set root "a" (lambda () (interactive) (setq ran 'a)))
    (define-key root "b" (cons "sub" sub))
    (with-temp-buffer
      (set-window-buffer (selected-window) (current-buffer))
      (exo-scan root)
      (unwind-protect
          (progn
            (exo-input-emit '(:modality bci :kind gesture :value "next"))   ; -> b
            (exo-input-emit '(:modality bci :kind gesture :value "select")) ; enter sub
            (exo-input-emit '(:modality bci :kind gesture :value "select")) ; run x
            (should (eq ran 'x))
            (should-not exo-scan--stack))
        (exo-scan-stop)))))

;;;; chords

(ert-deftest exo-test-chords-filtering-and-ngrams ()
  (let ((exo-chords--counts (make-hash-table :test 'equal))
        (exo-chords--ngrams (make-hash-table :test 'equal))
        (exo-chords--mx (make-hash-table :test 'eq))
        (exo-chords--recent nil))
    (with-temp-buffer
      (should-not (exo-chords--interesting-p 'self-insert-command [?a] 'normal))
      (should-not (exo-chords--interesting-p 'org-self-insert-command [?a] 'normal))
      (should (exo-chords--interesting-p 'save-buffer [?\C-x ?\C-s]))
      ;; plain keys count only in evil command states
      (should (exo-chords--interesting-p 'evil-delete [?d ?i ?w] 'normal))
      (should (exo-chords--interesting-p 'evil-delete [?d] 'visual))
      (should-not (exo-chords--interesting-p 'newline [return] 'insert))
      (should-not (exo-chords--interesting-p 'some-cmd [?x] 'emacs))
      (should-not (exo-chords--interesting-p 'some-cmd [?x] nil))
      (should (exo-chords--interesting-p 'evil-delete-backward-word [?\C-w] 'insert))
      ;; raw terminal input (e.g. a sudo password) is plain keys outside normal state
      (should-not (exo-chords--interesting-p 'term-send-raw [?p] 'emacs))
      ;; isearch runs outside the minibuffer, even from normal state
      (let ((isearch-mode t))
        (should-not (exo-chords--interesting-p 'isearch-printing-char [?f] 'normal))))
    (exo-chords-record 'evil-delete [?d ?i ?w])
    (exo-chords-record 'evil-change [?c ?i ?w])
    (exo-chords-record 'evil-delete [?d ?i ?w])
    (should (string-match-p "×2" (cdr exo-chords--last)))
    (exo-chords-record 'org-agenda [] t)
    (should (= (gethash "d i w\tevil-delete" exo-chords--counts) 2))
    (should (= (gethash "d i w → c i w" exo-chords--ngrams) 1))
    (should (= (gethash "d i w → c i w → d i w" exo-chords--ngrams) 1))
    (should (= (gethash 'org-agenda exo-chords--mx) 1))))

(ert-deftest exo-test-chords-persist ()
  (exo-test-with-data-dir
   (let ((exo-chords--counts (make-hash-table :test 'equal))
         (exo-chords--ngrams (make-hash-table :test 'equal))
         (exo-chords--mx (make-hash-table :test 'eq))
         (exo-chords--recent nil))
     (exo-chords-record 'evil-delete [?d ?d])
     (exo-chords-save)
     (clrhash exo-chords--counts)
     (exo-chords-load)
     (should (= (gethash "d d\tevil-delete" exo-chords--counts) 1)))))

;;;; leader

(ert-deftest exo-test-leader-labels ()
  (let ((exo-leader-map (make-sparse-keymap)))
    (exo-modal-default-leader)
    (should (eq (keymap-lookup exo-leader-map "a a") #'exo-agent-chat))
    (should (assoc "a agent" (exo-scan-items exo-leader-map)))))

;;;; inline

(ert-deftest exo-test-inline-show-accept-and-feedback ()
  (exo-test-with-data-dir
   (with-temp-buffer
     (set-window-buffer (selected-window) (current-buffer))
     (insert "(defun foo ")
     (let ((exo-inline-request-function
            (lambda (prefix _suffix cb)
              (should (string-suffix-p "foo " prefix))
              (funcall cb "(x) x)\n\n"))))
       (exo-inline--trigger (current-buffer))
       (should exo-inline--visible)
       (should (equal exo-inline--text "(x) x)"))
       (should (equal (buffer-string) "(defun foo "))  ; ghost only
       (exo-inline-accept)
       (should (equal (buffer-string) "(defun foo (x) x)"))
       (should-not exo-inline--visible)
       (should (string-match-p "\"accepted\":true"
                               (with-temp-buffer
                                 (insert-file-contents (exo-data-file "feedback.jsonl"))
                                 (buffer-string))))))))

(ert-deftest exo-test-inline-dismiss-logs-nothing-and-private-buffers-skip ()
  (exo-test-with-data-dir
   (with-temp-buffer
     (set-window-buffer (selected-window) (current-buffer))
     (insert "x = ")
     (let ((exo-inline-request-function (lambda (_p _s cb) (funcall cb "1"))))
       (exo-inline--trigger (current-buffer))
       (should exo-inline--visible)
       (exo-inline-dismiss)
       (should-not (file-exists-p (exo-data-file "feedback.jsonl")))
       (rename-buffer ".env")
       (exo-inline--trigger (current-buffer))
       (should-not exo-inline--visible)))))

(ert-deftest exo-test-inline-drops-stale-reply ()
  (exo-test-with-data-dir
   (with-temp-buffer
     (set-window-buffer (selected-window) (current-buffer))
     (insert "abc")
     (let* ((pending nil)
            (exo-inline-request-function (lambda (_p _s cb) (setq pending cb))))
       (exo-inline--trigger (current-buffer))
       (insert "d")                      ; user kept typing
       (funcall pending "zzz")
       (should-not exo-inline--visible)))))

;;; exo-test.el ends here

(ert-deftest exo-test-chords-full-keys ()
  ;; evil "d i w": operator saw [d], motion read 2 more events
  (should (equal (exo-chords-full-keys [?d] [?i ?w] 2 [?x ?d ?i ?w]) [?d ?i ?w]))
  ;; evil "d d": indistinguishable by keys, counter says 1 extra event
  (should (equal (exo-chords-full-keys [?d] [?d] 1 [?d ?d]) [?d ?d]))
  ;; ordinary command
  (should (equal (exo-chords-full-keys [?\C-x ?\C-s] [?\C-x ?\C-s] 0 []) [?\C-x ?\C-s]))
  ;; long mid-command reads are never appended
  (should (equal (exo-chords-full-keys [?\C-x ?\C-f] [?\C-x ?\C-f] 9 [?a ?b ?c ?d ?e ?f ?g ?h ?i])
                 [?\C-x ?\C-f])))

(ert-deftest exo-test-sidecar-starts-on-demand ()
  "First embed finds no sidecar, starts it (fake mode), waits, then succeeds."
  (let* ((probe (make-network-process :name "exo-port" :server t :service t
                                      :host 'local))
         (port (process-contact probe :service))
         (_ (delete-process probe))
         (exo-memory-backend 'sidecar)
         (exo-memory-embed-function nil)
         (exo-memory-sidecar-url (format "http://127.0.0.1:%d/api/embed" port))
         (exo-memory-sidecar-command
          (list "python3" (expand-file-name "../bin/exo-embed" exo-test--dir)
                "--fake" "--port" (number-to-string port)))
         (exo-memory--sidecar nil) (exo-memory--sidecar-ready nil)
         (exo-memory--sidecar-queue nil)
         got done)
    (unwind-protect
        (progn
          (exo-memory--embed '("hello" "world")
                             (lambda (v) (setq got v done t)))
          (with-timeout (20) (while (not done) (accept-process-output nil 0.1)))
          (should exo-memory--sidecar-ready)
          (should (= (length got) 2))
          (should (= (length (car got)) 8)))
      (when (process-live-p exo-memory--sidecar) (delete-process exo-memory--sidecar)))))

(ert-deftest exo-test-http-unreachable-calls-back-once ()
  (let ((n 0) done)
    (exo-http-post-json "http://127.0.0.1:9/nope" '(:a 1)
                        (lambda (_d err) (cl-incf n) (setq done err)))
    (with-timeout (5) (while (not done) (accept-process-output nil 0.1)))
    (accept-process-output nil 0.3)
    (should done)
    (should (= n 1))))

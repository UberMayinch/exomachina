# exomachina for Emacs

A Lisp environment that you and a local agent keep shaping together, with
whatever input you have: keys, voice, keyboard gestures, a pen, or a BCI.

It starts small: modal editing, a dispatcher for input from any device, a
memory, and an agent. From then on the agent watches how you work and
proposes Lisp that changes the environment to fit you. Every change is a
form you can read, check and keep. Your copy ends up unlike anyone
else's, and it stays yours.

## Why a Lisp environment

### Homoiconic: code is data, so the environment can edit itself

In Lisp, a program is a list. The agent's output, your config and the
running system are all made of the same stuff, so changing the
environment is just handling lists.

- **Input is data.** Every keystroke, voice command, pen stroke or BCI
  signal becomes a plist before anything acts on it:
  ```elisp
  (:modality voice :kind command :value save-buffer)
  (:modality bci   :kind gesture :value "select")
  (:modality pen   :kind keys    :value "dd")      ; any modality can speak vim
  ```
  Bindings are data too: an alist from `(MODALITY . GESTURE)` to an
  action, plus a table that maps spoken phrases to actions.
- **Your adaptations are data.** `self.el` in your vault is a plain list
  of forms, one per change, and it loads last. Adopting a change
  appends one form to it and evaluates it, so the change applies at
  once with no restart.
- **The agent's proposals are data.** The agent writes Lisp forms, not
  a description of what to click. A proposal can be read, diffed,
  rejected, edited and kept with the same tools you use for code.

### Performant: the editor never waits on a model

Emacs runs on one thread, so the design rule is simple: nothing heavy
runs on it.

- Models run in their own processes: Ollama for chat and completion, a
  Python sidecar for multimodal embeddings, and faster-whisper for
  speech. Emacs talks to them over async HTTP or pipes.
- **Lazy.** The memory sidecar starts on first use and costs no RAM or
  VRAM until then. Requests that arrive while it loads are queued, not
  dropped.
- **Stale work is dropped.** If you keep typing, ghost-text replies for
  older positions are thrown away. They never block or jump the cursor.
- **Numbers measured on a 4 GB laptop GPU:**
  - Inline completion takes 0.1–0.2 s with the model warm, and about 5 s
    when Ollama has to swap models after a chat.
  - Memory recall searches in Lisp over a local JSONL file.
- An Emacs built with native compilation compiles the Lisp itself to
  machine code. exomachina works without it; the build tested here
  doesn't have it.

### Verifiable: you can see and check every change

An environment that rewrites itself is only safe if you can check
the rewrite. Today:

- **The agent never evaluates its own code.** `SPC e a` asks the local
  model for changes to `self.el` and shows them in a buffer marked
  "Review before evaluating anything". Nothing runs until you evaluate
  it.
- **The self layer is one readable file.** `SPC e s` opens `self.el`.
  It holds one form per change, in the order you adopted them.
  Deleting a line undoes that change at the next start. `self.el` is
  plain text, so you can keep it under git yourself to get history
  and rollback.
- **Everything is local and owner-only.** The vault directory is 0700
  and its files are 0600. Typed text is never logged. Buffers that look
  like secrets get no completions and no feedback logging.
- **The core is tested.** 22 ERT tests cover:
  - input dispatch
  - voice command parsing
  - the socket bridge
  - memory, including recall by image, audio and video
  - chords
  - the lazy sidecar
  - the vault location

  To run them:
  ```sh
  emacs --batch -Q -L lisp -l test/exo-test.el -f ert-run-tests-batch-and-exit
  ```

Next, so that you can trust more of the loop to the agent:

- Byte-compile each proposed form and run the test suite against it in a
  separate batch Emacs before you're asked to adopt it.
- An allowlist of which functions a proposal may call, checked
  structurally (possible because proposals are lists). A form that only
  rebinds keys can then be adopted with less scrutiny than one that runs
  a shell command.
- Track `self.el` in git automatically, so every adoption is a commit
  and any one of them can be reverted.

## The agent extends the environment around you

The loop:

1. **Observe.** These counts stay local in your vault:
   - The chords you press, and the chord progressions you repeat.
   - The commands you run through `M-x`.
   - The completions you accept.
2. **Propose.** `SPC e e` shows your habits and offers one-click bindings
   for the commands you keep typing. `SPC e a` hands the same report to
   the local model, which drafts up to five forms with a comment
   explaining each.
3. **Check.** You read the forms, edit them, or reject them.
4. **Keep.** Adopted forms are appended to `self.el` and take effect at
   once.

Because voice, gestures and BCI signals all become events in one
dispatcher, the same loop covers every modality:

```elisp
;; Phrases you say often become commands.
(add-to-list 'exo-voice-commands '("comment" . comment-line))

;; A pen circle remembers the current file.
(exo-input-bind-gesture 'pen "circle" #'exo-memory-remember-file)

;; Your BCI classifier is reliable on "blink"; make it the select signal.
(exo-input-bind-gesture 'bci "blink" #'exo-scan-select)

;; You scan the leader menu slowly; let it advance on its own.
(setq exo-scan-interval 1.2)

;; A command you keep running gets a leader key.
(exo-leader-def "o f" #'project-find-file)
```

## Modal editing for every input

Evil's states (normal, insert, visual) are the shared grammar. Each
input device is a source that emits events in one of four kinds:

| kind      | effect                                     | example                         |
|-----------|--------------------------------------------|---------------------------------|
| `text`    | insert at point                            | dictation                       |
| `keys`    | replay as vim keys                         | a pedal sends `u`               |
| `command` | call an interactive command                | "computer save"                 |
| `gesture` | look up `(MODALITY . NAME)` → action       | pen circle, BCI select          |

- **Keyboard** works natively. `SPC` is the leader key in normal state
  and `C-c e` everywhere else; which-key shows what each key does.
  Chords appear on screen as you play them.
- **Voice** is push-to-talk (`SPC i v`) and transcribed locally. Plain
  speech is inserted as text. Starting with "computer" runs a command:
  "computer save", "computer delete line", "computer recall".
- **Keyboard gestures, pen, MIDI and pedals** write JSON lines to a Unix
  socket (`bin/exo-send pen gesture undo`), so a driver can be written
  in any language.
- **BCI and single switches.** `exo-scan` (`SPC i s`) walks the whole
  leader tree with three signals: next, select and back. With
  `exo-scan-interval` set, a single "select" is enough. A classifier
  that tells two mental states apart can drive the entire environment.

A new modality means registering a source and emitting events; nothing
else changes.

## Use it

```sh
bin/exomachina                       # GUI; -nw for terminal; --vault DIR; EXO_EMACS if not on PATH
bin/exomachina pull                  # first run: chat + completion models, memory weights (~4 GB)
bin/exo-send bci gesture scan        # drive it from any device
```

Needs Emacs 29+. Ollama runs the agent (`qwen3:8b` for chat,
`qwen2.5-coder:1.5b` for inline completion). uv runs the memory sidecar
and voice transcription.

| key        | does                                                   |
|------------|--------------------------------------------------------|
| `SPC a a`  | chat                                                   |
| `SPC a k`  | ask about the region (recalls memories first)          |
| `SPC a r`  | rewrite the region                                     |
| `SPC a i`  | toggle ghost-text completion (TAB accepts)             |
| `SPC m r`  | remember text; `SPC m i` remember a file               |
| `SPC m s`  | recall by text, or by a file as an example             |
| `SPC i v`  | voice; `SPC i s` scan; `SPC i b` input sources         |
| `SPC e e`  | your habits; `SPC e a` agent proposals; `SPC e s` self.el |

**Memory** uses [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2)
(Apache 2.0, 740M parameters). It puts text, images, audio and video in
one 768-d space, so a sketch, a voice memo, a clip and a sentence about
them can find each other.
- The `sidecar` backend (`bin/exo-embed`, bf16) handles all four media.
  It's the default when uv is installed.
- The `ollama` backend handles text only and needs Ollama newer than 0.17.
- Offline, search falls back to keywords.

**The vault** is one directory that holds memory, chord stats, completion
feedback, settings and `self.el`. Choose it with `--vault DIR`,
`EXO_VAULT`, or `~/.config/exomachina/env`; the default is
`$XDG_DATA_HOME/exomachina/`. It isn't encrypted at rest yet.

### Headless, on another machine

The vault, models and agent live on the server; your laptop carries only
the terminal and, for voice, the microphone.

```sh
bin/exo-remote myserver setup --vault '~/vault'   # copy, write the server's env, check deps
bin/exo-remote myserver pull                      # models + memory weights (once)
bin/exo-remote myserver                           # attach (starts the daemon)
bin/exo-remote myserver voice                     # speak here, transcribe here, send text
bin/exo-remote myserver send pen gesture undo
bin/exo-remote myserver status | stop
```

- The daemon outlives your SSH session, so `C-x C-c` only closes your
  terminal.
- Sockets live in `~/.local/state/exomachina/run/` (0700).
- If logind kills your processes when you log out, run
  `loginctl enable-linger`.
- On clusters, pin one login node.

## Not built yet

- **Device drivers.** No pen, BCI or MIDI drivers ship yet. The socket
  and the scan mode are ready for them.
- **Verifying proposals.** The compile and test gate, the allowlist and
  automatic git history for agent proposals described above.
- **Encryption at rest** for the vault.
- **Non-speech sound.** Pure tones and other non-speech sounds embed
  weakly: a sine beep didn't match "a beep tone".

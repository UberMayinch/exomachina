# exomachina

Local-first jam partner for creatives. Open-weights model, running on a server
the artist controls, post-trained continuously on the artist's own context, so
it grows with them.

The artist's work is their creative property. It never leaves their vault
without consent and is never used to train anyone else's model.

## Thesis

- Musicians, painters and writers each need their own language for talking to
  the machine. Chat boxes aren't enough.
- The model should improve the longer you play with it, and it should stay yours.
- Privacy is the foundation the rest is built on.

## Roadmap

1. **Vault.** Encrypted storage built to be overkill, with post-quantum key
   exchange (ML-KEM) and keys held by the artist. Nothing is stored in plaintext
   on the server.
2. **Serve.** An open-weights model running on local or dedicated hardware,
   behind a jam-bot harness tuned for creative sessions.
3. **Grow.** Continual post-training on the artist's context (LoRA / adapter
   per artist), with eval gates so that growth doesn't mean drift.
4. **RLNF.** Feedback from creative sessions fed back into training.
5. **Interfaces.** Interaction modes native to each medium: music first, other
   media after. The first one is an Emacs distribution (below) with a
   modality-agnostic input model.
6. **Service.** The whole stack sold as a managed service, with the artist
   keeping their keys.

## The editor: exomachina as an Emacs distribution

The first interface is an Emacs distribution. It starts minimal and grows
with you.

- **Modal, vim by default.** It uses evil with evil-collection. `SPC` is the
  leader key in normal state, `C-c e` everywhere else, and which-key shows
  what each key does.
- **Input across modalities.** Every device is a *source* that emits events
  (`text`, `keys`, `command`, `gesture`) into one dispatcher.
  - Keyboard is native.
  - Voice is push-to-talk (`SPC i v`), transcribed locally by
    `emacs/bin/exo-transcribe` (faster-whisper, small.en). Say
    "computer save", "computer delete word", and so on, for commands.
  - Pen, BCI, MIDI and pedals connect through a Unix socket
    (`emacs/bin/exo-send`).
  - `exo-scan` walks the whole leader tree with just next/select/back, so
    one to three discrete signals (from a BCI classifier or a switch) are
    enough to drive everything.
- **Chords on screen.** The chord you just played shows in the mode line
  with a count of how often you've played it. Chords and progressions are
  counted locally. Typed text is never logged. Keys without a modifier only
  count in evil's normal, visual or motion state. isearch and the minibuffer
  are skipped entirely.
- **Agent next to you.** It runs on your local Ollama model through gptel:
  - chat
  - ask about the region, with the answer streamed inline below it
  - rewrite
  - ghost-text completion (TAB accepts)

  When you ask, it first recalls relevant memories. Thinking is off by
  default (`exo-agent-think`), because it is slow on small GPUs.
- **Memory: one space for every medium.** The encoder is
  [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) (Google,
  Oct 2026, Apache 2.0, 740M parameters). It maps text, images, audio and
  video into a single 768-d space, so a sketch, a voice memo, a clip and a
  sentence about them can all find each other.
  - The `sidecar` backend (`emacs/bin/exo-embed`, full weights in bf16) is
    the default when uv is installed. It handles all four media and starts
    on first use, so it uses no RAM or VRAM until you remember or recall
    something. Requests wait while it loads.
  - The `ollama` backend handles text only (Ollama 0.17 is too old; tested on
    0.40.16).
  - `SPC m i` remembers a file. Recall accepts text, or a file to search by
    example.
  - Everything is stored in `memory.jsonl` (0600). Offline, search falls
    back to keywords.
- **Evolves with you.**
  - `SPC e e` shows your habits and binds the commands you keep running
    from M-x.
  - Your changes live in `self.el`, outside the repo.
  - Each completion you accept goes to `feedback.jsonl`, along with up to 300
    characters of the text before it. This is the seed data for per-artist
    post-training. Buffers that look like secrets (`.env`, `authinfo`,
    `.gpg`, and similar) get no completions and are never logged. To turn
    logging off, set `exo-inline-record-feedback`.

```sh
emacs/bin/exomachina                 # GUI; -nw for terminal; --vault DIR; EXO_EMACS if not on PATH
ollama pull qwen3:8b                 # chat  (exo-agent-chat-model)
ollama pull qwen2.5-coder:1.5b       # inline FIM (exo-inline-model)
emacs/bin/exo-embed                  # optional pre-warm: first run fetches torch + weights (~4GB)
ollama pull embeddinggemma-2         # only for (setq exo-memory-backend 'ollama)
emacs/bin/exo-send bci gesture scan  # drive it from any device
```

**The vault.** Memory, chord stats, feedback, settings and your self layer
all live in one directory, owner-only and never in the repo. You choose
where it lives with `--vault DIR`, `EXO_VAULT`, or
`~/.config/exomachina/env`; the default is `$XDG_DATA_HOME/exomachina/`.
It isn't encrypted at rest yet; encryption arrives with roadmap step 1.

### Headless, on another machine

Run exomachina on a server so the vault, the models and the agent all
live there. Your laptop only carries the terminal, and the mic if you use
voice.

```sh
emacs/bin/exo-remote myserver setup --vault '~/vault'      # copy dist, write the server's env, check deps
emacs/bin/exo-remote myserver pull                          # on the server: models + memory weights (once)
emacs/bin/exo-remote myserver                               # attach (starts the headless daemon)
emacs/bin/exo-remote myserver voice                         # speak here, transcribed here, text sent there
emacs/bin/exo-remote myserver send pen gesture undo         # any device event
emacs/bin/exo-remote myserver status | stop
```

The daemon keeps running after you disconnect, so `C-x C-c` just closes
your terminal frame. On the server itself, `bin/exomachina start|attach|status|stop`
do the same. The server needs Emacs 29+, Ollama for the agent and uv for
memory. Set `EXO_EMACS` in its env file if Emacs isn't on PATH. If the
server's logind kills user processes at logout, run `loginctl enable-linger`.
Sockets live in `~/.local/state/exomachina/run/` (0700, one per machine
name), not in `$XDG_RUNTIME_DIR`, which disappears when your last SSH
session closes. On clusters, pin one login node (round-robin aliases
land you on another machine). Compute nodes only live as long as the
scheduler job.

Run the tests with:

```sh
cd emacs && emacs --batch -Q -L lisp -l test/exo-test.el -f ert-run-tests-batch-and-exit
```

**Not built yet:**
- Pen, BCI and MIDI need drivers that classify the raw signal and write to
  the socket. None ship yet.
- Pure tones and other non-speech sounds embed weakly. In tests a sine
  beep didn't match "a beep tone". Speech, images and video matched their
  descriptions.

## Layout

```
emacs/       the Emacs distribution (init.el, lisp/exo-*.el, bin/, test/)
site/        landing page + waitlist (Cloudflare Worker + D1)
```

## Site: local dev

```sh
cd site
npx wrangler d1 execute exomachina-waitlist --local --file=schema.sql
npx wrangler dev
```

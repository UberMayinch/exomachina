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
5. **Interfaces.** A standalone computing environment that anyone can use
   to extend their creativity on the fly, with interaction modes native to
   each medium: music first, other media after. Today it is a bootable
   Arch-based OS whose session is the Emacs-based environment (below).
   Next, the core becomes a service any frontend can use.
6. **Service.** The whole stack sold as a managed service, with the artist
   keeping their keys.

## The machine: exomachina OS

A minimal, Arch-based bootable image that starts straight into
exomachina, full screen, with your vault on its own disk. Build it and
try it in a VM:

```sh
os/build && os/run-vm
```

See [os/README.md](os/README.md).

## The environment: Lisp, today on Emacs

The first frontend is a Lisp environment you and a local agent keep
shaping together.
- **Homoiconic:** your input events, your adaptations and the agent's
  proposals are all Lisp data.
- **Performant:** models run in their own processes, so the editor never
  waits on one.
- **Verifiable:** every change is a form you can read and check before
  you keep it.

It uses modal editing across keyboard gestures, voice, pen and BCI.
See [emacs/README.md](emacs/README.md).

```sh
emacs/bin/exomachina pull && emacs/bin/exomachina
```

## Layout

```
os/          bootable Arch-based image (archiso profile, build, run-vm)
emacs/       the Emacs-based environment (init.el, lisp/exo-*.el, bin/, test/)
site/        landing page + waitlist (Cloudflare Worker + D1)
```

## Site: local dev

```sh
cd site
npx wrangler d1 execute exomachina-waitlist --local --file=schema.sql
npx wrangler dev
```

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
   media after.
6. **Service.** The whole stack sold as a managed service, with the artist
   keeping their keys.

## Layout

```
site/        landing page + waitlist (Cloudflare Worker + D1)
```

## Site: local dev

```sh
cd site
npx wrangler d1 execute exomachina-waitlist --local --file=schema.sql
npx wrangler dev
```

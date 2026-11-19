# exomachina OS: design

**Status: design only. Nothing in this document is implemented yet.**
Branch `exo` of a fork of GEOS (GNU/Emacs Operating System) by Borja
Tarraso. Upstream credit and history are kept; licence for new files
is an open question (see the end).

## What this is

A computing environment that evolves with the person using it. You
turn on a minimal host that holds two things: the open-weight models
you choose to run, and your vault. The host builds a VM from the
vault every boot, and that VM is your whole environment: agent,
editor, tools, extensions. Every layer of it, from Elisp commands down
to GPU kernels and, on open-firmware hardware, the firmware, can be
changed by you or by the agent, gated, kept, and rolled back.

It is designed for the hardware and models of the next few years, not
for today's laptop. The development machine (4 GB GPU, closed
firmware) is the floor the design must still work on, not the target.

The architecture follows Karpathy's "LLM OS" framing: the model is
the CPU, the context window is RAM, the vault is the disk, tools are
peripherals, and the agent runtime is the kernel that schedules them.

This doc ties into the exomachina roadmap:
- item 3 (grow, with eval gates so growth isn't drift),
- item 4 (RLNF, feedback from use),
- item 5 (interfaces).

## Decisions

### Made by the user

- **Base: Nix.** NixOS host and guest, defined by one flake. Not Guix.
- **GNU Hurd: dropped.**
- **Threat model: malicious extensions and remote attackers.** The
  weights you choose to run, and looking after your own machine, are
  your responsibility.
- **The agent is trusted.** It can do whatever it needs to extend
  the system.
- **Models for now:** a quantized qwen3:8b as planner, plus small
  models (SLMs) for routing and specific tasks.
- **Shape:** a minimal host plus a VM rebuilt from the vault every
  boot.
- **Runtime changes allowed, including kernels:** OS kernel, GPU
  driver, GPU compute kernels.
- **Autoresearch loops:** the agent may run them on its own execution
  stack.
- **Built for the future:** more compute and better distilled models,
  not this laptop.

### Proposed, not yet confirmed

| Proposal | Why |
|---|---|
| Elisp `system.el` DSL → JSON → `builtins.fromJSON` | Lisp all the way up for the user, Nix's types and cache underneath, no Nix code printer |
| systemd as init (GEOS `pid1/` dropped) | NixOS needs it; it gives the sandboxing extensions need |
| btrfs on LUKS2, disko, root wiped every boot | Only the vault and the store persist. Malware dies at reboot unless it gets promoted (see the trust boundary in contract 4) |
| cloud-hypervisor | VFIO, virtiofs, vsock, snapshots, small |
| Taint tracking on the bus | Main defence against injection from extensions and network content |
| Physical presence (FIDO2 touch) only for firmware signing and disk re-layout | The two actions rollback can't undo |
| Agent runtime (`exo-kernel`) in Rust | Long-running, concurrent, must not share Emacs's thread |
| Stable and experiment lanes for inference | The agent mustn't run on the kernels it's experimenting on |
| Frontier API allowed for the kernel-research lane only | Kernel code has no personal data. The user's call |

### Open

- Fold or retire exomachina's Arch-based `os/` image.
- Licence for new code and docs. GEOS code is GPLv3 and its docs are GFDL.
- Names: `exo-host`, `exo-env`, `exo-kernel`, `exo-vault` are working names.

## Architecture

```
┌─ exo-host: minimal NixOS, changes rarely ─────────────────────────┐
│  exo-vault     keys, memory, adapters, the flake, the audit log   │
│  weight store  base models by sha256, read-only                   │
│  hypervisor    cloud-hypervisor                                   │
│  watchdog      health checks, VM reset, auto-rollback             │
│  display       compositor + waypipe, or headless and remote       │
└──────┬───────────────────┬─────────────────────┬──────────────────┘
       │ vsock: vault API  │ virtiofs, read-only │ VFIO: accelerators
       ▼                   ▼                     ▼
┌─ exo-env: VM, rebuilt from the vault's flake every boot ──────────┐
│  exo-broker    the bus; authenticates every local caller          │
│  exo-kernel    agent runtime: roles, scheduler, tools, taint      │
│  inference     engines serving model roles; stable and experiment │
│                lanes                                              │
│  frontends     Emacs (one client of many), voice, terminal        │
│  extensions    each in its own systemd sandbox, per its manifest  │
└───────────────────────────────────────────────────────────────────┘
```

### Boot

1. The host boots and the user unseals the vault (see Vault).
2. The host reads the current **generation** from the vault, builds
   (or fetches from cache) that generation's `exo-env`, and starts it.
3. The guest connects to the vault over vsock, and its broker starts
   the agent, the frontends and the extensions.
4. **Recovery:** if the vault stays sealed, the host can boot a stock
   `exo-env` that has no vault access.

### Where state lives

| Thing | Where | Persistent? |
|---|---|---|
| Keys, memory records, embeddings, chord stats, feedback, `self.el` | vault | yes, the only real state |
| The flake and its lock, the model roster, promoted kernel artifacts | vault | yes, versioned as generations |
| Fine-tuned LoRA adapters, distilled task models | vault (blobs) | yes, because they are personal |
| Base model weights | host weight store, by sha256 | re-fetchable, so not state |
| Guest root, `/home` scratch, unpromoted experiments | guest | gone at the next boot |
| Host root | host | wiped every boot, rebuilt from the host flake |

A machine is `flake.lock` + vault. Restoring the vault onto any
hardware, then installing from the flake, gives you back your
environment.

### Runtime change vs. promotion

The running guest is a REPL and the vault is the saved file.
- **Live changes are always allowed:**
  - sysctl
  - loading kernel modules
  - swapping the inference engine or a GPU kernel
  - rebinding a key
- **Unpromoted changes vanish** at the next boot.
- **Promotion goes through the evolution protocol** (contract 4),
  which writes a new generation to the vault.

How each kind of change is tested:
- **OS kernel changes:** blue/green. Boot a second guest with the
  candidate kernel, run the gates, switch. An accelerator passed
  through can only belong to one VM at a time, so tests that need
  the accelerator run in the active VM.
- **GPU compute kernels:** these are userspace code (`.cu`, Triton,
  PTX), so they swap without a reboot.

## The five contracts

The contracts are the parts meant to outlast any hardware, model or
frontend. Everything behind them can be replaced.

Shared rules for all five:
- **Wire format:** JSON on the wire, one object per line. Emacs shows
  the same objects as plists.
- **Versioning:** every connection opens with `hello`, which carries
  a major version. A major mismatch is refused. Minor additions must
  be ignorable.
- **Errors:** every reply is either `{"ok": …}` or
  `{"err": {"code": …, "msg": …}}`. Codes are listed per contract.

### 1. Vault API

**Transport:**
- The host serves vsock port 7000, guest side.
- The hypervisor assigns the guest's vsock CID, and the host trusts
  that CID as the caller's identity. A guest can't forge it.

**Two layers of authorisation:**
- **Host ceiling.** The vault gives each VM a maximum scope. The
  `exo-env` VM gets its user's vault, minus `keys/*`, which never
  leave the host.
- **Guest subdivision.** `exo-broker` gives each guest principal
  (agent, Emacs, each extension) a narrower handle.
- **Generations are host-only.** The guest may read the flake and
  generations but never write them. See "Promotion trust boundary"
  in contract 4.

A compromised guest kernel can impersonate any guest principal.
That's why the host ceiling is the real boundary, and why key
material is never sent to the guest at all.

**Verbs:**
```json
{"v":1,"id":1,"verb":"hello","body":{"major":1}}
{"v":1,"id":2,"verb":"open","body":{"scope":"memory/music/*","mode":"rw","ttl":3600}}
  → {"ok":{"handle":"h_7f…","expires":…}}
{"v":1,"id":3,"verb":"put","body":{"handle":"h_7f…","key":"memory/music/2026-11-15-a",
   "value":{…},"if_version":4}}
{"v":1,"id":4,"verb":"get","body":{"handle":"h_7f…","key":"…"}}
{"v":1,"id":5,"verb":"query","body":{"handle":"h_7f…","embedding":[…],"k":8}}
{"v":1,"id":6,"verb":"blob.put","body":{"handle":"…","sha256":"…","size":…}}  then stream
{"v":1,"id":7,"verb":"sign","body":{"handle":"…","key":"keys/firmware","digest":"…"}}
{"v":1,"id":8,"verb":"generation.current"}
{"v":1,"id":9,"verb":"audit.tail","body":{"n":100}}
```

**Semantics:**
- **Every write is compare-and-swap** (`if_version`). A failed CAS
  returns `conflict` with the current version.
- **`query`** searches embeddings only inside the handle's scope. The
  index is encrypted with the records.
- **`sign` runs on the host** and never returns key material. The
  ceiling stops the guest from *reading* `keys/*`, not from asking
  for a signature. Keys under `keys/firmware`
  and `keys/disk` return `presence-required` until the user touches
  the hardware key (proposed).
- **Every call is appended to the audit log**, which lives in the
  vault and is hash-chained.

**Error codes:**

| Code | Meaning |
|---|---|
| `denied` | the caller's scope doesn't allow this |
| `not-found` | no such key |
| `conflict` | CAS failed |
| `sealed` | the vault is locked |
| `presence-required` | needs a hardware-key touch |
| `expired` | the handle's TTL has run out |
| `unavailable` | the vault can't be reached |

**At-rest crypto (proposed; verify before building):**
- **Records:** each record is encrypted with its own data key
  (XChaCha20-Poly1305). Data keys are wrapped by the vault master key.
- **Master-key recipients:**
  - a FIDO2 hmac-secret key (primary)
  - a passphrase, stretched with argon2id (fallback)
  - TPM2 (convenience only)
  - a recovery key: a hybrid of ML-KEM-768 and X25519, for backups and
    for moving to new hardware
- **Why the post-quantum part:** it matters only where public-key
  wrapping protects data that leaves the machine, such as backups.
  Those are open to harvest-now-decrypt-later. The symmetric parts
  are 256-bit already.
- **The TPM is never the only recipient.** fwupd flags TPM firmware
  updates `affects-fde`, and such an update would lock the vault.

### 2. Bus protocol

**Transport:**
- **Inside the guest:** `exo-broker` listens on a Unix socket and reads
  each caller's uid with `SO_PEERCRED`. Each extension runs as its own
  uid (systemd `DynamicUser`), so uid → principal is unambiguous.
- **Vault calls** are proxied by the broker to the host over vsock.

**Envelope:**
```json
{"v":1,"id":42,"from":"ext:tidal","to":"agent","verb":"call",
 "method":"agent.ask","body":{…},"taint":["ext:tidal","net:example.org"]}
```

**Envelope rules:**
- **`from` is set by the broker, never by the caller.** A caller that
  supplies its own `from` is overwritten.
- **`verb`** is one of `hello`, `call`, `reply`, `emit` (event),
  `subscribe`, `unsubscribe`.
- **`taint`** is the set of untrusted origins this message's content
  came from. The broker adds the caller's own origin. Taint is never
  removed by forwarding.

**Namespaces:**

| Namespace | What lives there |
|---|---|
| `agent.*` | ask, plan, act, cancel |
| `vault.*` | contract 1, proxied |
| `input.*` | modality events, replacing today's `exo-bridge` socket. Plist shape unchanged: `(:modality pen :kind gesture :value "circle")` |
| `sys.*` | process, journal, service, network, disk and package snapshots for GEOS's system buffers; actions through systemd and NixOS |
| `models.*` | roster, load, unload, infer (contract 3) |
| `evolve.*` | proposals and generations (contract 4) |

**Taint policy (proposed):**
- **Escalation rule:** an action that is *exfil-capable* (network
  egress that carries data), taken by a principal whose current
  context is tainted and which has read vault scopes this session,
  goes to the user to confirm.
- **Everything else** the agent does without asking.
- **Taint origins:** extension output and network content are
  untrusted. The user and the agent's own reasoning are trusted.

**Errors:**

| Code | Meaning |
|---|---|
| `denied` | not allowed for this principal |
| `no-such-method` | unknown method |
| `timeout` | every call has a deadline. The broker enforces it, so a stuck callee can't stall callers. This is the lesson of GEOS's single thread |
| `confirm-pending` | waiting on the user (taint policy) |
| `unavailable` | the target isn't running |

### 3. Model role registry

**Roles, not model names.** Callers ask for a role, and the registry
resolves it to a concrete model for the current hardware.

```elisp
(models
 (router    :sha256 "…" :format gguf :quant q4_k_m :ctx 8192)
 (planner   :sha256 "…" :format gguf :quant q4_k_m :ctx 32768)
 (embedder  :sha256 "…" :modalities (text image audio video))
 (speech    :sha256 "…")
 (kernel-researcher :sha256 "…" :fallback (:api frontier :scope code-only))
 (task/chord-namer  :base planner :adapter "vault:blob/…" :distilled-from "traces/chords"))
```

**Each entry carries:**
- **Requirements:** minimum accelerator memory, context length, supported engines.
- **Eval scores:** from the last promotion.
- **Lineage:** the base model, adapter and distillation trace for derived roles.

**How a role is resolved:**
- **Capability profile.** The host probes the hardware at boot:
  accelerators, memory and interconnect, whatever the vendor. It
  passes the result to the guest as `capabilities.json`.
- **Resolution** = role + capability profile → a model, an engine, a
  placement (which accelerator, or CPU), and a lane.
- **Tiers.** On the 4 GB floor, the planner is split between GPU and
  CPU and the two lanes share the GPU in turns. On larger hardware
  both lanes run at once. The roster doesn't change.

**Self-distillation (how new roles appear):**
1. The agent sees a recurring task.
2. The planner's traces for it are stored in the vault as training data.
3. A task model is distilled from those traces.
4. Autoresearch tunes its kernels.
5. A `models` proposal adds the role.
6. The router learns to send that task to it.

All of this goes through contract 4.

**Errors:**

| Code | Meaning |
|---|---|
| `no-fit` | no model for this role fits this hardware |
| `missing-weights` | the sha256 isn't in the store, so fetch it |
| `lane-busy` | the lane is in use |

### 4. Evolution protocol

One protocol for every layer: propose → sandbox → gate → promote →
observe → (rollback).

```elisp
(proposal
 :id "p-2026-11-15-0042"
 :layer system                    ; interface | system | model | compute | firmware
 :author agent                    ; user | agent | ext:<name>
 :parent-generation 118
 :change (:flake-patch "…")       ; layer-specific payload
 :rationale "…"
 :taint ()                        ; inherited from the context that wrote it
 :gates (boots health no-regress))
```

**States:** `proposed → sandboxed → gated → promoted → observing → kept`.
A proposal can also end as `rejected` or `rolled-back`.

**Generation.** Promotion writes one atomic record to the vault: a new
**generation**. It is a tuple:
- the flake revision
- the model-roster revision
- the `self.el` revision
- the set of compute artifacts

Rolling back means picking an earlier generation, so every layer goes
back together and stays consistent.

**Per layer:**

| Layer | Sandbox | Gates | Default approval |
|---|---|---|---|
| interface (Elisp, `self.el`) | evaluate in a throwaway Emacs | loads, tests pass | user accepts (as `exo-evolve` does today) |
| system (flake) | build, then boot a blue VM | boots, health checks, no service regressions | automatic if gates pass |
| model (roster, adapters, distilled roles) | load in the experiment lane | your eval set, no regression on held-out tasks, RLNF scores | automatic if gates pass |
| compute (GPU kernels, quantisation, offload, scheduling) | experiment lane | output matches the reference within tolerance, tokens agree on the eval set, then a benchmark with a fixed budget (tokens/s, latency, memory, watts) | automatic if gates pass |
| firmware (open-firmware hardware only) | build reproducibly, then flash the inactive A/B slot | slot boots, signed with your vault key | physical presence |
| disk layout | replicate the vault, verify the copy | restore verified | physical presence |

**Promotion trust boundary.** Inside the guest, a hijacked agent, a
compromised guest kernel, or an extension with root all look exactly
like the agent from the host's side. Taint is assigned in the guest,
so it can be stripped there. If the guest could write generations,
anyone who compromised it could promote their own persistence.
Therefore:
- **The guest can only propose.** It gets `evolve.propose`, plus
  read access to generations and the flake. Writing a generation is
  host-only. The guest's vault ceiling excludes write access to the
  `system/flake` and `system/generations` scopes.
- **The host runs the gates for the system layer itself.** It
  evaluates and builds the candidate in a sandboxed builder (pure
  flake evaluation, ideally in a separate builder VM), and boots the
  blue VM. Guest-authored Nix is never evaluated with host
  privileges.
- **The guest can never change the host flake.**
- **What this guarantees, honestly:**
  - Unpromoted changes die at the next boot.
  - Promoted changes may carry an attacker's change, but each one is
    diffed into the hash-chained audit log.
  - Any promoted change can be rolled back.
  - The user can pin a known-good generation that later promotions
    can't replace without physical presence.

Guest-side gates (interface, model, compute) still run in the guest
for speed. The host re-checks their results only where it can do so
cheaply, such as artifact hashes and reproducible builds.

**Override rules:**
- **Taint:** any proposal with non-empty `taint` needs the user to
  accept it, whatever its layer's default.
- **Observing:** after promotion, the watchdog compares health and
  eval metrics for a set window. If they regress, it rolls back on
  its own.

**The autoresearch loop** drives this protocol for the compute and
model layers:
```
propose → compile → correctness gate → benchmark → keep or revert → log
```
- It runs unattended, under a time and energy budget.
- The agent's own reasoning stays on the stable lane while candidates
  run on the experiment lane.

### 5. Capability manifest

Extensions and the agent's tools use the same manifest format:
```json
{"name":"tidal","version":"0.1.0","source":"github:someone/exo-tidal?rev=…",
 "caps":{
   "fs":{"read":["~/music"],"write":["~/music/renders"]},
   "net":{"egress":[]},
   "vault":{"read":["music/*"],"write":[]},
   "bus":{"call":["agent.ask"],"emit":["input.*"],"subscribe":[]},
   "devices":["midi"],
   "accel":false}}
```

**Enforcement.** A NixOS module turns the manifest into a systemd unit:

| Manifest field | systemd setting |
|---|---|
| (always) | `DynamicUser`, `ProtectSystem=strict` |
| `fs` | `BindReadOnlyPaths` / `BindPaths` |
| `net` | `PrivateNetwork`, or `IPAddressAllow` for an allowlist |
| `devices` | `DeviceAllow` |
| (always) | `SystemCallFilter` |
| `vault`, `bus` | the broker issues handles for exactly these and nothing more |

**Defaults:**
- Anything left out of the manifest is denied.
- Everything an extension emits carries its taint.

**Upgrades.** An upgrade that widens `caps` is itself an interface-layer
proposal, so the user sees the widening.

**Errors:** `denied` (a call outside the manifest; it's logged and
counted). A count above threshold → the broker suspends the extension.

## What carries over

**From GEOS (this repo):**
- `emacs-init/buffers/`: processes, journal, services, network,
  disks, packages, users, audio. They become `sys.*` bus clients,
  backed by systemd, journald and NixOS instead of pid1 RPC.
- `emacs-init/buffers/install.el` and `emacs-init/install/`: rewritten
  around disko and `nixos-install`.
- `emacs-init/core/panic.el`: the error trap stays.
- `emacs-init/core/state.el`: the crash-safe write pattern, for
  frontend-local state.
- `emacs-init/core/rpc-server.el` and `rpc-client.el`: the
  peer-cred-gated socket design generalises into `exo-broker`.
- `emacs-init/core/session.el` and `buffers/login.el`: reviewed for
  multi-user later.

**Dropped:**
- `pid1/` and `shstub/` (systemd replaces them).
- `guix-system/` and the Guix-based `iso-build/`.
- `install/hurd-bootstrap.sh`, `services/hurd-essentials.el`, and the
  Linux/Hurd seam in `core/port.el`.
- `user/exwm-config.el`: X11 only, replaced by a Wayland compositor.

**From exomachina `emacs/`:**
- `lisp/exo-*.el`, all of it. Emacs becomes one frontend.
- `exo-bridge.el` → an `input.*` bus client. The plist event shape is unchanged.
- `exo-evolve.el` + `self.el` → the interface layer of contract 4.
- `exo-memory.el` → vault records + the `embedder` role.
- `bin/exo-embed` → serves the `embedder` role.
- `bin/exo-transcribe` → serves the `speech` role.
- `bin/exomachina` headless mode and `bin/exo-remote` → env placement
  on a remote host, with the vault staying local.

**Design rule kept from both:** nothing heavy runs on Emacs's thread.
Here it is enforced structurally. The agent, inference and vault are
separate processes, and every bus call has a deadline. A frozen Emacs
loses one frontend, not the machine.

## Repository layout (target)

```
flake.nix            host + env + modules, one lock
host/                exo-host NixOS config (hypervisor, vault, watchdog)
env/                 exo-env guest config
modules/             exo-*.nix: system DSL, extensions, roles, firmware
vault/               exo-vault daemon
kernel/              exo-kernel agent runtime + exo-broker
emacs/               the Emacs frontend
docs/
```

## Milestones

1. **M1 skeleton.**
   - Flake, `exo-host` and `exo-env` running under QEMU, no accelerator.
   - Vault stub, **plaintext and labelled as such**.
   - The evolution loop end to end on a sysctl: the agent proposes, a
     blue VM boots, the gates pass, a generation is written, the next
     boot includes it, and rollback works.
2. **M2 frontend.** `exo-broker`, the Emacs frontend in the guest, and
   `input.*`/`sys.*`.
3. **M3 vault.** Real crypto and the unseal flow. Audit log.
4. **M4 roles.** Model registry, router and planner on CPU, capability profile.
5. **M5 accelerators.** VFIO passthrough, stable and experiment lanes.
6. **M6 autoresearch.** Compute-layer loop with correctness and benchmark gates.
7. **M7 distillation.** Task roles from traces, model-layer gates with RLNF.
8. **M8 firmware.** Open-firmware hardware: reproducible build, A/B
   slots, signing key held in the vault.

## Verify before building

These are recalled, not checked. Each needs confirming before the
design depends on it:
- age's post-quantum hybrid (ML-KEM-768 + X25519) recipients: status,
  version, and whether they fit the vault's wrapping design.
- microvm.nix with cloud-hypervisor: VFIO passthrough of a GPU,
  virtiofs and vsock together. Laptop dGPU quirks: reset (FLR), and
  whether the vBIOS needs extracting from ACPI.
- systemd `LoadCredentialEncrypted` / `systemd-creds` sealed to TPM2,
  as a convenience unlock on the host.
- Karpathy's "autoresearch": the name and the shape of the loop this
  borrows from.
- NovaCustom laptops shipping Dasharo with RTX GPUs. Which models
  support vboot-style A/B slots.
- Spectrum OS: that it uses cloud-hypervisor. Worth reading as prior
  art either way.
- Whether disko can apply changes incrementally, or only formats.
- Isolating Nix evaluation and builds when the flake input is
  untrusted (guest-authored), so a malicious proposal can't run code
  on the host.

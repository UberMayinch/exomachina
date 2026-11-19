# exomachina OS

A bootable, Arch-based machine that starts straight into exomachina: no
desktop, no app launcher, just the environment, the agent and your
vault. This is the first step from "a config for an editor" to a
standalone computer anyone can pick up and shape.

This first version is deliberately small. It is Arch's `baseline`
archiso profile plus:
- **`cage`**, a kiosk compositor that shows one app full screen.
- **The current exomachina environment** (Emacs, pgtk), with its packages
  baked in.
- **Ollama and uv**, for the agent, memory and voice.

You log in automatically as `exo` on tty1. The other ttys
(Ctrl+Alt+F2…) are plain shells.

## Build

Needs Docker; works from any Linux distribution.

```sh
os/build          # -> os/out/exomachina-YYYY.MM.DD-x86_64.iso
```

`build` runs `mkarchiso` in an `archlinux` container. The container
runs `--privileged` because mkarchiso mounts `/proc` and `/sys` inside
the image it builds.

## Run in a VM

```sh
os/run-vm                       # QEMU/KVM, 8G RAM, 4 CPUs, GTK window
EXO_VM_MEM=12G os/run-vm        # more room for the 8B chat model
```

`run-vm` creates `os/out/data.img` (sparse 64G, ext4, label
`EXO_DATA`) the first time it runs.

## Your data

Everything you make lives on a disk labelled `EXO_DATA`, mounted at
`/var/lib/exomachina`:
- `vault/` holds memory, chord stats, feedback, settings and `self.el`.
- `ollama/` holds the models.
- `cache/` holds the Python and Hugging Face caches.

On the first boot with that disk, the models download in the background
(log: `pull.log`). The editor is usable straight away, and the agent
comes online when the download finishes. Without an `EXO_DATA` disk the
session runs from RAM, forgets everything at shutdown and skips the
download.

On real hardware, make an ext4 partition labelled `EXO_DATA` that uid
1000 owns:
```sh
mkfs.ext4 -L EXO_DATA -E root_owner=1000:1000 /dev/XXX
```

## Not yet

- **Untested boot.** The VM boot has not been run end to end. The first
  real boot is the test.
- **No installer.** It is a live ISO plus a data disk.
- **No GPU drivers.** Models run on the CPU in a VM, which is slow:
  expect seconds per reply from `qwen3:8b`.
- **No Wi-Fi tools.** Only wired DHCP is set up (systemd-networkd).
- **No sudo.** `exo` has no admin rights in the live session.
- **The frontend is still Emacs.** Next: pull the core (input events,
  memory, agent, self layer) out into a service, so the session can run
  a frontend that anyone can use without knowing Emacs. Emacs stays as
  one frontend.

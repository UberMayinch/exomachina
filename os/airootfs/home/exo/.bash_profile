# tty1 is the exomachina session; other ttys (Ctrl+Alt+F2) are plain shells.
if [ "$(tty)" = /dev/tty1 ] && [ -z "$WAYLAND_DISPLAY" ]; then
  exomachina-session || echo "exomachina-session exited ($?); run it again with: exomachina-session"
fi

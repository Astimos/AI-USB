# AI-USB rescue: start the session once per boot, on tty1 only.
[ -f ~/.bashrc ] && . ~/.bashrc
if [ "$(tty)" = "/dev/tty1" ] && [ ! -e /run/aiusb-started ]; then
    : > /run/aiusb-started
    exec /usr/local/sbin/aiusb-boot
fi

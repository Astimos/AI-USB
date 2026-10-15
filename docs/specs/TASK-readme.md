# Task: write `payload/README.txt` (the user guide on the stick)

Plain text (no markdown syntax beyond simple underlined headings with ===/---), max 100 columns,
CRLF-safe (just plain lines), ASCII only. 150-250 lines. Friendly, short sentences.
Audience: the stick's owner, technically comfortable but in a hurry because a PC is broken.

Sections:
1. What this stick does (two features, see ARCHITECTURE §1) and the agents on it
   (Claude Code, Claude Code on GLM via z.ai, OpenAI Codex, Google Gemini CLI).
2. First-time setup (on any working Windows or Linux PC): run the launcher, choose a passphrase
   (letters/digits/spaces only so it types the same on every keyboard), then sign in to each
   agent once: Claude (option 1 opens the login), Codex (K → 3), Gemini (API key via K → 2, or
   Google sign-in inside Gemini; Google sign-in must be redone on each new computer), GLM
   (K → 1, paste the z.ai API key).
3. Using it on Windows: open the AIUSB drive, double-click "Start AI Agent.cmd", accept the
   administrator prompt (needed so the agents can work across the whole PC), type the passphrase,
   pick an agent. Q saves and locks. Windows does not allow programs to start by themselves when
   a USB stick is plugged in, so the double-click is required.
4. Using it on Linux: `bash /path/to/AIUSB/start-ai-agent.sh` (or double-click if your file manager
   allows running scripts). It asks for sudo for full access.
5. Rescue boot (when Windows will not start): plug in, power on, open the boot menu (common keys:
   Dell/Lenovo F12, HP F9 or Esc, ASUS F8 or Esc, Acer F12, MSI F11, Gigabyte F12, Surface: hold
   Volume Down while powering on), choose the USB/UEFI entry. Secure Boot can stay on. Pick the
   keyboard layout, connect to Wi-Fi if asked, enter the BitLocker recovery key if the disk is
   encrypted (find it at https://aka.ms/myrecoverykey), type the passphrase, pick an agent and
   describe the problem. Boot menu options: normal, safe graphics (if the screen stays black),
   load into RAM. If the menu shows "Secure Boot violation" or similar, the PC's firmware is too old
   for this signed loader: temporarily disable Secure Boot (BitLocker will then ask for the
   recovery key once).
6. Where your logins are: only on this stick, encrypted with your passphrase. While a session is
   open they are unlocked in RAM (Linux/rescue) or in a session folder on the stick (Windows),
   never on the PC's disk. Pressing Q, closing normally, or pulling the stick ends the session;
   pulling the stick stops the agents immediately. If a Windows session was cut off, the next start
   cleans it up and re-locks it.
7. If you lose the stick: sign out its sessions: claude.ai Settings (log out of all sessions),
   ChatGPT Settings > Security (log out of all devices), Google Account > Security > third-party
   access (Gemini CLI), delete the z.ai API key and the Gemini API key in their consoles.
   Then on a fresh stick set things up again.
8. Safety: the agents ask before changing things unless Autonomous mode (A) is ON. Keep it OFF
   unless you are watching. Reports and backups are saved on the stick in aiusb\workspace and
   aiusb\backups.
9. Troubleshooting: forgot passphrase (K → 6 resets the vault; sign in again); "another session may
   be open" (answer y if you know it is not); Linux says permission denied (run with bash ...);
   rescue screen black (choose safe graphics); no Wi-Fi in rescue (use Ethernet or a phone's USB
   tethering).
10. Files on the stick (short map of ARCHITECTURE §3).

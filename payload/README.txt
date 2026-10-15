================================================================================
                             AI-USB  -  USER GUIDE
================================================================================

WHAT THIS STICK DOES
--------------------

This stick turns one USB drive into a repair kit and an AI workbench. It has
two features:

1. Rescue boot. If a PC's Windows will not start, boot the PC from this stick.
   A small Debian Linux system starts, helps you get online, and can unlock
   and mount the Windows disks. It then opens a menu of AI coding agents that
   run with full rights and can diagnose and repair Windows.

2. Plug-in launcher. On a PC that already works, open the stick and run
   "Start AI Agent.cmd" (Windows) or "start-ai-agent.sh" (Linux). The same
   menu opens with the same signed-in agents. They run with administrator
   or root rights and can work on every drive of the PC.

The agents on the stick:

  1) Claude Code            Anthropic's agent; sign in once with claude.ai.
  2) Claude Code on GLM     the same agent on z.ai models; needs a z.ai key.
  3) Codex (OpenAI)         OpenAI's agent; sign in with ChatGPT.
  4) Antigravity (Google)   Google's agent (Antigravity CLI); Google sign-in.

Windows never runs programs from a USB stick by itself, so the double-click
(or the command on Linux) is always required. That is a Windows rule, not a
fault of the stick.

FIRST-TIME SETUP
----------------

Do this once, on any working Windows or Linux PC. It takes a few minutes.

1. Run the launcher (see the next two sections for how).

2. You are asked to create a passphrase. It protects every login stored on
   the stick. Use letters, digits and spaces only, so it types the same on
   every keyboard layout. It cannot be recovered or reset without erasing
   the logins, so pick something you will remember.

3. Sign in to each agent you plan to use. From the main menu:

   Claude Code
       Choose 1. Claude starts its own login flow; open the link it prints
       and approve it in your browser.

   Codex (OpenAI)
       Press K, then 2 (Sign in to Codex), and follow the prompt.

   Antigravity (Google)
       Choose 4 and pick "Google OAuth". It prints a sign-in link: open it
       in a browser (Ctrl+click works in most terminals), sign in with your
       Google account, copy the code it shows and paste it back. The login
       is kept in the vault on the stick, never on the PC.

   Claude Code on GLM
       Press K, then 1 (Set z.ai key), and paste your z.ai API key.

4. Press Q to save and lock, then unplug the stick.

Everything you signed in to is stored encrypted on the stick. On the next
PC you only need the passphrase.

USING IT ON WINDOWS
-------------------

1. Plug in the stick and open the "AIUSB" drive in File Explorer.
2. Double-click "Start AI Agent.cmd".
3. Choose the language (1 English, 2 Slovencina; Enter keeps the last one).
4. Accept the administrator prompt (UAC). The agents need it to work across
   the whole PC. If you decline, they still run but cannot change system
   settings.
5. Type your passphrase.
6. Pick an agent and describe what you want.

Press Q to save and quit. The session is locked back into the vault and
nothing is left on the PC. H in the menu explains how everything works,
L switches the language.

The first start on a PC takes a little longer: Windows checks the programs
on the stick, and the launcher prepares a small helper once (it is kept on
the stick for every later start).

USING IT ON LINUX
-----------------

Open a terminal and run:

    bash /path/to/AIUSB/start-ai-agent.sh

Adjust the path to where the stick is mounted. With many file managers a
double-click on the script works too. The launcher asks whether to give the
agents root access; answer Y and enter your sudo password for full access,
or N to run with your normal permissions.

RESCUE BOOT (WHEN WINDOWS WILL NOT START)
-----------------------------------------

1. Plug the stick into the broken PC and power it on.
2. Open the firmware boot menu. Common keys:

     Dell, Lenovo        F12
     HP                  F9 or Esc
     ASUS                F8 or Esc
     Acer                F12
     MSI                 F11
     Gigabyte            F12
     Surface             hold Volume Down while powering on

3. Choose the USB stick. The menu shows its hardware name, often
   "UEFI: Kingston DataTraveler 3.0" or "USB HDD". Secure Boot can stay ON.
4. Pick your keyboard layout when asked.
5. Connect to Wi-Fi if asked, or use an Ethernet cable.
6. If the Windows disk is BitLocker-encrypted, enter the 48-digit recovery
   key. You can look it up at https://aka.ms/myrecoverykey (sign in with the
   Microsoft account of the PC's owner).
7. Answer Y to mount the Windows disks so the agents can repair them.
8. Type your passphrase, pick an agent, and describe the problem in plain
   words.

The stick's boot menu offers:

  - Normal start (default).
  - Safe graphics - use this if the screen stays black.
  - Load into RAM - copies the rescue system into memory before starting.

If the boot menu shows "Secure Boot violation" or something similar, the
PC's firmware is too old for this signed loader. Temporarily turn Secure
Boot off in the firmware settings and boot again. BitLocker will ask for
the recovery key once after that change.

INSTALLING WINDOWS 11 ON ANOTHER PC (OPTIONAL)
----------------------------------------------

Only on a stick that has the Windows installer added to it (with
scripts/add-win-installer.sh on the build PC): its boot menu then shows
"Install Windows 11 (Microsoft setup)". It is Microsoft's own installer,
unchanged, and works on PCs with UEFI firmware, which means any PC made for
Windows 8 or newer.

1. Back up anything you want to keep from that PC. Installing Windows
   erases the disk you choose.
2. Plug in the stick, power on and open the firmware boot menu (keys in
   the table above). Choose the USB stick (the "UEFI: ..." entry).
3. In the stick's menu choose "Install Windows 11 (Microsoft setup)".
4. Windows Setup starts. Pick the language and keyboard, then install.
   Without a product key choose "I don't have a product key": a PC that
   already had Windows 10 or 11 activates by itself once it is online.
5. When Setup asks where to install Windows, choose the PC's internal
   disk. The stick shows up as two partitions: AIUSB (about 223 GB) and an
   8 GB system partition. Never delete or format those.
6. When the PC restarts for the first time, remove the stick. Setup
   continues from the internal disk. (If the stick's menu still appears,
   choose "Start Windows instead".)

Your logins on the stick are not affected.

Setup checks for TPM 2.0, Secure Boot and a supported processor. On an
older PC it stops with "This PC can't run Windows 11".

If Setup says it cannot find the installation files (for example "A media
driver your computer needs is missing"), press Shift+F10, type
D:\sources\setup.exe and press Enter. If D: is not the stick, try E:, F:
and so on.

CONTINUING A CONVERSATION
-------------------------

Your conversations with the agents are saved in the vault too, encrypted
like the logins, on every PC and in every mode. To continue one, possibly
on another PC:

  - Press R in the menu, then the agent (1-4), then pick the conversation.
  - Inside Claude Code and Antigravity, typing /resume works as well.

Each agent's conversations are opened only when you start that agent, so
unlocking stays quick. Claude Code deletes conversations older than 30
days by itself; Codex and Antigravity keep them.

WHERE YOUR LOGINS ARE
---------------------

Your logins live only on this stick, encrypted with your passphrase.
Nothing secret is stored on the PCs you use.

While a session is open, the logins are unlocked in RAM only (Linux and
rescue boot) or in a session folder on the stick itself (Windows) - never
on the PC's hard disk.

Pressing Q, closing the program normally, or pulling the stick out all end
the session. Pulling the stick out stops the agents immediately. If a
Windows session was cut off by a crash or unplug, the next start cleans it
up and re-locks it into the vault.

IF YOU LOSE THE STICK
---------------------

The passphrase protects the logins, but treat them as exposed and sign them
out:

  - claude.ai: Settings -> log out of all sessions.
  - ChatGPT: Settings -> Security -> log out of all devices.
  - Google Account: Security -> third-party access -> remove Antigravity.
  - z.ai console: delete the z.ai API key you pasted during setup.

Then build a fresh stick and run the first-time setup again.

SAFETY
------

By default the agents ask before they change anything. Autonomous mode
(menu key A) switches those questions off. Keep it OFF unless you are
watching what the agent does.

Reports the agents write are kept on the stick in aiusb\workspace, and
backups made in rescue mode (registry, boot configuration) in aiusb\backups.
On Linux the same folders are aiusb/workspace and aiusb/backups.

TROUBLESHOOTING
---------------

Forgot the passphrase
    Press K, then 5 (Reset vault). This erases all logins on the stick and
    returns it to first-time setup. There is no way to recover a forgotten
    passphrase.

"The last session (on ...) was not closed; cleaning it up."
    Normal after pulling the stick out or a crash. Every start is a clean new
    session on any PC or system; logins from the unfinished session are saved
    first. Nothing to do.

"AISTiUSB is already open in another window on this PC"
    The launcher is already running on this PC. Use that window, or close it
    (Q) and start again.

Linux says "Permission denied" when starting
    Start it with bash explicitly:

        bash /path/to/AIUSB/start-ai-agent.sh

Windows offers to "format" the stick
    Never accept. Sticks made since October 2026 use a layout that every
    Windows version opens; an older stick can be converted without losing
    anything with scripts/convert-to-mbr.sh (see docs/HANDOFF.md).

Rescue screen stays black after boot
    Reboot and choose "safe graphics" in the stick's boot menu.

No Wi-Fi in rescue mode
    Use an Ethernet cable, or plug in a phone and switch on USB tethering.

FILES ON THE STICK
------------------

Windows-style paths are shown; on Linux use "/" instead of "\".
Each system shows only what it needs: Windows shows "Start AI Agent.cmd"
and this README (after the first start), Linux shows "start-ai-agent.sh"
and this README. The rest is hidden, not gone: in Windows Explorer use
View > Show > Hidden items, in Linux file managers press Ctrl+H.

Start AI Agent.cmd      Windows launcher (double-click this).
start-ai-agent.sh       Linux launcher entry.
README.txt              this guide.
aiusb\VERSION           build id of the software on the stick.
aiusb\aiusb.conf        non-secret settings.
aiusb\launcher\         the launcher programs (launcher.ps1, launcher.sh).
aiusb\context\          instructions the agents read in each mode.
aiusb\rescue\           scripts used by the rescue system.
aiusb\bin\              agent programs for linux-x64 and win-x64 (claude,
                        codex, agy = Antigravity CLI) and age.
aiusb\vault\            your encrypted logins (identity.age, home.tar.age,
                        plus a backup copy).
aiusb\session\          decrypted logins during a Windows session only;
                        removed automatically when the session ends.
aiusb\workspace\        agent reports and notes (not secret).
aiusb\logs\             launcher event log (no secrets, no keys).
aiusb\backups\          backups made in rescue mode, one folder per run.

================================================================================
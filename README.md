# AI-USB

A USB stick that carries AI coding agents with you. Plug it into any Windows or Linux PC,
type your passphrase, and pick an agent. Your logins travel with the stick, not the PC.

## What's on the stick

- **Claude Code**
- **Claude Code on GLM** (z.ai)
- **Codex** (OpenAI)
- **Antigravity** (Google)
- A shell with all of them ready to use

## How it works

- **Plug in and run.** On Windows, double-click `Start AI Agent.cmd`. On Linux, run
  `start-ai-agent.sh`. A menu opens.
- **Logins stay locked.** Every login is kept in an encrypted vault on the stick
  ([age](https://github.com/FiloSottile/age), protected by your passphrase).
- **Nothing left behind.** When you quit, everything is saved back into the vault. No
  logins stay on the PC.
- **Conversations follow you.** Pick up any saved conversation on any PC.
- **Rescue mode.** Boot the stick on a PC whose Windows won't start. A small Linux system
  opens the same menu so an agent can help repair it. Works with Secure Boot on.

## Build your own

You need a Linux PC (built on Arch/CachyOS) and a USB stick.

```bash
scripts/fetch-agents.sh                  # download the agents into build/payload
sudo scripts/build-rescue-rootfs.sh      # build the rescue system
scripts/make-esp-tree.sh                 # assemble the boot partition
```

Then write the stick with `scripts/write-usb.sh` (this **erases** the stick, and checks
its serial number first) and copy `build/payload` onto it. Use `--help` on the scripts to
see their options.

## More

- `payload/README.txt` is the user guide that ships on the stick.
- `docs/ARCHITECTURE.md` explains how everything fits together.
- `tests/` holds the launcher tests.

## License

Free for non-commercial use under the [PolyForm Noncommercial License 1.0.0](LICENSE.md).
For commercial use, contact me on GitHub ([@Astimos](https://github.com/Astimos)).

The agents and tools the build downloads (Claude Code, Codex, Antigravity, age) are not part
of this project and keep their own licenses.

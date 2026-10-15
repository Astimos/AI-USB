#!/usr/bin/env python3
"""Drive payload/aiusb/launcher/launcher.sh through its main flows in a pty.

Uses a throwaway copy of the payload (build/test-usb) and a throwaway passphrase.
Run: build/tools/venv/bin/python tests/test_launcher_sh.py  (venv: python3 -m venv build/tools/venv && build/tools/venv/bin/pip install pexpect)
Optional: AIUSB_TEST_USB=<mounted exFAT copy of build/payload>
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time

import pexpect

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
USB = os.environ.get("AIUSB_TEST_USB", os.path.join(REPO, "build", "test-usb"))
LAUNCHER = os.path.join(USB, "aiusb", "launcher", "launcher.sh")
V = os.path.join(USB, "aiusb", "vault")
S = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()), "aiusb-session")
PASS = "test pass 123"
ZAI = "zai-TEST-KEY-0123456789"
GEMKEY = "AIzaTEST-gemini-key"
MENU = r"Q\) Save, lock and quit"

results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + ((" - " + detail) if detail else ""), flush=True)


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def home_state():
    out = subprocess.run(
        "find ~/.codex ~/.gemini -maxdepth 2 -printf '%p %T@\\n' 2>/dev/null | sort",
        shell=True, capture_output=True, text=True).stdout
    return hashlib.sha256(out.encode()).hexdigest()


def start():
    # host settings that could steer an agent must never reach it (scrubbed by the launcher)
    env = dict(os.environ, TERM="xterm-256color", AIUSB_LANG="en", AGY_ACCOUNT="host-leak",
               ANTIGRAVITY_PROJECT_ID="host-leak")
    env.pop("AIUSB_ELEVATED", None)
    p = pexpect.spawn("bash", [LAUNCHER, "--mode", "linux"], env=env, encoding="utf-8",
                      timeout=60, dimensions=(50, 160))
    p.logfile_read = open(os.path.join(REPO, "build", "test-launcher.log"), "a")
    p.expect(r"root\) access to this PC\? \[Y/n\]")
    p.sendline("n")
    return p


def unlock(p, pw=PASS):
    p.expect("Enter passphrase")
    p.sendline(pw)


def quit_menu(p, wait_menu=True):
    if wait_menu:
        p.expect(MENU)
    p.send("q")
    p.expect(pexpect.EOF)
    p.close()
    return p.exitstatus


def reset_usb():
    for name in os.listdir(V):
        if os.path.isdir(os.path.join(V, name)):
            shutil.rmtree(os.path.join(V, name))
        else:
            os.remove(os.path.join(V, name))
    shutil.rmtree(S, ignore_errors=True)


reset_usb()
home_before = home_state()

# T1: first run creates the vault; set a z.ai key; quit
p = start()
p.expect("Enter passphrase")          # age -p: new passphrase
p.sendline(PASS)
p.expect("Confirm passphrase")
p.sendline(PASS)
p.expect(MENU)
check("T1 menu shows 'no key' for GLM", "no key" in p.before)
p.send("k")
p.expect(r"B\) Back")
p.send("1")
p.expect("Paste the key")
p.sendline(ZAI)
p.expect(r"Key saved \((\d+) characters\)")
check("T1 key length echoed only", p.match.group(1) == str(len(ZAI)) and ZAI not in p.before)
p.expect(r"B\) Back")
p.send("b")
rc = quit_menu(p)
files = sorted(os.listdir(V))
check("T1 exit 0", rc == 0, "rc=%s" % rc)
check("T1 vault files", files == ["home.tar.age", "home.tar.age.bak", "identity.age", "recipient.txt", "vault.id"], str(files))
check("T1 session wiped", not os.path.exists(S))
check("T1 lock removed", not os.path.exists(os.path.join(V, "session.lock")))

# T2: unlock with the passphrase; key survives; shell env and wrappers
p = start()
unlock(p)
p.expect(MENU)
check("T2 GLM shows key saved", "key saved" in p.before)
p.send("5")
p.expect(r"\(ai-usb\) ")
p.sendline("echo MARK; env | grep -E '^(ANTHROPIC|CLAUDE|CODEX|GEMINI|OPENAI|GOOGLE|AGY|ANTIGRAVITY|TMPDIR|AIUSB|DISABLE)' | sort; echo END$((7*6))MARK")
p.expect("END42MARK\r\n")
envtxt = p.before
p.expect(r"\(ai-usb\) ")
check("T2 shell env: CLAUDE_CONFIG_DIR in session", "CLAUDE_CONFIG_DIR=%s/home/claude" % S in envtxt)
check("T2 shell env: CODEX_HOME set", "CODEX_HOME=%s/home/codex" % S in envtxt)
check("T2 shell env: TMPDIR in session", "TMPDIR=%s/tmp" % S in envtxt)
check("T2 shell env: no z.ai key exported", ZAI not in envtxt and "ANTHROPIC_AUTH_TOKEN" not in envtxt)
check("T2 shell env: host AGY_*/ANTIGRAVITY_* scrubbed", "host-leak" not in envtxt)
import re as _re
OURS = ("CLAUDE_CODE_TMPDIR=", "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=",
        "CLAUDE_CODE_PROJECT_DIR_NAME=")  # set by the launcher
foreign = [l for l in envtxt.splitlines() if _re.match(r"(CLAUDE_CODE_|CLAUDECODE|CLAUDE_AGENT)", l) and not l.startswith(OURS)]
check("T2 shell env: host CLAUDE_CODE_* scrubbed", not foreign, str(foreign)[:200])
check("T2 shell env: one Claude conversation folder, Codex databases in the session",
      "CLAUDE_CODE_PROJECT_DIR_NAME=aiusb-workspace" in envtxt and "CODEX_SQLITE_HOME=%s/home/codex/sqlite" % S in envtxt)
p.sendline("claude --version; codex --version; agy --version; echo DONE$((6*7))VER")
p.expect("DONE42VER\r\n", timeout=90)
vers = p.before
p.expect(r"\(ai-usb\) ")
check("T2 wrappers run claude/codex/agy", "Claude Code" in vers and "codex-cli" in vers and re.search(r"(?m)^1\.\d+\.\d+", vers) is not None, vers.strip()[:200])
p.sendline("exit")
rc = quit_menu(p)
check("T2 exit 0", rc == 0, "rc=%s" % rc)
check("T2 session wiped", not os.path.exists(S))

# T3: wrong passphrase three times must not touch the vault
h_cur, h_bak = sha(os.path.join(V, "home.tar.age")), sha(os.path.join(V, "home.tar.age.bak"))
p = start()
for _ in range(3):
    unlock(p, "wrong passphrase")
p.expect(pexpect.EOF)
p.close()
check("T3 exit 1 after 3 failures", p.exitstatus == 1, "rc=%s" % p.exitstatus)
check("T3 vault unchanged", sha(os.path.join(V, "home.tar.age")) == h_cur and sha(os.path.join(V, "home.tar.age.bak")) == h_bak)
check("T3 session wiped", not os.path.exists(S))

# T4: crash (SIGKILL) leaves lock + RAM session; next start recovers it
p = start()
unlock(p)
p.expect(MENU)
# make the session newer than the vault: write a marker straight into H, then crash
with open(os.path.join(S, "home", "claude", "crash-marker"), "w") as f:
    f.write("x")
# caches are kept out of the vault (VAULT_EXCLUDES)
os.makedirs(os.path.join(S, "home", "claude", "cache"), exist_ok=True)
with open(os.path.join(S, "home", "claude", "cache", "junk.bin"), "wb") as f:
    f.write(b"0" * 1024 * 1024)
pids = subprocess.run(["pgrep", "-f", LAUNCHER], capture_output=True, text=True).stdout.split()
for pid in pids:
    os.kill(int(pid), 9)
time.sleep(1)
p.close(force=True)
check("T4 crash left lock and session", os.path.exists(os.path.join(V, "session.lock")) and os.path.isdir(S))
p = start()
p.expect("was not closed; cleaning it up")
p.expect("Found a session left open")
unlock(p)
p.expect(MENU)
check("T4 z.ai key kept", "key saved" in p.before)
check("T4 crash-marker recovered", os.path.exists(os.path.join(S, "home", "claude", "crash-marker")))
check("T4 cache not stored in the vault", not os.path.exists(os.path.join(S, "home", "claude", "cache", "junk.bin")))
check("T4 vault stays small", os.path.getsize(os.path.join(V, "home.tar.age")) < 200 * 1024,
      "%d bytes" % os.path.getsize(os.path.join(V, "home.tar.age")))
rc = quit_menu(p, wait_menu=False)
check("T4 exit 0", rc == 0, "rc=%s" % rc)

# T5a: a foreign lock no longer stops the start; it is replaced by our own
with open(os.path.join(V, "session.lock"), "w") as f:
    f.write("host=OTHER-PC os=windows pid=4242 started=2026-01-01T00:00:00Z\n")
p = start()
p.expect("was not closed; cleaning it up")
unlock(p)
p.expect(MENU)
rc = quit_menu(p, wait_menu=False)
check("T5a foreign lock: start continues, exit 0", rc == 0, "rc=%s" % rc)
check("T5a foreign lock removed afterwards", not os.path.exists(os.path.join(V, "session.lock")))

# T5b: a second launcher window on this PC stops itself; the first keeps working
pa = start()
unlock(pa)
pa.expect(MENU)
pb = start()
pb.expect("already open in another window on this PC")
pb.expect(pexpect.EOF)
pb.close()
check("T5b second window exits 0 by itself", pb.exitstatus == 0, "rc=%s" % pb.exitstatus)
check("T5b second window asks no passphrase", "Enter passphrase" not in pb.before)
rc = quit_menu(pa, wait_menu=False)
check("T5b first window still works (exit 0)", rc == 0, "rc=%s" % rc)
check("T5b lock gone after the first window quits", not os.path.exists(os.path.join(V, "session.lock")))

# T5c: the old multi-line lock format is still parsed
with open(os.path.join(V, "session.lock"), "w") as f:
    f.write("host=OTHER-PC\nos=Linux\npid=1\nstarted=2026-01-01T00:00:00Z\n")
p = start()
p.expect("was not closed; cleaning it up")
unlock(p)
p.expect(MENU)
rc = quit_menu(p, wait_menu=False)
check("T5c old multi-line lock: exit 0", rc == 0, "rc=%s" % rc)

# T6: unplug (vault.id disappears) while the shell runs
p = start()
unlock(p)
p.expect(MENU)
p.send("5")
p.expect(r"\(ai-usb\) ")
os.rename(os.path.join(V, "vault.id"), os.path.join(V, "vault.id.away"))
t0 = time.time()
p.expect("USB removed - session wiped", timeout=20)
p.expect(pexpect.EOF, timeout=15)
p.close()
check("T6 watcher fired", True, "%.1fs" % (time.time() - t0))
check("T6 session wiped", not os.path.exists(S))
os.rename(os.path.join(V, "vault.id.away"), os.path.join(V, "vault.id"))
for name in ("session.lock",):
    if os.path.exists(os.path.join(V, name)):
        os.remove(os.path.join(V, name))

# T8: closing the terminal window (hangup) while an agent runs saves, wipes and unlocks
p = start()
unlock(p)
p.expect(MENU)
p.send("5")
p.expect(r"\(ai-usb\) ")
with open(os.path.join(S, "home", "claude", "closed-marker"), "w") as f:
    f.write("x")
p.close(force=True)          # pty closes like a terminal window: SIGHUP
for _ in range(40):
    if not os.path.exists(S) and not os.path.exists(os.path.join(V, "session.lock")):
        break
    time.sleep(0.25)
check("T8 window close wiped the session", not os.path.exists(S))
check("T8 window close removed the lock", not os.path.exists(os.path.join(V, "session.lock")))
p = start()
p.expect(r"Enter passphrase")
check("T8 next start sees no leftover session", "Another session" not in p.before)
p.sendline(PASS)
p.expect(MENU)
check("T8 login saved on window close", os.path.exists(os.path.join(S, "home", "claude", "closed-marker")))
quit_menu(p, wait_menu=False)

# T9: an unfinished Windows session on the stick is saved into the vault, then wiped
STICK_S = os.path.join(USB, "aiusb", "session")
os.makedirs(os.path.join(STICK_S, "home", "claude"), exist_ok=True)
with open(os.path.join(STICK_S, "home", "claude", ".credentials.json"), "w") as f:
    f.write("WIN-SESSION")
with open(os.path.join(V, "vault.id")) as f:
    vid = f.read().strip()
with open(os.path.join(STICK_S, "home", ".aiusb-vault-id"), "w") as f:
    f.write(vid)
p = start()
p.expect("Saving logins from an unfinished Windows session")
unlock(p)
p.expect(MENU)
check("T9 stick session folder gone", not os.path.exists(STICK_S))
with open(os.path.join(S, "home", "claude", ".credentials.json")) as f:
    cred = f.read()
check("T9 Windows login saved into the vault and unlocked", "WIN-SESSION" in cred)
rc = quit_menu(p, wait_menu=False)
check("T9 exit 0", rc == 0, "rc=%s" % rc)

# T9b: a stick session from another vault is wiped without being saved
os.makedirs(os.path.join(STICK_S, "home", "claude"), exist_ok=True)
with open(os.path.join(STICK_S, "home", "claude", ".credentials.json"), "w") as f:
    f.write("MISMATCH-MARK")
with open(os.path.join(STICK_S, "home", ".aiusb-vault-id"), "w") as f:
    f.write("0000")
p = start()
unlock(p)
p.expect(MENU)
check("T9b mismatched stick session folder gone", not os.path.exists(STICK_S))
with open(os.path.join(S, "home", "claude", ".credentials.json")) as f:
    cred = f.read()
check("T9b other vault's login not restored", "MISMATCH-MARK" not in cred)
rc = quit_menu(p, wait_menu=False)
check("T9b exit 0", rc == 0, "rc=%s" % rc)

# T10: closing the terminal right after Q, while the final save is still running
# (a big file makes the save slow), must not abort the save or leave the lock behind
p = start()
unlock(p)
p.expect(MENU)
with open(os.path.join(S, "home", "secrets", "big.bin"), "wb") as f:
    f.write(os.urandom(150 * 1024 * 1024))
p.send("q")
p.expect("Saving and locking")
# hang up while cleanup saves, the way a closing terminal window does: the terminal side of
# the pty goes away and the kernel sends SIGHUP (pexpect's close(force=True) would also send
# SIGKILL 0.3 s later, which no terminal does)
p.ptyproc.fileobj.close()
p.ptyproc.closed = True       # nothing left for pexpect to close later (the fd number is reused)
p.closed = True
t10 = time.time()
for _ in range(240):
    if not os.path.exists(os.path.join(V, "session.lock")) and not os.path.exists(S):
        break
    time.sleep(0.25)
def _running(pid):
    try:
        return open("/proc/%d/stat" % pid).read().split()[2] != "Z"
    except OSError:
        return False
for _ in range(40):
    if not _running(p.pid):
        break
    time.sleep(0.25)
check("T10 launcher finished by itself after the hangup", not _running(p.pid), "%.1fs" % (time.time() - t10))
try:
    os.waitpid(p.pid, 0)
except OSError:
    pass
log10 = open(os.path.join(USB, "aiusb", "logs", "launcher.log")).read().splitlines()
check("T10 lock removed although the window closed during the save", not os.path.exists(os.path.join(V, "session.lock")))
check("T10 final save finished (save-ok after quit)", log10[-1].endswith("save-ok") or any(l.endswith("save-ok") for l in log10[-2:]), log10[-1])
check("T10 big file reached the vault", os.path.getsize(os.path.join(V, "home.tar.age")) > 100 * 1024 * 1024)
# clean up: remove big.bin again via a normal session
p = start()
unlock(p)
p.expect(MENU)
os.remove(os.path.join(S, "home", "secrets", "big.bin"))
quit_menu(p, wait_menu=False)

# T11: language switch: prompt at start, Slovak menu and help, L switches back to English
env11 = dict(os.environ, TERM="xterm-256color")
env11.pop("AIUSB_LANG", None)
env11.pop("AIUSB_ELEVATED", None)
p = pexpect.spawn("bash", [LAUNCHER, "--mode", "linux"], env=env11, encoding="utf-8",
                  timeout=60, dimensions=(50, 160))
p.logfile_read = open(os.path.join(REPO, "build", "test-launcher.log"), "a")
p.expect(r"Language / Jazyk:")
p.sendline("2")
p.expect(r"Da\u0165 asistentom|Dať asistentom")
p.sendline("n")
unlock(p)
p.expect(r"Q\) Ulo\u017ei\u0165|Q\) Uložiť")
check("T11 Slovak menu after choosing 2", True)
p.send("h")
p.expect("Ako funguje AISTiUSB")
p.expect(r"Enter")
p.sendline("")
p.expect(r"Q\) Ulo")
p.send("l")
p.expect(r"Language / Jazyk:")
p.sendline("1")
p.expect(MENU)
check("T11 English menu after L -> 1", True)
cur = open(os.path.join(USB, "aiusb", "lang", "current")).read().strip()
check("T11 choice remembered in lang/current", cur == "en", cur)
quit_menu(p, wait_menu=False)
# a saved Slovak choice is the default next time (Enter keeps it)
with open(os.path.join(USB, "aiusb", "lang", "current"), "w") as f:
    f.write("sk\n")
p = pexpect.spawn("bash", [LAUNCHER, "--mode", "linux"], env=env11, encoding="utf-8",
                  timeout=60, dimensions=(50, 160))
p.expect(r"Language / Jazyk:.*Sloven")
p.sendline("")
p.expect(r"Dať asistentom")
p.sendline("n")
unlock(p)
p.expect(r"Q\) Uložiť")
check("T11 saved Slovak is the default", True)
quit_menu(p, wait_menu=False)
os.remove(os.path.join(USB, "aiusb", "lang", "current"))


# T12: conversation history: saved in its own archives, opened only with an agent (here: the shell)
HIST = os.path.join(V, "history")
shutil.rmtree(HIST, ignore_errors=True)
CONV = os.path.join("claude", "projects", "aiusb-workspace", "conv-t12.jsonl")
ROLL = os.path.join("codex", "sessions", "2026", "10", "13", "rollout-t12.jsonl")
CHAT = os.path.join("agy", ".gemini", "antigravity-cli", "conversations", "t12.pb")
p = start()
unlock(p)
p.expect(MENU)
p.send("5")
p.expect(r"\(ai-usb\) ")
check("T12 the shell opens every group", all(os.path.exists(os.path.join(S, "home", ".aiusb-loaded-" + g))
                                             for g in ("claude", "codex", "agy")))
for rel, text in ((CONV, '{"t":12}'), (ROLL, '{"r":12}'), (CHAT, '{"g":12}')):
    os.makedirs(os.path.dirname(os.path.join(S, "home", rel)), exist_ok=True)
    with open(os.path.join(S, "home", rel), "w") as f:
        f.write(text)
os.makedirs(os.path.join(S, "home", "claude", "skills", "synced", "office"), exist_ok=True)
with open(os.path.join(S, "home", "claude", "skills", "synced", "office", "big.xsd"), "wb") as f:
    f.write(b"x" * 1024 * 1024)
os.makedirs(os.path.join(S, "home", "codex", "sqlite"), exist_ok=True)
with open(os.path.join(S, "home", "codex", "sqlite", "logs_2.sqlite"), "wb") as f:
    f.write(b"l" * 1024 * 1024)
p.sendline("exit")
p.expect(MENU)
check("T12 one archive per group after the agent ran",
      all(os.path.exists(os.path.join(HIST, g + ".tgz.age")) for g in ("claude", "codex", "agy")),
      str(os.listdir(HIST)) if os.path.isdir(HIST) else "no history dir")
check("T12 junk stays out (skills/synced, codex logs db)",
      os.path.getsize(os.path.join(HIST, "claude.tgz.age")) < 64 * 1024
      and os.path.getsize(os.path.join(HIST, "codex.tgz.age")) < 64 * 1024)
quit_menu(p, wait_menu=False)
p = start()
unlock(p)
p.expect(MENU)
check("T12 unlock leaves the conversations closed", not os.path.exists(os.path.join(S, "home", "claude", "projects"))
      and not os.path.exists(os.path.join(S, "home", ".aiusb-loaded-claude")))
check("T12 logins archive holds no conversations", os.path.getsize(os.path.join(V, "home.tar.age")) < 200 * 1024)
p.send("5")
p.expect(r"Opening saved conversations \(Claude\)")
p.expect(r"\(ai-usb\) ")
ok12 = True
for rel, text in ((CONV, '{"t":12}'), (ROLL, '{"r":12}'), (CHAT, '{"g":12}')):
    path = os.path.join(S, "home", rel)
    ok12 = ok12 and os.path.exists(path) and open(path).read() == text
check("T12 conversations of all three agents restored", ok12)
check("T12 junk not restored", not os.path.exists(os.path.join(S, "home", "claude", "skills", "synced"))
      and not os.path.exists(os.path.join(S, "home", "codex", "sqlite", "logs_2.sqlite")))
p.sendline("exit")
rc = quit_menu(p)
check("T12 exit 0", rc == 0, "rc=%s" % rc)
log12 = open(os.path.join(USB, "aiusb", "logs", "launcher.log")).read()
check("T12 load and save timings logged", re.search(r"history-load claude \d+ms", log12) is not None
      and re.search(r"history-save codex \d+ms", log12) is not None)

# T12b: a crashed session that never opened an archive must not overwrite it in the recovery
h12 = sha(os.path.join(HIST, "claude.tgz.age"))
p = start()
unlock(p)
p.expect(MENU)
os.makedirs(os.path.join(S, "home", "claude", "projects", "aiusb-workspace"), exist_ok=True)
with open(os.path.join(S, "home", "claude", "projects", "aiusb-workspace", "partial.jsonl"), "w") as f:
    f.write("partial")
for pid in subprocess.run(["pgrep", "-f", LAUNCHER], capture_output=True, text=True).stdout.split():
    os.kill(int(pid), 9)
time.sleep(1)
p.close(force=True)
p = start()
p.expect("Found a session left open")
unlock(p)
p.expect(MENU)
check("T12b recovery keeps an archive the crashed session never opened", sha(os.path.join(HIST, "claude.tgz.age")) == h12)
quit_menu(p, wait_menu=False)

# T13: R resumes; the agents get one conversation folder; old per-path folders are merged.
# Fake claude/codex/agy (bash scripts that log what they got) stand in for the real ones.
BIN = os.path.join(USB, "aiusb", "bin", "linux-x64")
FAKELOG = os.path.join(REPO, "build", "test-fake-agents.log")
FAKE_SH = r"""#!/usr/bin/env bash
{ printf 'AGENT=%s ARGS=' "$(basename "$0")"; printf '[%s]' "$@"; printf '\n'
  printf 'PROJECT_DIR=%s SQLITE=%s CWD=%s\n' "${CLAUDE_CODE_PROJECT_DIR_NAME:-}" "${CODEX_SQLITE_HOME:-}" "$PWD"
  printf 'AGYENV HOME=%s SSH=%s NOUPDATE=%s\n' "$HOME" "${SSH_CONNECTION:-}" "${AGY_CLI_DISABLE_AUTO_UPDATE:-}"; } >> "$AIUSB_FAKE_LOG"
if [[ "$(basename "$0")" == claude ]]; then
  { ls "$CLAUDE_CONFIG_DIR/projects" 2>&1; echo '@@'; } >> "$AIUSB_FAKE_LOG.claude-dirs"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/$CLAUDE_CODE_PROJECT_DIR_NAME"
  printf '{"fake":13}\n' > "$CLAUDE_CONFIG_DIR/projects/$CLAUDE_CODE_PROJECT_DIR_NAME/fake-t13.jsonl"
fi
if [[ "$(basename "$0")" == codex && "${1:-}" == login ]]; then printf '{}' > "$CODEX_HOME/auth.json"; fi
exit 0
"""
FAKES = ("claude", "codex", "agy")
for name in FAKES:
    os.rename(os.path.join(BIN, name), os.path.join(BIN, name + ".real"))
try:
    for name in FAKES:
        with open(os.path.join(BIN, name), "w") as f:
            f.write(FAKE_SH)
        os.chmod(os.path.join(BIN, name), 0o755)
    for old in (FAKELOG, FAKELOG + ".claude-dirs"):
        if os.path.exists(old):
            os.remove(old)
    env13 = dict(os.environ, TERM="xterm-256color", AIUSB_LANG="en", AIUSB_FAKE_LOG=FAKELOG)
    env13.pop("AIUSB_ELEVATED", None)
    p = pexpect.spawn("bash", [LAUNCHER, "--mode", "linux"], env=env13, encoding="utf-8",
                      timeout=60, dimensions=(50, 160))
    p.logfile_read = open(os.path.join(REPO, "build", "test-launcher.log"), "a")
    p.expect(r"root\) access to this PC\? \[Y/n\]")
    p.sendline("n")
    unlock(p)
    p.expect(MENU)
    check("T13 menu offers R", "R) Resume a conversation" in p.before)
    # a conversation saved by an older launcher under the path-based folder name of a Windows PC
    old_dir = os.path.join(S, "home", "claude", "projects", "E--aiusb-workspace")
    os.makedirs(old_dir, exist_ok=True)
    with open(os.path.join(old_dir, "old-win.jsonl"), "w") as f:
        f.write('{"old":1}')
    p.send("1")
    p.expect(MENU)
    p.send("r")
    p.expect("which assistant")
    p.send("1")
    p.expect(MENU)
    p.send("r")
    p.expect("which assistant")
    p.send("3")
    p.expect(MENU)
    p.send("r")
    p.expect("which assistant")
    p.send("4")
    p.expect("type /resume")
    p.expect(MENU)
    rc = quit_menu(p, wait_menu=False)
    fake = open(FAKELOG).read().splitlines()
    claude_runs = [l for l in fake if l.startswith("AGENT=claude")]
    codex_runs = [l for l in fake if l.startswith("AGENT=codex") and "[login]" not in l]
    agy_runs = [l for l in fake if l.startswith("AGENT=agy")]
    agy_env = [l for l in fake if l.startswith("AGYENV")]
    check("T13 normal start has no --resume, R adds it",
          len(claude_runs) == 2 and "[--resume]" not in claude_runs[0] and claude_runs[1].endswith("[--resume]"),
          str(claude_runs))
    check("T13 Claude gets CLAUDE_CODE_PROJECT_DIR_NAME", "PROJECT_DIR=aiusb-workspace" in "\n".join(fake))
    listings = [c.split() for c in open(FAKELOG + ".claude-dirs").read().split("@@") if c.strip()]
    check("T13 old per-path folder merged before Claude starts",
          len(listings) == 2 and all(l == ["aiusb-workspace"] for l in listings), str(listings))
    check("T13 Codex resume lists every PC's sessions (resume --all)",
          len(codex_runs) == 1 and codex_runs[0].startswith("AGENT=codex ARGS=[resume][--all][--no-daemon]"), str(codex_runs))
    check("T13 Codex gets CODEX_SQLITE_HOME in the session", ("SQLITE=%s/home/codex/sqlite" % S) in "\n".join(fake))
    check("T13 Antigravity starts normally with the /resume hint", agy_runs == ["AGENT=agy ARGS=[--add-dir][/]"], str(agy_runs))
    check("T13 Antigravity: home in the session, file login (SSH marker), no self-update",
          ("AGYENV HOME=%s/home/agy SSH=127.0.0.1 0 127.0.0.1 0 NOUPDATE=true" % S) in agy_env, str(agy_env[-1:]))
    check("T13 other agents keep the real HOME", all(("HOME=%s/home/agy" % S) not in l for l in agy_env[:-1]))
    check("T13 exit 0", rc == 0, "rc=%s" % rc)
finally:
    for name in FAKES:
        os.replace(os.path.join(BIN, name + ".real"), os.path.join(BIN, name))
for extra in (FAKELOG + ".claude-dirs",):
    if os.path.exists(extra):
        os.remove(extra)
# the fake conversation and the merged old one are in the vault now
p = start()
unlock(p)
p.expect(MENU)
p.send("5")
p.expect(r"\(ai-usb\) ")
merged = os.path.join(S, "home", "claude", "projects", "aiusb-workspace")
check("T13 merged and new conversations saved", os.path.exists(os.path.join(merged, "old-win.jsonl"))
      and os.path.exists(os.path.join(merged, "fake-t13.jsonl"))
      and not os.path.exists(os.path.join(S, "home", "claude", "projects", "E--aiusb-workspace")))
p.sendline("exit")
quit_menu(p)

# T14: the real Antigravity CLI through the launcher: its login goes to a file in the session
# (SSH marker), it does not update itself, its files stay in the session, and what the old
# Gemini CLI left in the vault is removed
with open(os.path.join(HIST, "gemini.tgz.age"), "w") as f:
    f.write("legacy")
p = start()
unlock(p)
p.expect(MENU)
check("T14 menu offers Antigravity", "4) Antigravity (Google)" in p.before)
check("T14 old Gemini history archive removed", not os.path.exists(os.path.join(HIST, "gemini.tgz.age")))
p.send("4")
time.sleep(12)                      # let it start (it waits for terminal answers first)
p.send("\x03")
time.sleep(2)
p.send("\x03")
p.expect(MENU, timeout=60)
agylog = ""
logdir = os.path.join(S, "home", "agy", ".gemini", "antigravity-cli", "log")
for name in (os.listdir(logdir) if os.path.isdir(logdir) else []):
    agylog += open(os.path.join(logdir, name), errors="replace").read()
check("T14 Antigravity keeps its login in a file (SSH session detected)",
      "Using file-based token storage because SSH session detected" in agylog, agylog[-300:])
check("T14 Antigravity auto-update disabled", "Auto-update disabled via environment variable" in agylog)
check("T14 Antigravity home is in the session", os.path.isdir(os.path.join(S, "home", "agy", ".gemini", "antigravity-cli")))
rc = quit_menu(p, wait_menu=False)
log14 = open(os.path.join(USB, "aiusb", "logs", "launcher.log")).read().splitlines()
check("T14 exit 0, saves fine (symlinks left out)", rc == 0 and not any("fail" in l for l in log14[-8:]), "\n".join(log14[-6:]))
check("T14 its conversations archive written", os.path.exists(os.path.join(HIST, "agy.tgz.age")))

# T7: nothing secret in the log; nothing new in ~/.codex or ~/.gemini
log = open(os.path.join(USB, "aiusb", "logs", "launcher.log")).read()
check("T7 log has no secrets", ZAI not in log and GEMKEY not in log and PASS not in log)
check("T7 host ~/.codex ~/.gemini untouched", home_state() == home_before)
leftover = subprocess.run("ls /dev/shm | grep -E '^aiusb-(bin|session)'; ls $XDG_RUNTIME_DIR | grep -i aiusb", shell=True,
                          capture_output=True, text=True).stdout.strip()
check("T7 no RAM leftovers", leftover == "", leftover)

failed = [n for n, ok in results if not ok]
print("\n%d passed, %d failed" % (len(results) - len(failed), len(failed)))
sys.exit(1 if failed else 0)

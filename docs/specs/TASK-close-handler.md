# Task: write `payload/aiusb/launcher/AiUsbConsole.cs` (Windows console guards for launcher.ps1)

launcher.ps1 (attached) loads this file with `Add-Type -Path` in **Windows PowerShell 5.1**, which
compiles it with the .NET Framework 4.x CodeDom C# compiler: **C# 5 only** (no string
interpolation `$"..."`, no `?.`, no `=>` members, no `nameof`, no auto-property initializers, no
`using static`, no tuples) and **.NET Framework 4.5 APIs only**. ASCII only. No namespace (the
classes are used as `[AiUsbCtrlGuard]` and `[AiUsbCloseGuard]`). The code also has to compile under
PowerShell 7 on Linux (used for tests); P/Invoke into kernel32 is only *called* on Windows.

## Class 1: `public static class AiUsbCtrlGuard` (move the existing one here, same behaviour)
Copy the class currently embedded in launcher.ps1 (attached) unchanged in behaviour: `On()` registers a
`HandlerRoutine` that swallows CTRL_C_EVENT (0) and CTRL_BREAK_EVENT (1) while an agent runs,
`Off()` unregisters it. Keep the delegate in a static field.

## Class 2: `public static class AiUsbCloseGuard` (new)
Purpose: the user may close the console window with X (or log off / shut down). Windows then sends
CTRL_CLOSE_EVENT (2), CTRL_LOGOFF_EVENT (5) or CTRL_SHUTDOWN_EVENT (6) and kills the process about
5 seconds later; PowerShell's `finally` blocks do NOT run. This class must, inside the handler and
synchronously, end the session the same way launcher.ps1's normal quit does (ARCHITECTURE 5.5-5.7):
stop the agent, save the vault, wipe the session folder, remove the lock, in under ~4 seconds.

Public API (exact):
- `public static void Arm(string tarExe, string ageExe, string usbRoot, string sessionDir,
   string homeDir, string vaultDir, string[] excludes, string logFile, string computerName)`
  Stores the values, registers the console handler once (`SetConsoleCtrlHandler(handler, true)`,
  delegate kept in a static field; registration errors are ignored, e.g. on Linux), sets armed.
- `public static void Disarm()`: after this the handler does nothing (launcher's own quit runs).
- `public static void SetAgentPid(int pid)`: pid of the running agent, 0 when none.
- `public static string RunCloseForTest()`: runs the same close routine synchronously, ignoring the
  armed flag's one-shot guard, and returns the result word (see logging). For tests only.

Handler: `static bool OnCtrl(uint ctrlType)`: for types 2, 5, 6: if armed and the routine has not
run yet (one-shot via `System.Threading.Interlocked.Exchange` on an int), run the close routine;
return `true`. For any other type return `false` (Ctrl+C is not ours). Never throw (catch all).

Close routine (each step wrapped in try/catch; total budget about 4 s):
1. Agent: if pid > 0: start `<windir>\System32\taskkill.exe /PID <pid> /T /F` (windir from
   `Environment.GetFolderPath(Environment.SpecialFolder.Windows)`; skip if the file does not exist),
   wait up to 1500 ms; then also `Process.GetProcessById(pid).Kill()` if it still runs.
2. Save: only when `<vaultDir>\recipient.txt`, `<vaultDir>\vault.id` and `homeDir` exist:
   - names = the file/dir names directly inside homeDir (`Directory.GetFileSystemEntries` +
     `Path.GetFileName`); if none, the save counts as failed.
   - tar: `tarExe -cf <sessionDir>\home.tar` then `--exclude <e>` for every excludes entry, then
     `-C <homeDir>` then every name. Never archive `.` (a `./` member breaks exFAT on Windows).
   - age: `ageExe -R <vaultDir>\recipient.txt -o <vaultDir>\home.tar.age.new <sessionDir>\home.tar`
   - Each process: `ProcessStartInfo` with `UseShellExecute = false`, `CreateNoWindow = true`,
     no stream redirection, arguments joined with a quoting function implementing exactly the
     MSVCRT rules of launcher.ps1's `ConvertTo-WinArg` (as-is when non-empty and free of space, tab
     and `"`; otherwise wrap in quotes, double backslashes before a quote or the closing quote,
     escape `"` as `\"`). Wait up to 2000 ms (tar) / 1500 ms (age); a timeout or a non-zero exit
     code means the save failed (kill a process that timed out).
   - Success only if `home.tar.age.new` exists with length > 0. Then rotate: delete
     `home.tar.age.bak` if present, move `home.tar.age` -> `home.tar.age.bak` if present, move
     `home.tar.age.new` -> `home.tar.age`.
   - Always delete `<sessionDir>\home.tar` and, on failure, `home.tar.age.new`.
3. Only if the save succeeded: wipe sessionDir. Guard: it must be non-empty and equal (ignoring
   case and a trailing separator) to `Path.Combine(usbRoot, "aiusb", "session")`; clear read-only /
   hidden / system attributes of every file and directory below it, then
   `Directory.Delete(sessionDir, true)` (one retry after 200 ms). Then delete
   `<vaultDir>\session.lock`. If the save failed, leave both in place: the next start recovers the
   session from the stick (it is on the stick, not on the PC).
4. Log: append one ASCII line `<UTC yyyy-MM-ddTHH:mm:ssZ> windows <computerName> window-closed
   <result>` to logFile, where result is `save-ok`, `save-fail` or `no-session`. Never log secrets.
   `RunCloseForTest` returns that result word.

Thread safety: the handler runs on a system thread. Store the configuration in static fields set
by Arm before registering; read them into locals at the start of the routine.

Output ONLY the raw C# file contents, no fences, no commentary.

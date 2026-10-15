// AiUsbConsole.cs - Windows console guards for launcher.ps1.
// Loaded with Add-Type -Path under Windows PowerShell 5.1 (CodeDom, C# 5,
// .NET Framework 4.5) and under PowerShell 7 (tests). ASCII only. No
// namespace: the classes are used as [AiUsbCtrlGuard] and [AiUsbCloseGuard].
// kernel32 is only ever called on Windows; on other platforms the calls are
// skipped or their errors ignored.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// ------------------------------------------------------------------ Ctrl+C guard
// While an agent runs, Ctrl+C belongs to the agent. The handler swallows
// CTRL_C_EVENT (0) and CTRL_BREAK_EVENT (1) so the console does not also stop
// launcher.ps1. A handler routine (unlike SetConsoleCtrlHandler(NULL)) is not
// inherited by children.
public static class AiUsbCtrlGuard
{
    public delegate bool HandlerRoutine(uint ctrlType);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    private static HandlerRoutine keep;

    private static bool Swallow(uint ctrlType)
    {
        return ctrlType == 0 || ctrlType == 1;
    }

    public static void On()
    {
        if (keep != null) { return; }
        if (Environment.OSVersion.Platform != PlatformID.Win32NT) { return; }
        keep = new HandlerRoutine(Swallow);
        try { SetConsoleCtrlHandler(keep, true); } catch { }
    }

    public static void Off()
    {
        if (keep == null) { return; }
        if (Environment.OSVersion.Platform != PlatformID.Win32NT) { keep = null; return; }
        try { SetConsoleCtrlHandler(keep, false); } catch { }
        keep = null;
    }
}

// ------------------------------------------------------------------ Credential Manager guard
// Antigravity CLI keeps its Google login in the Windows Credential Manager unless it takes
// the file store the launcher asks for (it does for SSH sessions; launcher.ps1 sets that
// marker). As a safety net the launcher records the entries before the agent starts
// (SetBaseline) and deletes only the new Antigravity entries afterwards and at window close
// (CleanNew), so no login stays on the PC and the PC owner's own entries are never touched.
public static class AiUsbCredGuard
{
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredEnumerateW(string filter, int flags, out int count, out IntPtr credentials);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, int type, int flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    private static readonly object gate = new object();
    private static string[] baseline = null;

    // Every credential of the current user as "type|target"; empty off Windows.
    public static string[] List()
    {
        List<string> result = new List<string>();
        if (Environment.OSVersion.Platform != PlatformID.Win32NT) { return result.ToArray(); }
        int count;
        IntPtr creds;
        // 1 = CRED_ENUMERATE_ALL_CREDENTIALS (filter must be null)
        if (!CredEnumerateW(null, 1, out count, out creds)) { return result.ToArray(); }
        try
        {
            for (int i = 0; i < count; i++)
            {
                IntPtr c = Marshal.ReadIntPtr(creds, i * IntPtr.Size);
                // CREDENTIALW: DWORD Flags, DWORD Type, LPWSTR TargetName, ...
                int type = Marshal.ReadInt32(c, 4);
                string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(c, 8));
                if (name != null) { result.Add(type.ToString(CultureInfo.InvariantCulture) + "|" + name); }
            }
        }
        finally { CredFree(creds); }
        return result.ToArray();
    }

    // Deletes one entry given as "type|target".
    public static bool Delete(string entry)
    {
        if (entry == null || Environment.OSVersion.Platform != PlatformID.Win32NT) { return false; }
        int bar = entry.IndexOf('|');
        if (bar < 1) { return false; }
        int type;
        if (!int.TryParse(entry.Substring(0, bar), NumberStyles.Integer, CultureInfo.InvariantCulture, out type)) { return false; }
        return CredDeleteW(entry.Substring(bar + 1), type, 0);
    }

    public static void SetBaseline()
    {
        string[] now = List();
        lock (gate) { baseline = now; }
    }

    public static void ClearBaseline()
    {
        lock (gate) { baseline = null; }
    }

    // Deletes Antigravity entries that were not there at SetBaseline; returns how many.
    public static int CleanNew()
    {
        string[] before;
        lock (gate) { before = baseline; }
        if (before == null) { return 0; }
        int removed = 0;
        string[] now = List();
        for (int i = 0; i < now.Length; i++)
        {
            string e = now[i];
            if (Array.IndexOf(before, e) >= 0) { continue; }
            string lower = e.ToLowerInvariant();
            if (lower.IndexOf("antigravity", StringComparison.Ordinal) < 0 && lower.IndexOf("jetski", StringComparison.Ordinal) < 0) { continue; }
            if (Delete(e)) { removed++; }
        }
        return removed;
    }
}

// ------------------------------------------------------------------ close guard
// The user may close the console window (or log off / shut down). Windows then
// sends CTRL_CLOSE_EVENT (2), CTRL_LOGOFF_EVENT (5) or CTRL_SHUTDOWN_EVENT (6)
// and kills the process about 5 seconds later; PowerShell "finally" blocks do
// NOT run. The handler ends the session synchronously, the same way the
// launcher's normal quit does: stop the agent, save the vault (logins first,
// then the conversation history of the agents that ran), wipe the session
// folder, remove the lock. The whole routine keeps to a 4.5 s budget: taskkill
// 700 ms, save-lock wait up to 3000 ms (then "save-busy", nothing wiped or
// unlocked), every tar and age run gets what is left of the budget. The session
// folder lives on the stick, so a failed or skipped save ("save-fail",
// "history-fail": nothing wiped) is recovered at next start. Killing the
// agent frees the launcher's main thread, whose own Save-Vault would then race
// this routine on the same files; closingFlag (set first here) plus
// EnterSave/ExitSave around that save prevent the race.
public static class AiUsbCloseGuard
{
    private delegate bool CtrlHandler(uint ctrlType);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(CtrlHandler handler, bool add);

    // configuration, stored by Arm before the handler is registered
    private static string cfgTarExe = "";
    private static string cfgAgeExe = "";
    private static string cfgUsbRoot = "";
    private static string cfgSessionDir = "";
    private static string cfgHomeDir = "";
    private static string cfgVaultDir = "";
    private static string[] cfgExcludes = new string[0];
    private static string cfgLogFile = "";
    private static string cfgComputerName = "";

    // conversation history (ARCHITECTURE 5.5.1): a group is saved at window close
    // when its agent ran (dirty) and its archive is open in this session (marker
    // file .aiusb-loaded-<group> in the home)
    private static string cfgHistoryDir = "";
    private static string[] cfgGroupNames = new string[0];
    private static string[] cfgGroupMembers = new string[0];   // '|'-joined paths
    private static string[] cfgJunk = new string[0];
    private static readonly object dirtyLock = new object();
    private static readonly Dictionary<string, bool> dirtyGroups = new Dictionary<string, bool>(StringComparer.Ordinal);

    // Windows ends the process about 5 s after the close event
    private const int CloseBudgetMs = 4500;

    private static int agentPidField;   // pid of the running agent, 0 when none
    private static int armedFlag;       // 1 = the handler acts
    private static int closeRan;        // one-shot guard for the close routine
    private static int registeredFlag;  // console handler registered once
    private static CtrlHandler keep;    // keeps the delegate alive

    // mutual exclusion with the launcher's own Save-Vault: the close routine
    // sets closingFlag before anything else, so the main thread's EnterSave
    // fails and its save is skipped; saveLock also waits out a main-thread
    // save that had already started when the window was closed. The close
    // routine never saves without this lock (two saves at once could
    // interleave writes to the same home.tar / home.tar.age.new and corrupt
    // the vault): it waits at most 3000 ms, then reports "save-busy" and
    // leaves the session folder and session.lock for the next start.
    private static readonly object saveLock = new object();
    private static int closingFlag;     // 1 = the close routine runs/ran

    public static void Arm(string tarExe, string ageExe, string usbRoot, string sessionDir,
        string homeDir, string vaultDir, string[] excludes, string logFile, string computerName)
    {
        cfgTarExe = (tarExe == null) ? "" : tarExe;
        cfgAgeExe = (ageExe == null) ? "" : ageExe;
        cfgUsbRoot = (usbRoot == null) ? "" : usbRoot;
        cfgSessionDir = (sessionDir == null) ? "" : sessionDir;
        cfgHomeDir = (homeDir == null) ? "" : homeDir;
        cfgVaultDir = (vaultDir == null) ? "" : vaultDir;
        cfgExcludes = (excludes == null) ? new string[0] : (string[])excludes.Clone();
        cfgLogFile = (logFile == null) ? "" : logFile;
        cfgComputerName = (computerName == null) ? "" : computerName;
        Interlocked.Exchange(ref agentPidField, 0);
        if (keep == null) { keep = new CtrlHandler(OnCtrl); }
        Interlocked.Exchange(ref armedFlag, 1);
        if (Interlocked.Exchange(ref registeredFlag, 1) == 0)
        {
            try { SetConsoleCtrlHandler(keep, true); } catch { }
        }
    }

    public static void Disarm()
    {
        Interlocked.Exchange(ref armedFlag, 0);
    }

    // historyDir: vault\history; names[i] is saved from the '|'-joined relative
    // paths members[i]; junkExcludes: the tar --exclude patterns for history.
    public static void SetHistory(string historyDir, string[] names, string[] members, string[] junkExcludes)
    {
        cfgHistoryDir = (historyDir == null) ? "" : historyDir;
        cfgGroupNames = (names == null) ? new string[0] : (string[])names.Clone();
        cfgGroupMembers = (members == null) ? new string[0] : (string[])members.Clone();
        cfgJunk = (junkExcludes == null) ? new string[0] : (string[])junkExcludes.Clone();
    }

    public static void SetDirty(string name, bool dirty)
    {
        if (name == null) { return; }
        lock (dirtyLock)
        {
            if (dirty) { dirtyGroups[name] = true; } else { dirtyGroups.Remove(name); }
        }
    }

    private static bool IsDirty(string name)
    {
        lock (dirtyLock)
        {
            return dirtyGroups.ContainsKey(name);
        }
    }

    public static void SetAgentPid(int pid)
    {
        Interlocked.Exchange(ref agentPidField, pid);
    }

    // The launcher's main thread calls this before its own Save-Vault; when it
    // returns false the save must be skipped (a window close handles it, or
    // another save holds the lock).
    public static bool EnterSave(int timeoutMs)
    {
        try
        {
            if (Interlocked.CompareExchange(ref closingFlag, 0, 0) != 0) { return false; }
            bool taken = Monitor.TryEnter(saveLock, timeoutMs);
            if (!taken) { return false; }
            if (Interlocked.CompareExchange(ref closingFlag, 0, 0) != 0)
            {
                try { Monitor.Exit(saveLock); }
                catch (SynchronizationLockException) { }
                return false;
            }
            return true;
        }
        catch { return false; }
    }

    // Releases the save lock taken by a successful EnterSave.
    public static void ExitSave()
    {
        try { Monitor.Exit(saveLock); }
        catch (SynchronizationLockException) { }
    }

    public static bool IsClosing()
    {
        return Interlocked.CompareExchange(ref closingFlag, 0, 0) != 0;
    }

    public static string RunCloseForTest()
    {
        try
        {
            return CloseRoutine();
        }
        catch { return "save-fail"; }
        finally
        {
            Interlocked.Exchange(ref closingFlag, 0);
        }
    }

    private static bool OnCtrl(uint ctrlType)
    {
        try
        {
            if (ctrlType == 2 || ctrlType == 5 || ctrlType == 6)
            {
                if (Interlocked.CompareExchange(ref armedFlag, 0, 0) == 0)
                {
                    return false;
                }
                if (Interlocked.Exchange(ref closeRan, 1) == 0)
                {
                    CloseRoutine();
                }
                return true;
            }
        }
        catch { }
        return false;
    }

    // The close routine. Every step catches its own errors; never throws.
    private static string CloseRoutine()
    {
        // claim the close FIRST: the launcher's main thread then sees
        // IsClosing/EnterSave fail and skips its own Save-Vault instead of
        // racing this routine on the same tar and age files.
        Interlocked.Exchange(ref closingFlag, 1);
        Stopwatch clock = Stopwatch.StartNew();

        // the handler runs on a system thread: read the configuration once
        string tarExe = cfgTarExe;
        string ageExe = cfgAgeExe;
        string usbRoot = cfgUsbRoot;
        string sessionDir = cfgSessionDir;
        string homeDir = cfgHomeDir;
        string vaultDir = cfgVaultDir;
        string[] excludes = cfgExcludes;
        string logFile = cfgLogFile;
        string computerName = cfgComputerName;
        string historyDir = cfgHistoryDir;
        string[] groupNames = cfgGroupNames;
        string[] groupMembers = cfgGroupMembers;
        string[] junk = cfgJunk;

        // a first line right away: the log then shows that the handler ran at all
        try { AppendLog(logFile, computerName, "begin"); } catch { }

        // 1. stop the agent (its death frees the main thread, whose save may
        //    already be running; the lock below waits for it to finish), then
        //    remove an Antigravity login it may have left in the Credential Manager
        try { StopAgent(); } catch { }
        try { AiUsbCredGuard.CleanNew(); } catch { }

        bool lockTaken = false;
        try
        {
            try { lockTaken = Monitor.TryEnter(saveLock, Math.Min(3000, Left(clock))); }
            catch { lockTaken = false; }

            // 2. never save without the lock: two saves at once could
            //    interleave writes to the same home.tar / home.tar.age.new
            //    and corrupt the vault. When the lock is not free in time
            //    (the main thread is still saving on a slow stick) nothing
            //    is saved, wiped or unlocked: the session folder stays on
            //    the stick and the next start recovers it.
            if (!lockTaken)
            {
                try { AppendLog(logFile, computerName, "save-busy"); } catch { }
                return "save-busy";
            }

            // 3. save the logins, then every history group whose agent ran
            string result;
            bool allSaved = false;
            try
            {
                bool haveVault = sessionDir.Length > 0 && vaultDir.Length > 0
                    && File.Exists(Path.Combine(vaultDir, "recipient.txt"))
                    && File.Exists(Path.Combine(vaultDir, "vault.id"))
                    && Directory.Exists(homeDir);
                if (!haveVault)
                {
                    result = "no-session";
                }
                else if (!SaveHome(tarExe, ageExe, sessionDir, homeDir, vaultDir, excludes, clock))
                {
                    result = "save-fail";
                }
                else
                {
                    bool groupsOk = true;
                    for (int i = 0; i < groupNames.Length; i++)
                    {
                        string name = groupNames[i];
                        if (name == null || name.Length == 0 || !IsDirty(name)) { continue; }
                        if (!File.Exists(Path.Combine(homeDir, ".aiusb-loaded-" + name))) { continue; }
                        string joined = (i < groupMembers.Length && groupMembers[i] != null) ? groupMembers[i] : "";
                        if (!SaveGroup(tarExe, ageExe, sessionDir, homeDir, vaultDir, historyDir, name,
                            joined.Split('|'), junk, clock))
                        {
                            groupsOk = false;
                        }
                    }
                    result = groupsOk ? "save-ok" : "history-fail";
                    allSaved = groupsOk;
                }
            }
            catch
            {
                allSaved = false;
                result = "save-fail";
            }

            // 4. only after a complete save: wipe the session folder, then the
            //    lock. Otherwise both stay: the next start recovers the session
            //    from the stick (it is on the stick, not on the PC).
            if (allSaved)
            {
                try { WipeSession(sessionDir, usbRoot, homeDir); } catch { }
                try
                {
                    string lockPath = Path.Combine(vaultDir, "session.lock");
                    if (File.Exists(lockPath)) { File.Delete(lockPath); }
                }
                catch { }
            }

            // 5. one non-secret log line
            try { AppendLog(logFile, computerName, result); } catch { }
            return result;
        }
        finally
        {
            if (lockTaken)
            {
                try { Monitor.Exit(saveLock); }
                catch (SynchronizationLockException) { }
            }
        }
    }

    // milliseconds left of the close budget
    private static int Left(Stopwatch clock)
    {
        long left = CloseBudgetMs - clock.ElapsedMilliseconds;
        if (left < 0) { return 0; }
        return (int)left;
    }

    private static void StopAgent()
    {
        int pid = Interlocked.CompareExchange(ref agentPidField, 0, 0);
        if (pid <= 0) { return; }
        string windir = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (windir != null && windir.Length > 0)
        {
            string taskkill = Path.Combine(windir, "System32\\taskkill.exe");
            if (File.Exists(taskkill))
            {
                // 700 ms only: the process is killed about 5 s after the
                // close event, and the save still needs its budget.
                bool timedOut;
                RunTool(taskkill,
                    new string[] { "/PID", pid.ToString(CultureInfo.InvariantCulture), "/T", "/F" },
                    700, out timedOut);
            }
        }
        try
        {
            Process ap = Process.GetProcessById(pid);
            try
            {
                if (!ap.HasExited) { ap.Kill(); }
            }
            finally { ap.Dispose(); }
        }
        catch { }
    }

    // Re-encrypt the agent home into the vault with the public key.
    private static bool SaveHome(string tarExe, string ageExe, string sessionDir, string homeDir,
        string vaultDir, string[] excludes, Stopwatch clock)
    {
        string tarTmp = Path.Combine(sessionDir, "home.tar");
        string recipient = Path.Combine(vaultDir, "recipient.txt");
        string newPath = Path.Combine(vaultDir, "home.tar.age.new");
        string curPath = Path.Combine(vaultDir, "home.tar.age");
        string bakPath = Path.Combine(vaultDir, "home.tar.age.bak");
        bool ok = false;
        try
        {
            // top-level names only, never ".": a "./" member breaks exFAT on Windows
            List<string> names = new List<string>();
            string[] entries = Directory.GetFileSystemEntries(homeDir);
            if (entries != null)
            {
                for (int i = 0; i < entries.Length; i++)
                {
                    string n = Path.GetFileName(entries[i]);
                    if (n != null && n.Length > 0) { names.Add(n); }
                }
            }
            if (names.Count > 0)
            {
                List<string> tarArgs = new List<string>();
                tarArgs.Add("-cf");
                tarArgs.Add(tarTmp);
                if (excludes != null)
                {
                    for (int i = 0; i < excludes.Length; i++)
                    {
                        string e = excludes[i];
                        if (e == null || e.Length == 0) { continue; }
                        tarArgs.Add("--exclude");
                        tarArgs.Add(e);
                    }
                }
                tarArgs.Add("-C");
                tarArgs.Add(homeDir);
                for (int i = 0; i < names.Count; i++) { tarArgs.Add(names[i]); }

                bool timedOut = false;
                int tarMs = Math.Min(2000, Left(clock) - 300);
                int rc = (tarMs < 200) ? -1 : RunTool(tarExe, tarArgs.ToArray(), tarMs, out timedOut);
                int ageMs = Math.Min(1500, Left(clock));
                if (rc == 0 && !timedOut && ageMs >= 100)
                {
                    int rc2 = RunTool(ageExe,
                        new string[] { "-R", recipient, "-o", newPath, tarTmp },
                        ageMs, out timedOut);
                    if (rc2 == 0 && !timedOut && File.Exists(newPath))
                    {
                        FileInfo fi = new FileInfo(newPath);
                        if (fi.Length > 0)
                        {
                            if (File.Exists(bakPath)) { File.Delete(bakPath); }
                            if (File.Exists(curPath)) { File.Move(curPath, bakPath); }
                            File.Move(newPath, curPath);
                            ok = true;
                        }
                    }
                }
            }
        }
        catch { ok = false; }
        finally
        {
            try { if (File.Exists(tarTmp)) { File.Delete(tarTmp); } } catch { }
            if (!ok)
            {
                try { if (File.Exists(newPath)) { File.Delete(newPath); } } catch { }
            }
        }
        return ok;
    }

    // Save one history group: gzip tar of its paths, encrypted to the vault's
    // public key, written as vault\history\<name>.tgz.age (previous one kept as .bak).
    private static bool SaveGroup(string tarExe, string ageExe, string sessionDir, string homeDir,
        string vaultDir, string historyDir, string name, string[] members, string[] junk, Stopwatch clock)
    {
        if (historyDir == null || historyDir.Length == 0) { return false; }
        string finalPath = Path.Combine(historyDir, name + ".tgz.age");
        string newPath = finalPath + ".new";
        string bakPath = finalPath + ".bak";
        string tgz = Path.Combine(sessionDir, "hist-" + name + ".tgz");
        string recipient = Path.Combine(vaultDir, "recipient.txt");
        bool ok = false;
        try
        {
            List<string> present = new List<string>();
            for (int i = 0; i < members.Length; i++)
            {
                string m = members[i];
                if (m == null || m.Length == 0) { continue; }
                string full = Path.Combine(homeDir, m);
                if (File.Exists(full) || Directory.Exists(full)) { present.Add(m); }
            }
            if (present.Count == 0)
            {
                // the group's folders were deleted on purpose: so are its archives (a
                // .bak would be opened again next time)
                if (File.Exists(finalPath)) { File.Delete(finalPath); }
                if (File.Exists(bakPath)) { File.Delete(bakPath); }
                return true;
            }
            if (!Directory.Exists(historyDir)) { Directory.CreateDirectory(historyDir); }
            List<string> tarArgs = new List<string>();
            tarArgs.Add("-czf");
            tarArgs.Add(tgz);
            if (junk != null)
            {
                for (int i = 0; i < junk.Length; i++)
                {
                    if (junk[i] == null || junk[i].Length == 0) { continue; }
                    tarArgs.Add("--exclude");
                    tarArgs.Add(junk[i]);
                }
            }
            tarArgs.Add("-C");
            tarArgs.Add(homeDir);
            tarArgs.AddRange(present);
            bool timedOut;
            int tarMs = Math.Min(3000, Left(clock) - 300);
            if (tarMs < 200) { return false; }
            int rc = RunTool(tarExe, tarArgs.ToArray(), tarMs, out timedOut);
            if (rc != 0 || timedOut) { return false; }
            int ageMs = Math.Min(2000, Left(clock));
            if (ageMs < 100) { return false; }
            int rc2 = RunTool(ageExe, new string[] { "-R", recipient, "-o", newPath, tgz }, ageMs, out timedOut);
            if (rc2 != 0 || timedOut || !File.Exists(newPath)) { return false; }
            if (new FileInfo(newPath).Length <= 0) { return false; }
            if (File.Exists(bakPath)) { File.Delete(bakPath); }
            if (File.Exists(finalPath)) { File.Move(finalPath, bakPath); }
            File.Move(newPath, finalPath);
            ok = true;
            return true;
        }
        catch { return false; }
        finally
        {
            try { if (File.Exists(tgz)) { File.Delete(tgz); } } catch { }
            if (!ok)
            {
                try { if (File.Exists(newPath)) { File.Delete(newPath); } } catch { }
            }
        }
    }

    private static void WipeSession(string sessionDir, string usbRoot, string homeDir)
    {
        if (!IsExpectedSessionDir(sessionDir, usbRoot)) { return; }
        if (!Directory.Exists(sessionDir)) { return; }
        // the vault id first: a half-wiped session must never be saved over the vault
        try
        {
            string sid = Path.Combine(homeDir, ".aiusb-vault-id");
            if (File.Exists(sid)) { File.Delete(sid); }
        }
        catch { }
        try
        {
            FileAttributes bad = FileAttributes.ReadOnly | FileAttributes.Hidden | FileAttributes.System;
            string[] files = Directory.GetFiles(sessionDir, "*", SearchOption.AllDirectories);
            for (int i = 0; i < files.Length; i++)
            {
                try { File.SetAttributes(files[i], File.GetAttributes(files[i]) & ~bad); } catch { }
            }
            string[] dirs = Directory.GetDirectories(sessionDir, "*", SearchOption.AllDirectories);
            for (int i = 0; i < dirs.Length; i++)
            {
                try { File.SetAttributes(dirs[i], File.GetAttributes(dirs[i]) & ~bad); } catch { }
            }
            try { File.SetAttributes(sessionDir, File.GetAttributes(sessionDir) & ~bad); } catch { }
        }
        catch { }
        try { Directory.Delete(sessionDir, true); } catch { }
        if (Directory.Exists(sessionDir))
        {
            try { Thread.Sleep(200); } catch { }
            try { Directory.Delete(sessionDir, true); } catch { }
        }
    }

    // The session folder may only be wiped at the stick's fixed session path.
    private static bool IsExpectedSessionDir(string sessionDir, string usbRoot)
    {
        if (sessionDir == null || usbRoot == null) { return false; }
        string s = sessionDir.TrimEnd('\\', '/');
        string expected = Path.Combine(usbRoot, "aiusb", "session").TrimEnd('\\', '/');
        if (s.Length == 0 || expected.Length == 0) { return false; }
        return string.Compare(s, expected, StringComparison.OrdinalIgnoreCase) == 0;
    }

    private static void AppendLog(string logFile, string computerName, string result)
    {
        if (logFile == null || logFile.Length == 0) { return; }
        string dir = Path.GetDirectoryName(logFile);
        if (dir != null && dir.Length > 0 && !Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }
        string stamp = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        string line = stamp + " windows " + computerName + " window-closed " + result + "\r\n";
        File.AppendAllText(logFile, line, Encoding.ASCII);
    }

    // Run one tool: no stream redirection, no window, quoted arguments.
    // Returns the exit code, or -1 on timeout (the process is then killed).
    private static int RunTool(string exe, string[] args, int timeoutMs, out bool timedOut)
    {
        timedOut = false;
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = exe;
        psi.Arguments = BuildArgs(args);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardInput = false;
        psi.RedirectStandardOutput = false;
        psi.RedirectStandardError = false;
        Process p = Process.Start(psi);
        if (p == null) { return -1; }
        try
        {
            if (!p.WaitForExit(timeoutMs))
            {
                timedOut = true;
                try { p.Kill(); } catch { }
                try { p.WaitForExit(300); } catch { }
                return -1;
            }
            return p.ExitCode;
        }
        finally { p.Dispose(); }
    }

    private static string BuildArgs(string[] args)
    {
        if (args == null || args.Length == 0) { return ""; }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0) { sb.Append(' '); }
            sb.Append(QuoteArg(args[i]));
        }
        return sb.ToString();
    }

    // The MSVCRT / CommandLineToArgvW rules of launcher.ps1's ConvertTo-WinArg:
    // as-is when non-empty and free of space, tab and double quote; otherwise
    // wrapped in quotes, backslashes doubled before a quote or the closing
    // quote, and a double quote escaped as backslash-quote.
    private static string QuoteArg(string value)
    {
        if (value == null) { value = ""; }
        if (value.Length > 0 && value.IndexOf(' ') < 0 && value.IndexOf('\t') < 0
            && value.IndexOf('"') < 0)
        {
            return value;
        }
        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        int i = 0;
        while (i < value.Length)
        {
            int bs = 0;
            while (i < value.Length && value[i] == '\\') { bs++; i++; }
            if (i < value.Length)
            {
                char ch = value[i];
                if (ch == '"')
                {
                    sb.Append('\\', 2 * bs + 1);
                    sb.Append('"');
                }
                else
                {
                    sb.Append('\\', bs);
                    sb.Append(ch);
                }
                i++;
            }
            else
            {
                sb.Append('\\', 2 * bs);
            }
        }
        sb.Append('"');
        return sb.ToString();
    }
}
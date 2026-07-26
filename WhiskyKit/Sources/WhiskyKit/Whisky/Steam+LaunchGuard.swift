//
//  Steam+LaunchGuard.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Darwin
import Foundation

// Single-instance launch guard: keeps Steam to one clean CEF login tree.
extension Steam {
    /// Substrings unique to Steam's Wine-side process tree — the client `steam.exe`,
    /// its CEF host `steamwebhelper` / `cef.win64` / `cef.win32` subprocesses, and
    /// the background `steamservice` / `steamerrorreporter`. Matched against each
    /// process's argv (see `matchingPIDs`); none appears in the Whisky launcher's own
    /// argv, and a reap only runs before starting a new Steam, so it can neither kill
    /// Whisky itself nor a launch in flight.
    private static let steamProcessPatterns =
        ["steam.exe", "steamwebhelper", "cef.win64", "cef.win32", "steamservice", "steamerrorreporter"]

    /// True when a Steam client (`steam.exe`) is already running in any bottle.
    public static func isSteamRunning() -> Bool {
        !matchingPIDs(patterns: ["steam.exe"]).isEmpty
    }

    /// True when `url` is the Steam client executable — the one launch we guard.
    /// Games and other programs are unaffected (they never trigger a reap).
    public static func isSteamClient(_ url: URL) -> Bool {
        url.lastPathComponent.caseInsensitiveCompare("Steam.exe") == .orderedSame
    }

    /// Clear everything Steam left behind so a fresh launch starts clean — kill the
    /// client, its CEF login trees, and the background service, then the bottle's
    /// wineserver. Call only when no live client is running (`isSteamRunning` is false).
    ///
    /// Two things must be cleared. (1) Steam's mutex does not survive Wine's wineserver
    /// lifecycle: when the server is killed or restarts (Wine rebuilds, `wineserver -k`,
    /// crashes), running `steamwebhelper` trees reparent to launchd (PPID 1) and detach
    /// from the new server — `wineserver -k` can no longer reach them, so they are
    /// killed directly. (2) The old wineserver itself: an orphaned/detached one keeps a
    /// Steam bound to a dead session whose windows macOS no longer maps (the
    /// invisible-Steam trap). It is found by its `WINEPREFIX` environment and killed
    /// with `kill(2)` — not `wineserver -k`, which can't reach a detached session.
    public static func reapSteamProcesses(in bottle: Bottle) async {
        await SteamLaunchGuard.shared.serialize {
            let prefix = bottle.url.path(percentEncoded: false)
            for pid in matchingPIDs(patterns: steamProcessPatterns) {
                kill(pid, SIGKILL)
            }
            // SIGKILL is prompt, but reparented children can take a moment to
            // disappear; wait (bounded ~5s) before clearing the server.
            for _ in 0..<25 {
                if matchingPIDs(patterns: steamProcessPatterns).isEmpty { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            // Kill the bottle's whole Wine tree by working directory, not by name:
            // the wineserver plus its detached service processes (services.exe,
            // svchost.exe, plugplay.exe, rpcss.exe, tabtip.exe, winedevice.exe,
            // explorer.exe). Once these reparent to launchd their argv/env go
            // unreadable via KERN_PROCARGS2, so the pattern and WINEPREFIX-env
            // matchers above never see them, and killing the server does not
            // cascade to PPID-1 children — so they leak and pile up across every
            // server death (crash, `wineserver -k`, Wine rebuild). Their cwd stays
            // inside this bottle's prefix, readable via proc_pidinfo, and scoped to
            // this bottle so another bottle's Wine is never touched.
            for pid in pidsWithWorkingDirectory(under: prefix) {
                kill(pid, SIGKILL)
            }
            // Belt and suspenders: a wineserver whose cwd is not under the prefix
            // is still caught by its WINEPREFIX environment.
            for pid in wineserverPIDs(forPrefix: prefix) {
                kill(pid, SIGKILL)
            }
        }
    }

    /// PIDs whose argv contains any of `patterns` (case-insensitive), found via
    /// libproc + `sysctl(KERN_PROCARGS2)` — no `pgrep`/`pkill` subprocess.
    private static func matchingPIDs(patterns: [String]) -> [pid_t] {
        let needles = patterns.map { $0.lowercased() }
        return allPIDs().filter { pid in
            guard let argv = processArgvEnv(pid)?.argv.lowercased() else { return false }
            return needles.contains { argv.contains($0) }
        }
    }

    /// PIDs of the wineserver(s) whose `WINEPREFIX` environment is `prefix` — matched on
    /// argv (the wineserver binary) plus env (the prefix), so this bottle's server is
    /// killed without touching another bottle's, entirely via `sysctl` + `kill(2)`.
    private static func wineserverPIDs(forPrefix prefix: String) -> [pid_t] {
        let prefixNeedle = "wineprefix=\(prefix)".lowercased()
        return allPIDs().filter { pid in
            guard let info = processArgvEnv(pid) else { return false }
            return info.argv.lowercased().contains("wineserver")
                && info.env.lowercased().contains(prefixNeedle)
        }
    }

    /// PIDs whose current working directory is `prefix` or lives inside it, via
    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)` — readable even for detached processes
    /// whose argv/env `sysctl(KERN_PROCARGS2)` no longer returns. This is how the
    /// bottle's Wine service tree is reached; scoped to `prefix` so it cannot touch
    /// another bottle.
    private static func pidsWithWorkingDirectory(under prefix: String) -> [pid_t] {
        let root = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return allPIDs().filter { pid in
            guard let cwd = processWorkingDirectory(pid) else { return false }
            return cwd == prefix || cwd.hasPrefix(root)
        }
    }

    /// The current working directory of `pid`, or nil if unreadable/gone.
    private static func processWorkingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard written == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Every process ID on the system (best-effort).
    private static func allPIDs() -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<pid_t>.size + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 != 0 }
    }

    /// The exec path + argv and the environment of `pid`, each as one string, via
    /// `sysctl(KERN_PROCARGS2)`. Returns nil when the process is gone or unreadable.
    private static func processArgvEnv(_ pid: pid_t) -> (argv: String, env: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: argc (Int32), exec_path\0, padding\0…, argv[0]\0 … argv[argc-1]\0, env…
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard index < buffer.count else { return nil }
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(bytes: buffer[start..<index], encoding: .utf8)
        }
        var argvParts: [String] = []
        if let execPath = nextString() { argvParts.append(execPath) }
        while index < buffer.count, buffer[index] == 0 { index += 1 }  // padding before argv
        var read: Int32 = 0
        while read < argc, index < buffer.count, let arg = nextString() {
            argvParts.append(arg)
            read += 1
        }
        var envParts: [String] = []
        while index < buffer.count, buffer[index] == 0 { index += 1 }  // padding before env
        while index < buffer.count, let env = nextString(), !env.isEmpty {
            envParts.append(env)
        }
        return (argvParts.joined(separator: " "), envParts.joined(separator: " "))
    }
}

/// Serializes Steam launch reaps within the process so two overlapping launch
/// requests can't interleave their reap-and-launch and momentarily leave two CEF
/// trees. Each call chains after the previous one's completion.
private actor SteamLaunchGuard {
    static let shared = SteamLaunchGuard()
    private var tail: Task<Void, Never> = Task {}

    func serialize(_ body: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let task = Task {
            await previous.value
            await body()
        }
        tail = task
        await task.value
    }
}

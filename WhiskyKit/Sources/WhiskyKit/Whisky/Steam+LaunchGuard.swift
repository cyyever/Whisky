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

    /// Kill every leftover Steam process — the client, its CEF login trees, and the
    /// background service — then wait until they're gone, so a fresh launch starts
    /// clean. Call only when no live client is running (`isSteamRunning` is false).
    ///
    /// Steam's own mutex does not survive Wine's wineserver lifecycle: when the
    /// server is killed or restarts (frequent here — Wine rebuilds, `wineserver -k`,
    /// crashes), running `steamwebhelper` trees reparent to launchd (PPID 1) and
    /// detach from the new server, and a `steamservice` can linger. A new Steam then
    /// fights them over the one `-steampid` and the login window never renders, so
    /// they must be reaped.
    public static func reapSteamProcesses() async {
        await SteamLaunchGuard.shared.serialize {
            for pid in matchingPIDs(patterns: steamProcessPatterns) {
                kill(pid, SIGKILL)
            }
            // SIGKILL is prompt, but reparented children can take a moment to
            // disappear; wait (bounded ~5s) so the launch starts from a clean slate.
            for _ in 0..<25 {
                if matchingPIDs(patterns: steamProcessPatterns).isEmpty { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// PIDs whose argv contains any of `patterns` (case-insensitive), found via
    /// libproc + `sysctl(KERN_PROCARGS2)` — no `pgrep`/`pkill` subprocess.
    private static func matchingPIDs(patterns: [String]) -> [pid_t] {
        let needles = patterns.map { $0.lowercased() }
        return allPIDs().filter { pid in
            guard let argv = processArgv(pid)?.lowercased() else { return false }
            return needles.contains { argv.contains($0) }
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

    /// The exec path + argv of `pid` as one string (environment excluded), via
    /// `sysctl(KERN_PROCARGS2)`. Returns nil when the process is gone or unreadable.
    private static func processArgv(_ pid: pid_t) -> String? {
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
        var parts: [String] = []
        if let execPath = nextString() { parts.append(execPath) }
        while index < buffer.count, buffer[index] == 0 { index += 1 }  // skip padding
        var read: Int32 = 0
        while read < argc, index < buffer.count, let arg = nextString() {
            parts.append(arg)
            read += 1
        }
        return parts.joined(separator: " ")
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

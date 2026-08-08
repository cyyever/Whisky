//
//  WineProcesses.swift
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

/// Finding the Wine-side processes belonging to a bottle.
///
/// All of it goes through libproc and `sysctl` rather than spawning `ps`/`pgrep`:
/// no subprocess per query, and it keeps working for the processes that matter
/// most here. When a wineserver dies its children reparent to launchd, and from
/// then on `KERN_PROCARGS2` returns nothing for them — so argv matching alone
/// silently misses exactly the orphans a reap exists to clean up.
/// `workingDirectory` still reads, which is why bottle scoping is done that way.
///
/// Scoping matters and is easy to get subtly wrong. A matcher that only tests
/// the client's own name will happily report "a client is running" for a client
/// in a *different* bottle, and the caller then skips cleanup that the bottle in
/// front of it needed.
enum WineProcesses {
    /// PIDs whose argv contains any of `patterns` (case-insensitive).
    static func matching(patterns: [String]) -> [pid_t] {
        let needles = patterns.map { $0.lowercased() }
        return all().filter { pid in
            guard let argv = argvAndEnv(pid)?.argv.lowercased() else { return false }
            return needles.contains { argv.contains($0) }
        }
    }

    /// PIDs whose argv matches `patterns` *and* which belong to `bottle`.
    ///
    /// Membership is by working directory, not by looking for the prefix in
    /// argv: a Wine process's argv carries the Windows path of its exe
    /// (`C:\…\GalaxyClient.exe`), which contains no bottle prefix at all, so an
    /// argv test can only ever be a no-op that reads like a scope check.
    static func matching(patterns: [String], in bottle: Bottle) -> [pid_t] {
        let scoped = Set(withWorkingDirectory(under: bottle.url.path(percentEncoded: false)))
        return matching(patterns: patterns).filter { scoped.contains($0) }
    }

    /// PIDs of the wineserver(s) whose `WINEPREFIX` environment is `prefix` — matched on
    /// argv (the wineserver binary) plus env (the prefix), so this bottle's server is
    /// reached without touching another bottle's.
    static func wineservers(forPrefix prefix: String) -> [pid_t] {
        let prefixNeedle = "wineprefix=\(prefix)".lowercased()
        return all().filter { pid in
            guard let info = argvAndEnv(pid) else { return false }
            return info.argv.lowercased().contains("wineserver")
                && info.env.lowercased().contains(prefixNeedle)
        }
    }

    /// PIDs whose current working directory is `prefix` or lives inside it, via
    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)` — readable even for detached processes
    /// whose argv/env `sysctl(KERN_PROCARGS2)` no longer returns.
    static func withWorkingDirectory(under prefix: String) -> [pid_t] {
        let root = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return all().filter { pid in
            guard let cwd = workingDirectory(pid) else { return false }
            return cwd == prefix || cwd.hasPrefix(root)
        }
    }

    /// The current working directory of `pid`, or nil if unreadable/gone.
    static func workingDirectory(_ pid: pid_t) -> String? {
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
    static func all() -> [pid_t] {
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
    static func argvAndEnv(_ pid: pid_t) -> (argv: String, env: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
            size > MemoryLayout<Int32>.size
        else { return nil }
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

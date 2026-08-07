//
//  GogGalaxy.swift
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

import Foundation
import os.log

/// GOG Galaxy launch hygiene.
///
/// Galaxy is single-instance, and it decides whether another instance is running
/// from lock files under `ProgramData`, not from anything the OS tracks. Under
/// Wine those files routinely outlive the process — a wineserver kill, a crash,
/// or quitting Whisky leaves them behind — after which every subsequent launch
/// takes the "already running" path, tries to raise a window that no longer
/// exists, and quits:
///
///     Could not start 'GalaxyClientService' while requesting service to delete stale lock files.
///     Second client instance detected. Sending RestoreClientMessage.
///     Failed to locate Galaxy Client window, message will not be sent, error code 0.
///     Initialization strategy 'InitClientStrategy' returned exit code 0. The client will exit.
///
/// It reads as "Galaxy silently does nothing": exit code 0, no crash dialog, and
/// the client's own log is the only place the reason appears. Clearing the locks
/// before launch is enough — Galaxy recreates them.
public enum GogGalaxy {
    /// Galaxy's own client executable (not the launcher stub or the service).
    public static func isGalaxyClient(_ url: URL) -> Bool {
        url.lastPathComponent.caseInsensitiveCompare("GalaxyClient.exe") == .orderedSame
    }

    /// True while a Galaxy client is live in `bottle`, so we leave its locks alone.
    public static func isGalaxyRunning(in bottle: Bottle) -> Bool {
        !matchingPIDs(pattern: "GalaxyClient.exe", bottle: bottle).isEmpty
    }

    /// Remove lock files left by a previous run so Galaxy doesn't mistake them for
    /// a live instance. Only safe when no client is running — checked by the caller.
    public static func clearStaleLocks(in bottle: Bottle) {
        let manager = FileManager.default
        let programData = bottle.url
            .appending(path: "drive_c")
            .appending(path: "ProgramData")
            .appending(path: "GOG.com")
            .appending(path: "Galaxy")

        // The lock directory itself is recreated by Galaxy, so emptying it is
        // enough — and safer than removing the directory, which the client may
        // expect to exist.
        let lockDirectory = programData.appending(path: "lock-files")
        if let entries = try? manager.contentsOfDirectory(
            at: lockDirectory,
            includingPropertiesForKeys: nil)
        {
            for entry in entries {
                try? manager.removeItem(at: entry)
                Logger.wineKit.info("Removed stale GOG Galaxy lock \(entry.lastPathComponent)")
            }
        }

        // The embedded Chromium's LevelDB lock. Held for the process lifetime, so
        // it survives a kill too and blocks the web view from opening its store.
        let webCacheLock =
            programData
            .appending(path: "webcache")
            .appending(path: "common")
            .appending(path: "Local Storage")
            .appending(path: "leveldb")
            .appending(path: "LOCK")
        if manager.fileExists(atPath: webCacheLock.path(percentEncoded: false)) {
            try? manager.removeItem(at: webCacheLock)
            Logger.wineKit.info("Removed stale GOG Galaxy webcache LOCK")
        }
    }

    /// PIDs of processes whose command line contains `pattern` and that belong to
    /// `bottle`. Mirrors the Steam launch guard's matcher.
    private static func matchingPIDs(pattern: String, bottle: Bottle) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "pid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil,
            let data = try? pipe.fileHandleForReading.readToEnd(),
            let output = String(data: data, encoding: .utf8)
        else { return [] }
        process.waitUntilExit()

        let prefix = bottle.url.path(percentEncoded: false)
        return output.split(separator: "\n").compactMap { line in
            guard line.contains(pattern) else { return nil }
            // A Wine process's argv carries the unix path of its exe, so the
            // bottle prefix distinguishes this bottle's Galaxy from another's.
            guard line.contains(prefix) || line.contains("GalaxyClient.exe") else { return nil }
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            return fields.first.flatMap { pid_t($0) }
        }
    }
}

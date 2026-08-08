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
    ///
    /// Scoped to the bottle by working directory. The previous matcher looked for
    /// the bottle prefix in the process's argv, which cannot work: a Wine
    /// process's argv carries the *Windows* path of its exe
    /// (`C:\…\GalaxyClient.exe`) and no prefix at all. Its fallback clause made
    /// the test unconditionally true, so a Galaxy in any bottle suppressed lock
    /// clearing for every other bottle — the silent exit-0 this file exists to
    /// prevent.
    public static func isGalaxyRunning(in bottle: Bottle) -> Bool {
        !WineProcesses.matching(patterns: ["GalaxyClient.exe"], in: bottle).isEmpty
    }

    /// Remove lock files left by a previous run so Galaxy doesn't mistake them for
    /// a live instance. Only safe when no client is running — checked by the caller.
    public static func clearStaleLocks(in bottle: Bottle) {
        let programData = bottle.url
            .appending(path: "drive_c")
            .appending(path: "ProgramData")
            .appending(path: "GOG.com")
            .appending(path: "Galaxy")

        StaleLocks.empty(
            programData.appending(path: "lock-files"), describing: "GOG Galaxy lock")

        // The embedded Chromium's LevelDB locks. Held for the process lifetime, so
        // they survive a kill too and block the web view from opening its store.
        // Swept rather than named: this used to remove only
        // `webcache/common/Local Storage/leveldb/LOCK`, which is one store out of
        // however many the bundled Chromium happens to ship — see
        // `StaleLocks.removeAll`.
        StaleLocks.removeAll(
            named: "LOCK", under: programData.appending(path: "webcache"),
            describing: "GOG Galaxy webcache LOCK file(s)")
    }
}

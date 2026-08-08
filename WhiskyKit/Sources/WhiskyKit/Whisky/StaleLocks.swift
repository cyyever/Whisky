//
//  StaleLocks.swift
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

/// Removing the on-disk state a killed client left behind.
///
/// Several game clients decide "am I already running?" from files rather than
/// from anything the OS tracks, so a run that ended in a SIGKILL — Whisky's own
/// reaping, a crash, a wineserver death — leaves them convinced an instance is
/// still live. The failure is quiet and intermittent: the client either exits 0
/// with nothing on screen (GOG Galaxy) or comes up with no UI at all (Steam's
/// CEF), and whether it happens is decided by how the *previous* session ended.
///
/// Which files each client leaves is client-specific knowledge and stays with
/// that client (`Steam.clearStaleLocks`, `GogGalaxy.clearStaleLocks`). What they
/// share is only the mechanics below — remove if present, and say so, since a
/// silent removal makes the next report of "it hung again" impossible to read.
enum StaleLocks {
    /// Remove one lock file if it is there. `what` names it in the log.
    static func remove(_ url: URL, describing what: String) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try? manager.removeItem(at: url)
        Logger.wineKit.info("Removed stale \(what)")
    }

    /// Remove every file named `name` anywhere under `root`.
    ///
    /// A sweep rather than a list of known paths: these are LevelDB stores, and
    /// the client's embedded Chromium adds new ones between versions, where a
    /// single missed lock is enough to reproduce the whole failure.
    static func removeAll(named name: String, under root: URL, describing what: String) {
        let manager = FileManager.default
        guard
            let walker = manager.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }

        var removed = 0
        for case let url as URL in walker where url.lastPathComponent == name {
            try? manager.removeItem(at: url)
            removed += 1
        }
        if removed > 0 {
            Logger.wineKit.info("Removed \(removed) stale \(what)")
        }
    }

    /// Empty `directory` without removing it — safer than deleting the directory,
    /// which the client may expect to exist. It recreates the contents itself.
    static func empty(_ directory: URL, describing what: String) {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return }

        for entry in entries {
            try? manager.removeItem(at: entry)
            Logger.wineKit.info("Removed stale \(what) \(entry.lastPathComponent)")
        }
    }
}

//
//  SteamLibraryWatcher.swift
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

import CoreServices
import Foundation
import os.log

/// Watches a bottle's Steam `steamapps/common` trees and re-runs the DXVK D3D9
/// provisioning scan when the library changes.
///
/// Games launched from inside Steam's own UI (the Play button) bypass Whisky's
/// `Wine.runProgram` path, so `Steam.configure` never sees them: a D3D9 game
/// installed or updated while Steam is already running would otherwise not get
/// its DXVK `d3d9.dll` until Steam is relaunched through Whisky. This watcher
/// closes that gap by re-running the (cheap, mtime-cached) scan a couple of
/// seconds after the on-disk library changes.
///
/// The watcher is a long-lived object owned by the app's active-bottle
/// lifecycle. It is a no-op — never crashing — when the bottle has no Steam
/// library. Recursive `FSEvents` file-event notifications are used (no polling)
/// so both new game directories and in-place updates are caught.
public final class SteamLibraryWatcher: @unchecked Sendable {
    private let bottle: Bottle
    private let watchedPaths: [String]
    private let queue = DispatchQueue(label: "com.isaacmarovitz.Whisky.SteamLibraryWatcher")

    /// Coalesce bursts of file events (Steam writes many files while installing)
    /// into a single rescan roughly this long after the last change.
    private let debounceInterval: TimeInterval = 2

    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?

    public init(bottle: Bottle) {
        self.bottle = bottle
        self.watchedPaths = Steam.steamLibraryCommonDirectories(in: bottle)
            .map { $0.path(percentEncoded: false) }
    }

    deinit {
        stop()
    }

    /// Begin watching. A no-op when already running or when the bottle has no
    /// Steam `steamapps/common` directory.
    public func start() {
        guard stream == nil, !watchedPaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // Non-capturing C callback: recover `self` from the context `info`.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SteamLibraryWatcher>.fromOpaque(info)
                .takeUnretainedValue()
                .scheduleRescan()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval / 2,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            Logger.wineKit.error(
                "Failed to create Steam library FSEventStream for \(self.bottle.url.lastPathComponent)")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        Logger.wineKit.info(
            "Started Steam library watcher (\(self.watchedPaths.count) path(s)) for \(self.bottle.settings.name)")
    }

    /// Stop watching and release the event stream. Idempotent; safe to call from
    /// `deinit`.
    public func stop() {
        debounce?.cancel()
        debounce = nil

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Debounced rescan trigger. Runs on `queue` (the stream's dispatch queue).
    private func scheduleRescan() {
        debounce?.cancel()

        let bottle = self.bottle
        let work = DispatchWorkItem {
            Logger.wineKit.info("Steam library changed; rescanning \(bottle.settings.name) for D3D9 games")
            Steam.rescanDXVKForD3D9Games(in: bottle)
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}

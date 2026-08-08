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
        !WineProcesses.matching(patterns: ["steam.exe"]).isEmpty
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
            for pid in WineProcesses.matching(patterns: steamProcessPatterns) {
                kill(pid, SIGKILL)
            }
            // SIGKILL is prompt, but reparented children can take a moment to
            // disappear; wait (bounded ~5s) before clearing the server.
            for _ in 0..<25 {
                if WineProcesses.matching(patterns: steamProcessPatterns).isEmpty { break }
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
            for pid in WineProcesses.withWorkingDirectory(under: prefix) {
                kill(pid, SIGKILL)
            }
            // Belt and suspenders: a wineserver whose cwd is not under the prefix
            // is still caught by its WINEPREFIX environment.
            for pid in WineProcesses.wineservers(forPrefix: prefix) {
                kill(pid, SIGKILL)
            }
            // Everything above is SIGKILL, which is precisely what leaves the
            // state cleared below. Reaping without this is a half-measure: the
            // next launch comes up crippled instead of clean.
            clearStaleLocks(in: bottle)
        }
    }

    /// Remove the state a killed Steam leaves behind, so the next launch is not
    /// treated as a second instance.
    ///
    /// Steam's CEF holds Chromium's singleton lock plus a LevelDB `LOCK` per
    /// store under `htmlcache`, and Steam itself keeps a `.crash` marker that it
    /// only deletes on a clean exit. After a SIGKILL — ours above, a crash, or a
    /// wineserver death — all of it survives, and the next start comes up in a
    /// distinctive shape: the browser process runs but spawns no renderers and
    /// creates no window, so Steam sits there with no UI at low CPU. It looks
    /// like a hang, and it is intermittent, because whether it happens depends
    /// entirely on how the *previous* session ended.
    ///
    /// Only safe with no client running — every caller reaps first.
    /// Same failure and same fix as GOG Galaxy's, see `GogGalaxy.clearStaleLocks`.
    static func clearStaleLocks(in bottle: Bottle) {
        let driveC = bottle.url.appending(path: "drive_c")

        // Steam's own "last exit was not clean" marker.
        StaleLocks.remove(
            driveC
                .appending(path: "Program Files (x86)")
                .appending(path: "Steam")
                .appending(path: ".crash"),
            describing: "Steam .crash marker")

        // Chromium's singleton lock, plus the LevelDB LOCK each store under it
        // holds open for the process lifetime.
        let htmlCache =
            driveC
            .appending(path: "users")
            .appending(path: "steamuser")
            .appending(path: "AppData")
            .appending(path: "Local")
            .appending(path: "Steam")
            .appending(path: "htmlcache")
        StaleLocks.remove(htmlCache.appending(path: "lockfile"), describing: "Steam CEF lockfile")
        StaleLocks.removeAll(named: "LOCK", under: htmlCache, describing: "Steam LevelDB LOCK file(s)")
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

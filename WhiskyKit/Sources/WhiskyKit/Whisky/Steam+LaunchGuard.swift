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

import Foundation

// Single-instance launch guard: keeps Steam to one clean CEF login tree.
extension Steam {
    /// Process-name fragments that appear only in Steam's CEF host tree
    /// (`steamwebhelper` and its `cef.win64`/`cef.win32` subprocesses) and the
    /// background service. Matched against full argv with `pkill -f`. Chosen so
    /// they never appear in a launcher's argv (the Whisky app or `WhiskyCmd`) —
    /// only in the Wine-side Steam processes — so a reap can't kill the launcher.
    private static let cefProcessPatterns = ["steamwebhelper", "cef.win64", "cef.win32", "steamservice"]

    /// True when `url` is the Steam client executable — the one launch we guard.
    /// Games and other programs are unaffected (they never trigger a reap).
    public static func isSteamClient(_ url: URL) -> Bool {
        url.lastPathComponent.caseInsensitiveCompare("Steam.exe") == .orderedSame
    }

    /// Reap leftover Steam CEF webhelper processes before launching Steam, then
    /// wait until they're gone, so Steam brings up exactly one login tree.
    ///
    /// Steam's own single-instance mutex does not survive Wine's wineserver
    /// lifecycle: when the server is killed or restarts (frequent in this fork —
    /// Wine rebuilds, `wineserver -k`, crashes), the running `steamwebhelper`
    /// trees are reparented to launchd (PPID 1) and detached from the new server,
    /// so a fresh `wineserver -k` can no longer reach them. Two CEF trees then
    /// fight over the one `-steampid` and the login window never renders. Reaping
    /// them by name is the one reliable way to catch those orphans.
    ///
    /// Deliberately does NOT kill `Steam.exe` itself: its argv is a Windows path
    /// that a launcher's argv (a unix path to the same file) would also match,
    /// risking self-termination of `WhiskyCmd`; and Steam's mutex already
    /// coalesces two clients. Killing the CEF trees is enough — the surviving or
    /// relaunched `Steam.exe` then respawns a single clean webhelper.
    public static func reapCEFProcesses() async {
        await SteamLaunchGuard.shared.serialize {
            for pattern in cefProcessPatterns {
                runManagementTool("/usr/bin/pkill", ["-9", "-f", pattern])
            }
            // SIGKILL is prompt, but reparented CEF children can take a moment to
            // disappear; wait (bounded ~5s) so the launch starts from a clean slate.
            for _ in 0..<25 {
                if !anyCEFProcessRunning() { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private static func anyCEFProcessRunning() -> Bool {
        cefProcessPatterns.contains { runManagementTool("/usr/bin/pgrep", ["-f", $0]) == 0 }
    }

    @discardableResult
    private static func runManagementTool(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
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

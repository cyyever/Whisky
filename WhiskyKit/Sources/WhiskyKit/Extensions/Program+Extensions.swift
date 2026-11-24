//
//  Program+Extensions.swift
//  Whisky
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

import AppKit
import Foundation

extension Program {
    /// GUI entry point: launch this program. Fire-and-forget — the launch (and
    /// its preparation) runs detached; errors surface via an alert.
    public func run() {
        Task.detached(priority: .userInitiated) {
            await self.launch()
        }
    }

    /// The single entry point for launching a program in a bottle. Every caller —
    /// GUI buttons, pins, the file-open sheet, and the CLI — goes through here, so
    /// bottle preparation (Steam's CEF wrapper, DXVK auto-drop) happens exactly
    /// once, and there is only one way to run a program.
    public func launch() async {
        let alreadyLaunching = await MainActor.run { bottle.isLaunching(url) }
        if alreadyLaunching { return }

        let isSteam = Steam.isSteamClient(url)
        // Steam is single-instance: if a client is already running, warn and do not
        // start a second (their CEF trees would fight over the one -steampid). If
        // none is running, reap any orphaned Steam processes — crash / wineserver-kill
        // leftovers, including the background service — so the new one starts clean.
        if isSteam {
            if Steam.isSteamRunning() {
                await showSteamAlreadyRunningAlert()
                return
            }
            await bottle.beginLaunching(
                url,
                status: String(localized: "launch.preparingSteam", defaultValue: "Preparing Steam…")
            )
            await Steam.reapSteamProcesses(in: bottle)
            await bottle.updateLaunchingStatus(
                String(localized: "launch.startingSteam", defaultValue: "Starting Steam…")
            )
        } else {
            let displayName = url.deletingPathExtension().lastPathComponent
            let format = NSLocalizedString("launch.startingProgram", value: "Starting %@…", comment: "")
            await bottle.beginLaunching(url, status: String(format: format, displayName))
        }

        // GOG Galaxy is single-instance too, but decides that from lock files that
        // outlive a killed process — leaving every later launch to quit silently
        // (exit 0, nothing on screen). Clear them when no client is running.
        if GogGalaxy.isGalaxyClient(url), !GogGalaxy.isGalaxyRunning(in: bottle) {
            GogGalaxy.clearStaleLocks(in: bottle)
        }
        do {
            try await Wine.runProgram(
                at: url, bottle: bottle, environment: generateEnvironment()
            )
            if isSteam {
                let targetBottle = bottle
                await Steam.waitForWindowAfterLaunch(in: targetBottle) {
                    await targetBottle.updateLaunchingStatus(
                        String(localized: "launch.loadingSteamUI", defaultValue: "Loading Steam UI…")
                    )
                }
            } else {
                // Keep feedback visible briefly until a window maps (bounded ~3s) so
                // double-clicking an exe never feels unresponsive.
                for _ in 0..<12 {
                    if Steam.hasVisibleBottleWindow(in: bottle) { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            await bottle.endLaunching(url)
            await showRunError(message: error.localizedDescription)
            return
        }
        await bottle.endLaunching(url)
    }

    @MainActor private func showRunError(message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.message")
        alert.informativeText =
            String(localized: "alert.info")
            + " \(self.url.lastPathComponent): "
            + message
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "button.ok"))
        alert.runModal()
    }

    @MainActor private func showSteamAlreadyRunningAlert() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "alert.steamRunning.message", defaultValue: "Steam is already running")
        alert.informativeText = String(
            localized: "alert.steamRunning.info",
            defaultValue: "Quit the running Steam before launching it again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "button.ok"))
        alert.runModal()
    }
}

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
        // Steam is single-instance: if a client is already running, warn and do not
        // start a second (their CEF trees would fight over the one -steampid). If
        // none is running, reap any orphaned Steam processes — crash / wineserver-kill
        // leftovers, including the background service — so the new one starts clean.
        if Steam.isSteamClient(url) {
            if Steam.isSteamRunning() {
                await showSteamAlreadyRunningAlert()
                return
            }
            await Steam.reapSteamProcesses(in: bottle)
        }
        let arguments = settings.arguments.split { $0.isWhitespace }.map(String.init)
        do {
            try await Wine.runProgram(
                at: url, args: arguments, bottle: bottle, environment: generateEnvironment()
            )
        } catch {
            await showRunError(message: error.localizedDescription)
        }
    }

    /// Renders the full `wine …` launch command (env + start line) as a shell
    /// string. Used only to embed the launch in the standalone `.app` shortcut
    /// (see `ProgramShortcut`), never to spawn a Terminal.
    public func generateTerminalCommand() -> String {
        return Wine.generateRunCommand(
            at: self.url, bottle: bottle, args: settings.arguments, environment: generateEnvironment()
        )
    }

    @MainActor private func showRunError(message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.message")
        alert.informativeText = String(localized: "alert.info")
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

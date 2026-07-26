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
        await Wine.prepareForLaunch(bottle: bottle)
        // Launching Steam: reap orphaned CEF webhelper trees first so exactly one
        // login tree comes up (Steam's own mutex can't reap Wine-orphaned ones).
        if Steam.isSteamClient(url) {
            await Steam.reapCEFProcesses()
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
}

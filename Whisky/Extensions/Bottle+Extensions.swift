//
//  Bottle+Extensions.swift
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
import WhiskyKit

extension Bottle {
    func openCDrive() {
        NSWorkspace.shared.open(url.appending(path: "drive_c"))
    }

    func updateInstalledPrograms() {
        let driveC = url.appending(path: "drive_c")
        var programs: [Program] = []
        var foundURLS: Set<URL> = []

        for folderName in ["Program Files", "Program Files (x86)"] {
            let folderURL = driveC.appending(path: folderName)
            let enumerator = FileManager.default.enumerator(
                at: folderURL, includingPropertiesForKeys: [.isExecutableKey], options: [.skipsHiddenFiles]
            )

            while let url = enumerator?.nextObject() as? URL {
                guard !url.hasDirectoryPath && url.pathExtension == "exe" else { continue }
                guard !settings.blocklist.contains(url) else { continue }
                foundURLS.insert(url)
                programs.append(Program(url: url, bottle: self))
            }
        }

        // Add missing programs from pins
        for pin in settings.pins {
            guard let url = pin.url else { continue }
            guard !foundURLS.contains(url) else { continue }
            programs.append(Program(url: url, bottle: self))
        }

        self.programs = programs.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    @MainActor
    func move(destination: URL) {
        do {
            if let bottle = BottleVM.shared.bottles.first(where: { $0.url == url }) {
                bottle.inFlight = true
                for index in 0..<bottle.settings.pins.count {
                    let pin = bottle.settings.pins[index]
                    if let url = pin.url {
                        bottle.settings.pins[index].url = url.updateParentBottle(old: url,
                                                                                 new: destination)
                    }
                }

                for index in 0..<bottle.settings.blocklist.count {
                    let blockedUrl = bottle.settings.blocklist[index]
                    bottle.settings.blocklist[index] = blockedUrl.updateParentBottle(old: url,
                                                                                     new: destination)
                }
            }
            try FileManager.default.moveItem(at: url, to: destination)
            if let path = BottleVM.shared.bottlesList.paths.firstIndex(of: url) {
                BottleVM.shared.bottlesList.paths[path] = destination
            }
            BottleVM.shared.loadBottles()
        } catch {
            print("Failed to move bottle")
        }
    }

    @MainActor
    func remove(delete: Bool) {
        do {
            if let bottle = BottleVM.shared.bottles.first(where: { $0.url == url }) {
                bottle.inFlight = true
            }

            if delete {
                try FileManager.default.removeItem(at: url)
            }

            if let path = BottleVM.shared.bottlesList.paths.firstIndex(of: url) {
                BottleVM.shared.bottlesList.paths.remove(at: path)
            }
            BottleVM.shared.loadBottles()
        } catch {
            print("Failed to remove bottle")
        }
    }

    @MainActor
    func rename(newName: String) {
        settings.name = newName
    }
}

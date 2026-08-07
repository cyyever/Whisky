//
//  BottleVM.swift
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

import Foundation
import SemanticVersion
import WhiskyKit

// swiftlint:disable:next todo
// TODO: Don't use unchecked!
final class BottleVM: ObservableObject, @unchecked Sendable {
    @MainActor static let shared = BottleVM()

    var bottlesList = BottleData()
    @Published var bottles: [Bottle] = []

    @MainActor
    func loadBottles() {
        bottles = bottlesList.loadBottles()
    }

    func countActive() -> Int {
        return bottles.filter { $0.isAvailable == true }.count
    }

    func createNewBottle(bottleName: String, winVersion: WinVersion, bottleURL: URL) -> URL {
        let newBottleDir = bottleURL.appending(path: UUID().uuidString)

        Task.detached {
            var bottleId: Bottle?
            do {
                try FileManager.default.createDirectory(
                    atPath: newBottleDir.path(percentEncoded: false),
                    withIntermediateDirectories: true)
                let bottle = Bottle(bottleUrl: newBottleDir, inFlight: true)
                bottleId = bottle

                await MainActor.run {
                    self.bottles.append(bottle)
                }

                bottle.settings.windowsVersion = winVersion
                bottle.settings.name = bottleName
                // The winemac.drv=d init workaround (macOS-26 WM_TIMER wineboot hang)
                // was dropped 2026-07-25: the hang is gone on proton-wine 11.0 —
                // wineboot --init completes in ~14s with winemac.drv enabled (mirrors
                // the dropped patch 0007). Re-add the environment override if a fresh
                // GUI bottle creation hangs.
                try await Wine.changeWinVersion(bottle: bottle, win: winVersion)
                // Read the installed version from the version plist instead of spawning
                // `wine --version` (bottle: nil): that global wine call can hang when a
                // wineserver is churning, which would leave the bottle `inFlight` forever
                // (loadBottles below never runs) with all its controls disabled until an app
                // restart. Reading the plist has no subprocess, so bottle creation can't stall.
                bottle.settings.wineVersion = WhiskyWineInstaller.whiskyWineVersion() ?? SemanticVersion(0, 0, 0)
                // Add record
                await MainActor.run {
                    self.bottlesList.paths.append(newBottleDir)
                    self.loadBottles()
                }
            } catch {
                print("Failed to create new bottle: \(error)")
                if let bottle = bottleId {
                    await MainActor.run {
                        if let index = self.bottles.firstIndex(of: bottle) {
                            self.bottles.remove(at: index)
                        }
                    }
                }
            }
        }
        return newBottleDir
    }
}

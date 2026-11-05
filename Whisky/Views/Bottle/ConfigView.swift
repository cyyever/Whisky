//
//  ConfigView.swift
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

import SwiftUI
import WhiskyKit

struct ConfigView: View {
    /// Apple family 9 GPUs (A17, M3, M4) support hardware ray tracing. The
    /// capability is fixed for the machine, so resolve it once instead of
    /// allocating a Metal device on every body re-render.
    private static let supportsRaytracing =
        MTLCreateSystemDefaultDevice()?.supportsFamily(.apple9) ?? false

    @ObservedObject var bottle: Bottle
    @AppStorage("wineSectionExpanded") private var wineSectionExpanded: Bool = true
    @AppStorage("advancedSectionExpanded") private var advancedSectionExpanded: Bool = false

    var body: some View {
        Form {
            Section("config.title.wine", isExpanded: $wineSectionExpanded) {
                // Enhanced Sync selector removed: the backend is locked to msync on
                // this stack (macOS has no eventfd for esync). `enhancedSync` stays in
                // the model at its `.msync` default for decode compat.
                Toggle(isOn: $bottle.settings.followSystemProxy) {
                    Text("config.followSystemProxy")
                    Text("config.followSystemProxy.info")
                }
            }
            if Self.supportsRaytracing {
                Section("config.title.advanced", isExpanded: $advancedSectionExpanded) {
                    Toggle(isOn: $bottle.settings.dxrEnabled) {
                        Text("config.dxr")
                        Text("config.dxr.info")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(.whiskyDefault, value: wineSectionExpanded)
        .animation(.whiskyDefault, value: advancedSectionExpanded)
        .navigationTitle("tab.config")
    }
}

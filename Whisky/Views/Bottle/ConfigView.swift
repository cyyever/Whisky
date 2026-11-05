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

enum LoadingState {
    case loading
    case modifying
    case success
    case failed
}

struct ConfigView: View {
    /// Apple family 9 GPUs (A17, M3, M4) support hardware ray tracing. The
    /// capability is fixed for the machine, so resolve it once instead of
    /// allocating a Metal device on every body re-render.
    private static let supportsRaytracing =
        MTLCreateSystemDefaultDevice()?.supportsFamily(.apple9) ?? false

    @ObservedObject var bottle: Bottle
    @State private var retinaMode: Bool = false
    @State private var retinaModeLoadingState: LoadingState = .loading
    @AppStorage("wineSectionExpanded") private var wineSectionExpanded: Bool = true
    @AppStorage("advancedSectionExpanded") private var advancedSectionExpanded: Bool = false

    var body: some View {
        Form {
            Section("config.title.wine", isExpanded: $wineSectionExpanded) {
                // The Wine backend and Windows 11 mode are fixed for every bottle.
                SettingItemView(title: "config.retinaMode", loadingState: retinaModeLoadingState) {
                    Toggle("config.retinaMode", isOn: $retinaMode)
                        .onChange(
                            of: retinaMode,
                            { _, newValue in
                                Task(priority: .userInitiated) {
                                    retinaModeLoadingState = .modifying
                                    do {
                                        try await Wine.changeRetinaMode(bottle: bottle, retinaMode: newValue)
                                        retinaModeLoadingState = .success
                                    } catch {
                                        print("Failed to change Retina mode: \(error)")
                                        retinaModeLoadingState = .failed
                                    }
                                }
                            })
                }
                // Enhanced Sync selector removed: the backend is locked to msync on
                // this stack (macOS has no eventfd for esync). `enhancedSync` stays in
                // the model at its `.msync` default for decode compat.
                Toggle(isOn: $bottle.settings.followSystemProxy) {
                    Text("config.followSystemProxy")
                    Text("config.followSystemProxy.info")
                }
                Toggle(isOn: $bottle.settings.hideVirtualAudioDevices) {
                    Text("config.hideVirtualAudioDevices")
                    Text("config.hideVirtualAudioDevices.info")
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
        .onAppear {
            Task(priority: .userInitiated) {
                do {
                    retinaMode = try await Wine.retinaMode(bottle: bottle)
                    retinaModeLoadingState = .success
                } catch {
                    print(error)
                    retinaModeLoadingState = .failed
                }
            }
        }
    }

}

struct SettingItemView<Content: View>: View {
    let title: String.LocalizationValue
    let loadingState: LoadingState
    @ViewBuilder var content: () -> Content

    @Namespace private var viewId
    @Namespace private var progressViewId

    var body: some View {
        HStack {
            Text(String(localized: title))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                switch loadingState {
                case .loading, .modifying:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .matchedGeometryEffect(id: progressViewId, in: viewId)
                case .success:
                    content()
                        .labelsHidden()
                        .disabled(loadingState != .success)
                case .failed:
                    Text("config.notAvailable")
                        .font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                }
            }.animation(.default, value: loadingState)
        }
    }
}

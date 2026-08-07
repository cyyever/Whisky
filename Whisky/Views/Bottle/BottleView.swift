//
//  BottleView.swift
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
import UniformTypeIdentifiers
import WhiskyKit

enum BottleStage {
    case config
}

struct BottleView: View {
    @ObservedObject var bottle: Bottle
    @State private var path = NavigationPath()
    @State private var programLoading: Bool = false
    /// Non-nil while a gaming-platform installer is downloading (shown next to the spinner).
    @State private var loadingStatus: String?
    /// Non-nil surfaces an install/run failure in an alert.
    @State private var installError: String?

    private let gridLayout = [GridItem(.adaptive(minimum: 100, maximum: .infinity))]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: gridLayout, alignment: .center) {
                    ForEach(bottle.pinnedPrograms, id: \.id) { pinnedProgram in
                        PinView(
                            bottle: bottle, program: pinnedProgram.program, pin: pinnedProgram.pin, path: $path
                        )
                    }
                    // Sits with the programs it adds: fetch a known gaming
                    // platform's installer, or pick a local file. Whatever it
                    // launches joins the grid, so there is no separate "pin" step.
                    addProgramMenu
                }
                .padding()
                Form {
                    NavigationLink(value: BottleStage.config) {
                        Label("tab.config", systemImage: "gearshape")
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }
            .bottomBar {
                HStack {
                    Spacer()
                    Button("button.cDrive") {
                        bottle.openCDrive()
                    }
                    .accessibilityIdentifier("bottle.cDrive")
                    if programLoading {
                        Spacer()
                            .frame(width: 10)
                        if let loadingStatus {
                            Text(loadingStatus)
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding()
            }
            .alert(
                "menu.platformInstallFailed",
                isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })
            ) {
                Button(role: .cancel) {
                    installError = nil
                } label: {
                    Text(verbatim: "OK")
                }
            } message: {
                if let installError { Text(installError) }
            }
            .disabled(!bottle.isAvailable)
            .navigationTitle(bottle.settings.name)
            .onChange(of: bottle.settings) { oldValue, newValue in
                guard oldValue != newValue else { return }
                // Trigger a reload
                BottleVM.shared.bottles = BottleVM.shared.bottles
            }
            .navigationDestination(for: BottleStage.self) { _ in
                ConfigView(bottle: bottle)
            }
            .navigationDestination(for: Program.self) { program in
                ProgramView(program: program)
            }
        }
    }

    /// The grid's trailing tile: a menu of gaming-platform installers plus a
    /// "choose a local file" escape hatch. Sized to match `PinView` so it reads
    /// as the last item in the program grid.
    private var addProgramMenu: some View {
        VStack {
            Menu {
                Section("menu.installPlatform") {
                    ForEach(GamingPlatform.all) { platform in
                        Button {
                            install(platform)
                        } label: {
                            Label {
                                Text(verbatim: platform.name)
                            } icon: {
                                Image(systemName: platform.symbol)
                            }
                        }
                        .accessibilityIdentifier("install." + platform.name)
                    }
                }
                Divider()
                Button {
                    runFileFromPanel()
                } label: {
                    Label("menu.chooseFile", systemImage: "folder")
                }
                .accessibilityIdentifier("bottle.chooseFile")
            } label: {
                Image(systemName: "plus.circle")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // .fixedSize keeps the borderless menu from stretching the tile's
            // width, which would pull the glyph off-centre from its caption.
            .fixedSize()
            .frame(width: 45, height: 45)
            .accessibilityLabel("button.addProgram")
            .accessibilityIdentifier("bottle.installRun")
            .disabled(programLoading)
            Spacer()
            Text("button.addProgram")
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(width: 90, height: 90)
        .padding(10)
    }

    /// Download the platform's official installer into the bottle and launch it.
    private func install(_ platform: GamingPlatform) {
        programLoading = true
        loadingStatus = String(
            format: NSLocalizedString("menu.platformInstalling", comment: ""), platform.name
        )
        Task(priority: .userInitiated) {
            do {
                try await GamingPlatformInstaller.install(platform, in: bottle)
            } catch {
                installError = error.localizedDescription
            }
            programLoading = false
            loadingStatus = nil
        }
    }

    /// Pick a local `.exe`/`.msi` and run it in the bottle. Whatever the user
    /// picks is also added to the grid, so the bottle's home is the list of
    /// programs they have actually run — no separate "pin" step.
    private func runFileFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType.exe,
            UTType(exportedAs: "com.microsoft.msi-installer"),
        ]
        panel.directoryURL = bottle.url.appending(path: "drive_c")
        panel.begin { result in
            guard result == .OK, let url = panel.urls.first else { return }
            programLoading = true
            Task(priority: .userInitiated) {
                // Single launch entry: `Program.launch` handles .bat vs .exe/.msi
                // and bottle preparation, and surfaces its own errors.
                let program = Program(url: url, bottle: bottle)
                if !program.pinned { program.pinned = true }
                await program.launch()
                programLoading = false
            }
        }
    }

}

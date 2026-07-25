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
    case programs
    case processes
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
                    PinAddView(bottle: bottle)
                }
                .padding()
                Form {
                    NavigationLink(value: BottleStage.programs) {
                        Label("tab.programs", systemImage: "list.bullet")
                    }
                    NavigationLink(value: BottleStage.config) {
                        Label("tab.config", systemImage: "gearshape")
                    }
//                    NavigationLink(value: BottleStage.processes) {
//                        Label("tab.processes", systemImage: "hockey.puck.circle")
//                    }
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
                    Button("button.terminal") {
                        bottle.openTerminal()
                    }
                    .accessibilityIdentifier("bottle.terminal")
                    // One entry point for getting a program into the bottle: fetch
                    // a known gaming platform's installer, or pick a local file.
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
                        Text("button.installOrRun")
                    }
                    .accessibilityLabel("button.installOrRun")
                    .accessibilityIdentifier("bottle.installRun")
                    .fixedSize()
                    .disabled(programLoading)
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
                Button(role: .cancel) { installError = nil } label: { Text(verbatim: "OK") }
            } message: {
                if let installError { Text(installError) }
            }
            .onAppear {
                updateStartMenu()
            }
            .disabled(!bottle.isAvailable)
            .navigationTitle(bottle.settings.name)
            .onChange(of: bottle.settings) { oldValue, newValue in
                guard oldValue != newValue else { return }
                // Trigger a reload
                BottleVM.shared.bottles = BottleVM.shared.bottles
            }
            .navigationDestination(for: BottleStage.self) { stage in
                switch stage {
                case .config:
                    ConfigView(bottle: bottle)
                case .programs:
                    ProgramsView(
                        bottle: bottle, path: $path
                    )
                case .processes:
                    RunningProcessesView(bottle: bottle)
                }
            }
            .navigationDestination(for: Program.self) { program in
                ProgramView(program: program)
            }
        }
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
            updateStartMenu()
        }
    }

    /// Pick a local `.exe`/`.msi`/`.bat` and run it in the bottle (the classic
    /// "Run..." flow, folded into the unified install/run menu).
    private func runFileFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.exe,
                                     UTType(exportedAs: "com.microsoft.msi-installer"),
                                     UTType(exportedAs: "com.microsoft.bat")]
        panel.directoryURL = bottle.url.appending(path: "drive_c")
        panel.begin { result in
            guard result == .OK, let url = panel.urls.first else { return }
            programLoading = true
            Task(priority: .userInitiated) {
                do {
                    if url.pathExtension == "bat" {
                        try await Wine.runBatchFile(url: url, bottle: bottle)
                    } else {
                        try await Wine.runProgram(at: url, bottle: bottle)
                    }
                } catch {
                    installError = error.localizedDescription
                }
                programLoading = false
                updateStartMenu()
            }
        }
    }

    private func updateStartMenu() {
        bottle.updateInstalledPrograms()

        let startMenuPrograms = bottle.getStartMenuPrograms()
        for startMenuProgram in startMenuPrograms {
            for program in bottle.programs where
            // For some godforsaken reason "foo/bar" != "foo/Bar" so...
            program.url.path().caseInsensitiveCompare(startMenuProgram.url.path()) == .orderedSame {
                program.pinned = true
                guard !bottle.settings.pins.contains(where: { $0.url == program.url }) else { return }
                bottle.settings.pins.append(PinnedProgram(
                    name: program.url.deletingPathExtension().lastPathComponent,
                    url: program.url
                ))
            }
        }
    }
}

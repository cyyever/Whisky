//
//  ContentView.swift
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

struct ContentView: View {
    @AppStorage("selectedBottleURL") private var selectedBottleURL: URL?
    @EnvironmentObject var bottleVM: BottleVM
    @Binding var showSetup: Bool

    @State private var selected: URL?
    @State private var showBottleCreation: Bool = false
    @State private var bottlesLoaded: Bool = false
    @State private var showBottleSelection: Bool = false
    @State private var newlyCreatedBottleURL: URL?
    @State private var openedFileURL: URL?
    @State private var triggerRefresh: Bool = false
    @State private var refreshAnimation: Angle = .degrees(0)

    @State private var bottleFilter = ""

    // Watches the active bottle's Steam library so a game installed/updated from
    // inside Steam's own UI still gets its DXVK d3d9.dll dropped (that launch
    // path bypasses Whisky's runProgram, so the scan would otherwise not run).
    // One watcher at a time, swapped as the selection changes — never leaked.
    @State private var libraryWatcher: SteamLibraryWatcher?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showBottleCreation.toggle()
                } label: {
                    Image(systemName: "plus")
                        .help("button.createBottle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    bottleVM.loadBottles()
                    if let bottle = bottleVM.bottles.first(where: { $0.url == selected }) {
                        bottle.updateInstalledPrograms()
                    }
                    triggerRefresh.toggle()
                    withAnimation(.default) {
                        refreshAnimation = .degrees(360)
                    } completion: {
                        refreshAnimation = .degrees(0)
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .help("button.refresh")
                        .rotationEffect(refreshAnimation)
                }
            }
        }
        .sheet(isPresented: $showBottleCreation) {
            BottleCreationView(newlyCreatedBottleURL: $newlyCreatedBottleURL)
        }
        .sheet(isPresented: $showSetup) {
            SetupView(showSetup: $showSetup, firstTime: false)
        }
        .sheet(item: $openedFileURL) { url in
            FileOpenView(fileURL: url,
                         currentBottle: selected,
                         bottles: bottleVM.bottles)
        }
        .onChange(of: selected) {
            selectedBottleURL = selected
            updateLibraryWatcher(for: selected)
        }
        .onDisappear {
            libraryWatcher?.stop()
            libraryWatcher = nil
        }
        .handlesExternalEvents(preferring: [], allowing: ["*"])
        .onOpenURL { url in
            openedFileURL = url
        }
        .task {
            bottleVM.loadBottles()
            bottlesLoaded = true

            if !bottleVM.bottles.isEmpty || bottleVM.countActive() != 0 {
                if let bottle = bottleVM.bottles.first(where: { $0.url == selectedBottleURL && $0.isAvailable }) {
                    selected = bottle.url
                } else {
                    selected = bottleVM.bottles[0].url
                }
            }

            if !WhiskyWineInstaller.isWhiskyWineInstalled() {
                showSetup = true
            }

            updateLibraryWatcher(for: selected)
        }
    }

    /// Start watching the newly-active bottle's Steam library (and stop watching
    /// the previous one). A no-op bottle — no Steam, or none selected — leaves no
    /// watcher running, so watchers are never leaked or duplicated.
    private func updateLibraryWatcher(for url: URL?) {
        libraryWatcher?.stop()
        libraryWatcher = nil

        guard let url, let bottle = bottleVM.bottles.first(where: { $0.url == url }) else { return }
        let watcher = SteamLibraryWatcher(bottle: bottle)
        watcher.start()
        libraryWatcher = watcher
    }

    var sidebar: some View {
        ScrollViewReader { proxy in
            List(selection: $selected) {
                Section {
                    ForEach(filteredBottles) { bottle in
                        Group {
                            if bottle.inFlight {
                                HStack {
                                    Text(bottle.settings.name)
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                }
                                .opacity(0.5)
                            } else {
                                BottleListEntry(bottle: bottle, selected: $selected, refresh: $triggerRefresh)
                                    .selectionDisabled(!bottle.isAvailable)
                            }
                        }
                        .id(bottle.url)
                    }
                }
            }
            .animation(.default, value: bottleVM.bottles)
            .animation(.default, value: bottleFilter)
            .listStyle(.sidebar)
            .searchable(text: $bottleFilter, placement: .sidebar)
            .onChange(of: newlyCreatedBottleURL) { _, url in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    selected = url
                    withAnimation {
                        proxy.scrollTo(url, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    var detail: some View {
        if let bottle = selected {
            if let bottle = bottleVM.bottles.first(where: { $0.url == bottle }) {
                BottleView(bottle: bottle)
                    .disabled(bottle.inFlight)
                    .id(bottle.url)
            }
        } else {
            if (bottleVM.bottles.isEmpty || bottleVM.countActive() == 0) && bottlesLoaded {
                VStack {
                    Text("main.createFirst")
                    Button {
                        showBottleCreation.toggle()
                    } label: {
                        HStack {
                            Image(systemName: "plus")
                            Text("button.createBottle")
                        }
                        .padding(6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                }
            }
        }
    }

    var filteredBottles: [Bottle] {
        if bottleFilter.isEmpty {
            bottleVM.bottles
                .sorted()
        } else {
            bottleVM.bottles
                .filter { $0.settings.name.localizedCaseInsensitiveContains(bottleFilter) }
                .sorted()
        }
    }
}

#Preview {
    ContentView(showSetup: .constant(false))
        .environmentObject(BottleVM.shared)
}

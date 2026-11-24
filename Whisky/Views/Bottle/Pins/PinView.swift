//
//  PinView.swift
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

struct PinView: View {
    @ObservedObject var bottle: Bottle
    @ObservedObject var program: Program
    @State var pin: PinnedProgram  // swiftlint:disable:this private_swiftui_state
    @Binding var path: NavigationPath

    @State private var image: Image?
    @State private var showRenameSheet = false
    @State private var name: String = ""
    @State private var pulse = false

    private var isLaunching: Bool {
        bottle.isLaunching(program.url)
    }

    var body: some View {
        VStack {
            ZStack {
                if isLaunching {
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(pulse ? 0.25 : 0.85), lineWidth: 2.5)
                        .frame(width: 56, height: 56)
                        .scaleEffect(pulse ? 1.14 : 0.94)
                }
                Group {
                    if let image {
                        image
                            .resizable()
                    } else {
                        Image(systemName: "app.dashed")
                            .resizable()
                    }
                }
                .frame(width: 45, height: 45)
                .opacity(isLaunching ? (pulse ? 0.55 : 0.9) : 1.0)
                .scaleEffect(isLaunching ? (pulse ? 0.92 : 1.0) : 1.0)

                if isLaunching {
                    ProgressView()
                        .controlSize(.regular)
                        .padding(6)
                        .background(.regularMaterial, in: Circle())
                        .shadow(radius: 2)
                }
            }
            .frame(width: 56, height: 56)
            Spacer()
            Text(isLaunching ? (bottle.launchingStatus ?? String(localized: "launch.startingShort")) : name)
                .foregroundStyle(isLaunching ? Color.accentColor : Color.primary)
                .fontWeight(isLaunching ? .medium : .regular)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(width: 96, height: 96)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isLaunching ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay {
            if !isLaunching {
                HStack {
                    Spacer()
                    Button {
                        program.run()
                    } label: {
                        Image(systemName: "play.fill")
                            .resizable()
                            .foregroundColor(.green)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 45, height: 45)
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
            }
        }
        .animation(.whiskyDefault, value: isLaunching)
        .onChange(of: isLaunching, initial: true) { _, launching in
            if launching {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    pulse = false
                }
            }
        }
        .contextMenu {
            ProgramMenuView(program: program, path: $path)

            Button("button.rename", systemImage: "pencil.line") {
                showRenameSheet.toggle()
            }
            .labelStyle(.titleAndIcon)
            Button("button.showInFinder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([program.url])
            }
            .labelStyle(.titleAndIcon)
        }
        .onTapGesture(count: 2) {
            guard !isLaunching else { return }
            program.run()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(name)
        .accessibilityIdentifier("pin." + (pin.url?.lastPathComponent ?? pin.name))
        .accessibilityAction {
            program.run()
        }
        .accessibilityAction(named: Text("button.rename")) {
            showRenameSheet.toggle()
        }
        .accessibilityAction(named: Text("button.showInFinder")) {
            NSWorkspace.shared.activateFileViewerSelecting([program.url])
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameView("rename.pin.title", name: name) { newName in
                name = newName
            }
        }
        .task {
            name = pin.name
            guard let peFile = program.peFile else { return }
            let task = Task.detached {
                guard let image = peFile.bestIcon() else { return nil as Image? }
                return Image(nsImage: image)
            }
            self.image = await task.value
        }
        .onChange(of: name) {
            if let index = bottle.settings.pins.firstIndex(where: {
                let exists = FileManager.default.fileExists(atPath: pin.url?.path(percentEncoded: false) ?? "")
                return $0.url == pin.url && exists
            }) {
                bottle.settings.pins[index].name = name
            }
        }
    }
}

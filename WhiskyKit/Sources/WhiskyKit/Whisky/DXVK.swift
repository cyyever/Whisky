//
//  DXVK.swift
//  WhiskyKit
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
import os.log

/// DXVK provides D3D9 (and D3D8) on macOS: wined3d's D3D9/D3D8 path is broken here
/// (GL black screen / no fixed-function on Vulkan) and DXMT does not implement them,
/// so DXVK is the only working route.
///
/// It is installed the same way DXMT is — into the Wine layer, not per game. The
/// DXVK `d3d9.dll`/`d3d8.dll` (built by `make dxvk` into `Libraries/DXVK/{win32,win64}`)
/// are copied into the bottle's Windows system directories and enabled with a
/// global `native` DLL override, so Wine loads DXVK for *any* d3d9/d3d8 game with
/// the right architecture chosen automatically. No per-game PE scan, no watcher.
///
/// A game that ships its own `d3d9.dll` next to its executable still wins: Windows
/// resolves an exe's imports from its own directory before system32, so the
/// system copy only serves games that don't bring their own.
public enum DXVK {
    /// The `make dxvk` payload, split by architecture.
    private static let payloadFolder: URL = WhiskyWineInstaller.libraryFolder
        .appending(path: "DXVK")

    /// Registry key holding per-DLL load-order overrides.
    private static let dllOverridesKey = #"HKCU\Software\Wine\DllOverrides"#

    /// Payload arch subdir → the bottle system directory it installs into.
    /// Under WoW64, `system32` is 64-bit and `syswow64` is 32-bit.
    private static let systemInstalls: [(archSubdir: String, systemDir: String)] = [
        ("win64", "system32"),
        ("win32", "syswow64")
    ]

    /// Install DXVK's `d3d9`/`d3d8` into `bottle`'s system directories and set the
    /// global `native` override for each one actually installed. Idempotent — after
    /// the first install it re-copies only when the payload changes (DXVK rebuild),
    /// and rewrites the override only when it (re)copies, so a steady-state launch
    /// is a handful of `stat`s.
    ///
    /// A no-op when the payload is not built (`make dxvk`): the override is left
    /// unset, so a d3d9 game fails loudly rather than silently white-screening on
    /// the broken wined3d path.
    public static func installSystemDLLs(in bottle: Bottle) async {
        let fileManager = FileManager.default

        for dll in ["d3d9.dll", "d3d8.dll"] {
            var copied = false
            for (archSubdir, systemDir) in systemInstalls {
                let source = payloadFolder.appending(path: archSubdir).appending(path: dll)
                guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
                let dest = bottle.url.appending(path: "drive_c/windows/\(systemDir)/\(dll)")
                if install(source, to: dest, fileManager: fileManager) { copied = true }
            }

            // Only touch the registry when the dll was actually (re)written, to keep
            // steady-state launches from re-spawning `wine reg` every time.
            if copied {
                // `native` (not `native,builtin`): the builtin wined3d D3D9/D3D8 is
                // broken on macOS, so a fallback to it only masks the failure.
                try? await Wine.addRegistryKey(
                    bottle: bottle, key: dllOverridesKey, name: String(dll.dropLast(4)),
                    data: "native", type: .string
                )
            }
        }
    }

    /// Copy `source` → `dest` (creating the system dir) unless a same-size file is
    /// already there. Returns `true` only when it actually wrote the file, so the
    /// caller can gate the registry write on a real change.
    @discardableResult
    private static func install(_ source: URL, to dest: URL, fileManager: FileManager) -> Bool {
        if fileSize(of: source) == fileSize(of: dest) { return false }
        do {
            try fileManager.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dest.path(percentEncoded: false)) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(at: source, to: dest)
            Logger.wineKit.info(
                "Installed DXVK \(dest.lastPathComponent) into \(dest.deletingLastPathComponent().lastPathComponent)")
            return true
        } catch {
            Logger.wineKit.error("Failed to install DXVK \(dest.lastPathComponent): \(error)")
            return false
        }
    }

    private static func fileSize(of url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
}

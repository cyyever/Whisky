//
//  Steam.swift
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

/// Steam-specific compatibility shims.
///
/// Steam's CEF host (`steamwebhelper.exe`) renders a black window under Wine on
/// macOS because its sandbox hooks into the NT kernel and its out-of-process GPU
/// cannot reset the D3D device. We work around this by replacing the CEF host
/// with a small wrapper (see `SteamHelper/webhelper_wrapper.c`) that re-launches
/// the genuine binary with `--no-sandbox --in-process-gpu --disable-gpu
/// --disable-gpu-compositing`.
public enum Steam {
    /// The compiled wrapper, installed next to the Wine libraries by
    /// `scripts/build-webhelper-wrapper.sh`.
    private static let wrapperBinary: URL = WhiskyWineInstaller.libraryFolder
        .appending(path: "SteamHelper")
        .appending(path: "steamwebhelper_wrapper.exe")

    /// Relative paths inside `drive_c` where Steam may be installed.
    private static let steamRoots = [
        "Program Files (x86)/Steam",
        "Program Files/Steam"
    ]

    /// Install (or refresh) the webhelper wrapper in every 64-bit CEF directory
    /// found in the bottle. Idempotent and safe to call on every Steam launch:
    /// it is a no-op when Steam is absent, and it re-installs itself after a
    /// Steam update overwrites `steamwebhelper.exe`.
    public static func installWebhelperWrapper(in bottle: Bottle) {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: wrapperBinary.path(percentEncoded: false)) else {
            Logger.wineKit.info("Steam webhelper wrapper not built; skipping install")
            return
        }

        for cefDir in cefDirectories(in: bottle) {
            installWrapper(into: cefDir, fileManager: fileManager)
        }
    }

    /// All 64-bit CEF directories (e.g. `cef.win64`, `cef.win7x64`) that contain
    /// a `steamwebhelper.exe`.
    private static func cefDirectories(in bottle: Bottle) -> [URL] {
        let fileManager = FileManager.default
        var directories: [URL] = []

        for root in steamRoots {
            let cefParent = bottle.url
                .appending(path: "drive_c")
                .appending(path: root)
                .appending(path: "bin/cef")

            guard let entries = try? fileManager.contentsOfDirectory(
                at: cefParent, includingPropertiesForKeys: nil
            ) else { continue }

            for entry in entries where entry.lastPathComponent.lowercased().contains("64") {
                let helper = entry.appending(path: "steamwebhelper.exe")
                if fileManager.fileExists(atPath: helper.path(percentEncoded: false)) {
                    directories.append(entry)
                }
            }
        }

        return directories
    }

    private static func installWrapper(into cefDir: URL, fileManager: FileManager) {
        let helper = cefDir.appending(path: "steamwebhelper.exe")
        let real = cefDir.appending(path: "steamwebhelper_real.exe")

        let helperSize = fileSize(of: helper)
        let wrapperSize = fileSize(of: wrapperBinary)

        // Already our wrapper (and the genuine binary is preserved): nothing to do.
        if helperSize == wrapperSize, fileManager.fileExists(atPath: real.path(percentEncoded: false)) {
            return
        }

        do {
            // The current steamwebhelper.exe is the genuine binary (fresh install,
            // or a Steam update overwrote our wrapper). Preserve it as the _real
            // target, replacing any stale backup.
            if helperSize != wrapperSize {
                if fileManager.fileExists(atPath: real.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: real)
                }
                try fileManager.copyItem(at: helper, to: real)
            }

            // Swap in the wrapper.
            try fileManager.removeItem(at: helper)
            try fileManager.copyItem(at: wrapperBinary, to: helper)
            Logger.wineKit.info("Installed Steam webhelper wrapper in \(cefDir.lastPathComponent)")
        } catch {
            Logger.wineKit.error("Failed to install Steam webhelper wrapper: \(error)")
        }
    }

    private static func fileSize(of url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
}

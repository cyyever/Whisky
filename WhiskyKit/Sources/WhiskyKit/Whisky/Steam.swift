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
/// cannot reset the D3D device. We work around this by wrapping the CEF host with
/// a small launcher (see `SteamHelper/webhelper_wrapper.c`) that re-launches the
/// genuine binary with `--no-sandbox --in-process-gpu --disable-gpu
/// --disable-gpu-compositing`.
///
/// The wrapper is attached via the image's "Debugger" Image File Execution
/// Options entry (see `ifeoDebuggerKey`) rather than by overwriting
/// `steamwebhelper.exe`. That keeps the on-disk binary byte-identical to Valve's,
/// so Steam's startup file verification passes and it no longer re-downloads the
/// client on every launch.
public enum Steam {
    /// The compiled wrapper, installed next to the Wine libraries by
    /// `scripts/build-webhelper-wrapper.sh`.
    private static let wrapperBinary: URL = WhiskyWineInstaller.libraryFolder
        .appending(path: "SteamHelper")
        .appending(path: "steamwebhelper_wrapper.exe")

    /// Where the wrapper is installed inside the bottle (the IFEO Debugger value
    /// points here). Kept in `C:\windows` so a single copy serves every CEF dir.
    private static let wrapperBottlePath = "drive_c/windows/steamwebhelper_wrapper.exe"

    /// Registry key whose `Debugger` value tells Wine to launch the wrapper
    /// whenever `steamwebhelper.exe` starts.
    private static let ifeoDebuggerKey =
        #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\steamwebhelper.exe"#

    /// `Debugger` value: the wrapper's Windows path, quoted so spaces are safe.
    private static let ifeoDebuggerValue = #""C:\windows\steamwebhelper_wrapper.exe""#

    /// Relative paths inside `drive_c` where Steam may be installed.
    private static let steamRoots = [
        "Program Files (x86)/Steam",
        "Program Files/Steam"
    ]

    /// Make a bottle ready to run Steam's CEF host under Wine: install the
    /// webhelper wrapper and, when Steam is present, attach it via the image's
    /// IFEO `Debugger` value (keeping `steamwebhelper.exe` genuine so Steam's
    /// verification passes). Idempotent and a no-op when Steam is absent; safe to
    /// call before launching any program.
    public static func configure(in bottle: Bottle) async {
        guard installWebhelperWrapper(in: bottle) else { return }
        try? await Wine.addRegistryKey(
            bottle: bottle, key: ifeoDebuggerKey, name: "Debugger",
            data: ifeoDebuggerValue, type: .string
        )
    }

    /// Install (or refresh) the webhelper wrapper and make sure the genuine
    /// `steamwebhelper.exe` is in place. Returns `true` when Steam was found.
    @discardableResult
    private static func installWebhelperWrapper(in bottle: Bottle) -> Bool {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: wrapperBinary.path(percentEncoded: false)) else {
            Logger.wineKit.info("Steam webhelper wrapper not built; skipping install")
            return false
        }

        let cefDirs = cefDirectories(in: bottle)
        guard !cefDirs.isEmpty else { return false }

        // One wrapper copy in the bottle; the IFEO Debugger value points at it.
        let wrapperDest = bottle.url.appending(path: wrapperBottlePath)
        installFile(wrapperBinary, to: wrapperDest, fileManager: fileManager)

        for cefDir in cefDirs {
            prepareCefDirectory(cefDir, fileManager: fileManager)
        }
        return true
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

    /// Make a CEF directory ready for the IFEO-based wrapper:
    /// 1. If `steamwebhelper.exe` is an old-style wrapper copy, restore the
    ///    genuine binary from `steamwebhelper_real.exe` so verification passes.
    /// 2. Ensure `steamwebhelper_real.exe` is a current copy of the genuine
    ///    binary — that is what the wrapper actually launches.
    private static func prepareCefDirectory(_ cefDir: URL, fileManager: FileManager) {
        let helper = cefDir.appending(path: "steamwebhelper.exe")
        let real = cefDir.appending(path: "steamwebhelper_real.exe")
        let wrapperSize = fileSize(of: wrapperBinary)

        // Migration from the old approach: steamwebhelper.exe is our wrapper.
        // Restore the genuine binary from the preserved copy so verification passes.
        if fileSize(of: helper) == wrapperSize {
            guard let realSize = fileSize(of: real), realSize != wrapperSize else {
                Logger.wineKit.error(
                    "steamwebhelper.exe is the wrapper but no genuine copy to restore in \(cefDir.lastPathComponent)")
                return
            }
            guard replace(at: helper, with: real, fileManager: fileManager) else { return }
            Logger.wineKit.info("Restored genuine steamwebhelper.exe in \(cefDir.lastPathComponent)")
        }

        // Keep steamwebhelper_real.exe (what the wrapper launches) in sync with
        // the genuine binary.
        if fileSize(of: real) != fileSize(of: helper),
           replace(at: real, with: helper, fileManager: fileManager) {
            Logger.wineKit.info("Refreshed steamwebhelper_real.exe in \(cefDir.lastPathComponent)")
        }
    }

    /// Copy `source` to `dest` (replacing) unless they are already the same size.
    private static func installFile(_ source: URL, to dest: URL, fileManager: FileManager) {
        if fileSize(of: dest) == fileSize(of: source) { return }
        try? fileManager.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if replace(at: dest, with: source, fileManager: fileManager) {
            Logger.wineKit.info("Installed \(dest.lastPathComponent)")
        }
    }

    /// Replace `dest` with a fresh copy of `source`, removing any existing `dest`.
    private static func replace(at dest: URL, with source: URL, fileManager: FileManager) -> Bool {
        do {
            if fileManager.fileExists(atPath: dest.path(percentEncoded: false)) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(at: source, to: dest)
            return true
        } catch {
            Logger.wineKit.error("Failed to write \(dest.lastPathComponent): \(error)")
            return false
        }
    }

    private static func fileSize(of url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
}

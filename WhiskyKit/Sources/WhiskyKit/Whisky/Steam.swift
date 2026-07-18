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

    /// Registry key holding per-DLL load-order overrides.
    private static let dllOverridesKey = #"HKCU\Software\Wine\DllOverrides"#

    /// DXVK d3d9 payload installed by `scripts/build-dxvk.sh` (`make dxvk`),
    /// split by architecture (`win32`/`win64`).
    private static let dxvkFolder: URL = WhiskyWineInstaller.libraryFolder
        .appending(path: "DXVK")

    /// Make a bottle ready to run Steam's CEF host under Wine: install the
    /// webhelper wrapper and, when Steam is present, attach it via the image's
    /// IFEO `Debugger` value (keeping `steamwebhelper.exe` genuine so Steam's
    /// verification passes). Also drops the DXVK `d3d9.dll` into installed
    /// Steam games that import d3d9 (wined3d's D3D9 is broken on macOS).
    /// Idempotent and a no-op when Steam is absent; safe to call before
    /// launching any program.
    public static func configure(in bottle: Bottle) async {
        if installWebhelperWrapper(in: bottle) {
            try? await Wine.addRegistryKey(
                bottle: bottle, key: ifeoDebuggerKey, name: "Debugger",
                data: ifeoDebuggerValue, type: .string
            )
        }

        if installDXVKForD3D9Games(in: bottle) {
            // `native,builtin` (never plain `native`): a d3d9 game that did not
            // get the DXVK dll must fall back to the builtin instead of failing
            // to launch with c0000135.
            try? await Wine.addRegistryKey(
                bottle: bottle, key: dllOverridesKey, name: "d3d9",
                data: "native,builtin", type: .string
            )
        }
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

    /// Maximum directory depth walked under a game when looking for d3d9
    /// executables. Steam games keep their exe within a few levels (e.g.
    /// `Binaries/Win64/Game.exe`); the cap bounds the per-launch scan cost.
    private static let d3d9ScanMaxDepth = 4

    /// Per-bottle cache of scanned game directories (kept next to `Metadata.plist`,
    /// outside `drive_c` so Wine never sees it). Games whose directory modification
    /// time is unchanged since the last scan are skipped without re-walking or
    /// PE-parsing anything.
    private static func scanCacheURL(for bottle: Bottle) -> URL {
        bottle.url.appending(path: "DXVKScanCache").appendingPathExtension("plist")
    }

    /// A remembered scan result for one game directory.
    private struct DXVKScanEntry: Codable {
        let mtime: Double
        let hasD3D9: Bool
    }

    /// Outcome of scanning a single game directory this run.
    private struct DXVKScanResult {
        /// At least one executable imports d3d9.dll.
        var foundD3D9 = false
        /// Every d3d9 executable is now provisioned (dll present or just copied).
        /// When `false` (payload not built yet, or a copy failed) the entry is
        /// not cached, so the game is retried on the next launch.
        var complete = true
    }

    /// Give installed Steam games that use D3D9 the DXVK `d3d9.dll` (wined3d's
    /// D3D9 path is broken on macOS; DXMT does not implement D3D9). Walks each
    /// game's tree for executables that import d3d9.dll and copies the
    /// architecture-matching payload next to each such exe (Windows resolves an
    /// exe's imports from its own directory, so the dll must sit beside it, not
    /// at the game root). Never overwrites an existing `d3d9.dll` (a game may
    /// ship its own, or the user a custom build). Returns `true` when at least
    /// one d3d9 executable was found, so the caller only writes the d3d9
    /// override for bottles that actually need it.
    ///
    /// Unchanged games are skipped via a per-bottle mtime cache, so the steady
    /// state cost is one directory listing plus a stat per game — no PE parsing.
    @discardableResult
    private static func installDXVKForD3D9Games(in bottle: Bottle) -> Bool {
        let fileManager = FileManager.default
        let cacheURL = scanCacheURL(for: bottle)
        let oldCache = loadScanCache(at: cacheURL)
        var newCache: [String: DXVKScanEntry] = [:]
        var foundD3D9Game = false

        for root in steamRoots {
            let common = bottle.url
                .appending(path: "drive_c")
                .appending(path: root)
                .appending(path: "steamapps/common")

            guard let games = try? fileManager.contentsOfDirectory(
                at: common, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
            ) else { continue }

            for gameDir in games {
                let values = try? gameDir.resourceValues(
                    forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values?.isDirectory == true else { continue }
                let path = gameDir.path(percentEncoded: false)
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

                if let cached = oldCache[path], cached.mtime == mtime {
                    // Unchanged since the last complete scan; reuse the result.
                    newCache[path] = cached
                    foundD3D9Game = foundD3D9Game || cached.hasD3D9
                    continue
                }

                let result = installDXVK(gameDir: gameDir, fileManager: fileManager)
                foundD3D9Game = foundD3D9Game || result.foundD3D9
                // Only remember games that finished provisioning; a game still
                // awaiting the DXVK payload must be retried next launch.
                if result.complete {
                    newCache[path] = DXVKScanEntry(mtime: mtime, hasD3D9: result.foundD3D9)
                }
            }
        }

        saveScanCache(newCache, to: cacheURL)
        return foundD3D9Game
    }

    /// Walk a game's tree (bounded depth) and, next to every executable that
    /// imports d3d9.dll, install the architecture-matching DXVK `d3d9.dll`
    /// unless one is already present.
    private static func installDXVK(gameDir: URL, fileManager: FileManager) -> DXVKScanResult {
        var result = DXVKScanResult()
        guard let enumerator = fileManager.enumerator(
            at: gameDir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }

        for case let entry as URL in enumerator {
            if enumerator.level > d3d9ScanMaxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard entry.pathExtension.lowercased() == "exe",
                  let peFile = try? PEFile(url: entry), peFile.importsDLL("d3d9.dll"),
                  peFile.architecture != .unknown else { continue }

            result.foundD3D9 = true

            let dest = entry.deletingLastPathComponent().appending(path: "d3d9.dll")
            guard !fileManager.fileExists(atPath: dest.path(percentEncoded: false)) else { continue }

            let archDir = peFile.architecture == .x64 ? "win64" : "win32"
            let payload = dxvkFolder.appending(path: archDir).appending(path: "d3d9.dll")
            guard fileManager.fileExists(atPath: payload.path(percentEncoded: false)) else {
                Logger.wineKit.info(
                    "DXVK \(archDir) payload not built; skipping d3d9 install for \(entry.lastPathComponent)")
                result.complete = false
                continue
            }

            do {
                try fileManager.copyItem(at: payload, to: dest)
                Logger.wineKit.info("Installed DXVK d3d9.dll (\(archDir)) next to \(entry.lastPathComponent)")
            } catch {
                Logger.wineKit.error("Failed to install DXVK d3d9.dll for \(entry.lastPathComponent): \(error)")
                result.complete = false
            }
        }

        return result
    }

    /// Load the per-bottle scan cache; returns an empty map when absent or unreadable.
    private static func loadScanCache(at url: URL) -> [String: DXVKScanEntry] {
        guard let data = try? Data(contentsOf: url),
              let cache = try? PropertyListDecoder().decode([String: DXVKScanEntry].self, from: data)
        else { return [:] }
        return cache
    }

    /// Persist the scan cache (best effort; a failure just means a rescan next time).
    private static func saveScanCache(_ cache: [String: DXVKScanEntry], to url: URL) {
        guard let data = try? PropertyListEncoder().encode(cache) else { return }
        try? data.write(to: url)
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

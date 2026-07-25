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

        let provision = installDXVKForGames(in: bottle)
        // `native` only (never `native,builtin`): the builtin wined3d D3D9/D3D8
        // path is broken on macOS (black/white screen), so falling back to it
        // only masks the real problem. A game that did not receive the DXVK dll
        // should fail loudly (c0000135) rather than silently white-screen on a
        // backend that cannot render. A D3D8 game also needs d3d9 native — DXVK's
        // d3d8 is a wrapper that drives DXVK's d3d9 underneath.
        if provision.needsD3D9 {
            try? await Wine.addRegistryKey(
                bottle: bottle, key: dllOverridesKey, name: "d3d9",
                data: "native", type: .string
            )
        }
        if provision.needsD3D8 {
            try? await Wine.addRegistryKey(
                bottle: bottle, key: dllOverridesKey, name: "d3d8",
                data: "native", type: .string
            )
        }
    }

    /// Existing `steamapps/common` directories across every Steam root in the
    /// bottle. Used by ``SteamLibraryWatcher`` to know which trees to watch;
    /// returns an empty array when Steam (or its library) is not present.
    public static func steamLibraryCommonDirectories(in bottle: Bottle) -> [URL] {
        let fileManager = FileManager.default
        var directories: [URL] = []

        for root in steamRoots {
            let common = bottle.url
                .appending(path: "drive_c")
                .appending(path: root)
                .appending(path: "steamapps/common")

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: common.path(percentEncoded: false), isDirectory: &isDirectory
            ), isDirectory.boolValue {
                directories.append(common)
            }
        }

        return directories
    }

    /// Re-run the DXVK (D3D9/D3D8) provisioning scan for a bottle whose Steam
    /// library changed outside of Whisky's own launch path — a game installed or
    /// updated from inside Steam's UI, which bypasses ``Wine/prepareForLaunch(bottle:)``.
    /// Thin public wrapper over the internal, mtime-cached scan; cheap and safe
    /// to call repeatedly (used by ``SteamLibraryWatcher``).
    public static func rescanDXVKForGames(in bottle: Bottle) {
        installDXVKForGames(in: bottle)
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
}

// MARK: - DXVK D3D9/D3D8 auto-drop
//
// The launch-time scan that provisions installed Steam games with the matching
// DXVK dll(s). Kept in an extension so the main `Steam` enum stays within
// SwiftLint's type_body_length; same-file `private` access makes the split seamless
// (the webhelper section above still calls installFile/replace/fileSize below).
extension Steam {
    /// Maximum directory depth walked under a game when looking for d3d9/d3d8
    /// executables. Steam games keep their exe within a few levels (e.g.
    /// `Binaries/Win64/Game.exe`); the cap bounds the per-launch scan cost.
    private static let dxvkScanMaxDepth = 4

    /// Per-bottle cache of scanned game directories (kept next to `Metadata.plist`,
    /// outside `drive_c` so Wine never sees it). Games whose directory modification
    /// time is unchanged since the last scan are skipped without re-walking or
    /// PE-parsing anything.
    private static func scanCacheURL(for bottle: Bottle) -> URL {
        bottle.url.appending(path: "DXVKScanCache").appendingPathExtension("plist")
    }

    /// A remembered scan result for one game directory. (A cache written by an
    /// older, d3d9-only build lacks these keys and simply fails to decode, which
    /// discards it and triggers one idempotent re-scan — the intended fallback.)
    private struct DXVKScanEntry: Codable {
        let mtime: Double
        /// The game needs DXVK's d3d9 override (a D3D9 game, or a D3D8 game whose
        /// wrapper drives d3d9 underneath).
        let needsD3D9: Bool
        /// The game imports d3d8.dll and needs DXVK's d3d8 override.
        let needsD3D8: Bool
    }

    /// Which DXVK DLL overrides a scan established a bottle needs.
    private struct DXVKProvision {
        /// At least one game needs DXVK's d3d9 (a D3D9 game, or the d3d9 that
        /// every D3D8 game's wrapper sits on).
        var needsD3D9 = false
        /// At least one game imports d3d8.dll.
        var needsD3D8 = false
    }

    /// Outcome of scanning a single game directory this run.
    private struct DXVKScanResult {
        /// The game needs DXVK's d3d9 (imports d3d9.dll, or imports d3d8.dll whose
        /// DXVK wrapper drives d3d9).
        var needsD3D9 = false
        /// The game imports d3d8.dll.
        var needsD3D8 = false
        /// Every executable is now provisioned (dll(s) present or just copied).
        /// When `false` (payload not built yet, or a copy failed) the entry is
        /// not cached, so the game is retried on the next launch.
        var complete = true
    }

    /// Give installed Steam games that use D3D9 or D3D8 the matching DXVK dll(s)
    /// (wined3d's D3D9/D3D8 path is broken on macOS; DXMT does not implement
    /// them). Walks each game's tree for executables that import d3d9.dll /
    /// d3d8.dll and copies the architecture-matching payload next to each such
    /// exe (Windows resolves an exe's imports from its own directory, so the dll
    /// must sit beside it, not at the game root). A D3D8 game gets both d3d8.dll
    /// and d3d9.dll — DXVK's d3d8 is a wrapper over its d3d9. Never overwrites an
    /// existing dll (a game may ship its own, or the user a custom build).
    /// Returns which overrides are needed, so the caller writes only those.
    ///
    /// Unchanged games are skipped via a per-bottle mtime cache, so the steady
    /// state cost is one directory listing plus a stat per game — no PE parsing.
    @discardableResult
    private static func installDXVKForGames(in bottle: Bottle) -> DXVKProvision {
        let fileManager = FileManager.default
        let cacheURL = scanCacheURL(for: bottle)
        let oldCache = loadScanCache(at: cacheURL)
        var newCache: [String: DXVKScanEntry] = [:]
        var provision = DXVKProvision()

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
                    provision.needsD3D9 = provision.needsD3D9 || cached.needsD3D9
                    provision.needsD3D8 = provision.needsD3D8 || cached.needsD3D8
                    continue
                }

                let result = installDXVK(gameDir: gameDir, fileManager: fileManager)
                provision.needsD3D9 = provision.needsD3D9 || result.needsD3D9
                provision.needsD3D8 = provision.needsD3D8 || result.needsD3D8
                // Only remember games that finished provisioning; a game still
                // awaiting the DXVK payload must be retried next launch.
                if result.complete {
                    newCache[path] = DXVKScanEntry(
                        mtime: mtime, needsD3D9: result.needsD3D9, needsD3D8: result.needsD3D8)
                }
            }
        }

        saveScanCache(newCache, to: cacheURL)
        return provision
    }

    /// Walk a game's tree (bounded depth) and, next to every executable that
    /// imports d3d9.dll / d3d8.dll, install the architecture-matching DXVK dll(s)
    /// unless already present. A d3d8 importer gets both d3d8.dll and d3d9.dll
    /// (DXVK's d3d8 calls Direct3DCreate9 from d3d9.dll).
    private static func installDXVK(gameDir: URL, fileManager: FileManager) -> DXVKScanResult {
        var result = DXVKScanResult()
        guard let enumerator = fileManager.enumerator(
            at: gameDir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }

        for case let entry as URL in enumerator {
            if enumerator.level > dxvkScanMaxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard entry.pathExtension.lowercased() == "exe",
                  let peFile = try? PEFile(url: entry),
                  peFile.architecture != .unknown else { continue }
            let importsD3D8 = peFile.importsDLL("d3d8.dll")
            let importsD3D9 = peFile.importsDLL("d3d9.dll")
            guard importsD3D8 || importsD3D9 else { continue }

            let archDir = peFile.architecture == .x64 ? "win64" : "win32"
            let dir = entry.deletingLastPathComponent()
            let exeName = entry.lastPathComponent

            if importsD3D8 {
                result.needsD3D8 = true
                if !dropDXVKDLL("d3d8.dll", archDir: archDir, into: dir, beside: exeName,
                                fileManager: fileManager) {
                    result.complete = false
                }
            }
            // d3d9 is needed for a D3D9 game and under every D3D8 game's wrapper.
            result.needsD3D9 = true
            if !dropDXVKDLL("d3d9.dll", archDir: archDir, into: dir, beside: exeName,
                            fileManager: fileManager) {
                result.complete = false
            }
        }

        return result
    }

    /// Copy DXVK's `dllName` from the `archDir` (`win32`/`win64`) payload folder
    /// into `dir`, unless a dll of that name is already there. Returns `false`
    /// when the payload is not built yet or the copy failed, so the game is left
    /// uncached and retried on the next launch.
    private static func dropDXVKDLL(
        _ dllName: String, archDir: String, into dir: URL, beside exeName: String,
        fileManager: FileManager
    ) -> Bool {
        let dest = dir.appending(path: dllName)
        guard !fileManager.fileExists(atPath: dest.path(percentEncoded: false)) else { return true }

        let payload = dxvkFolder.appending(path: archDir).appending(path: dllName)
        guard fileManager.fileExists(atPath: payload.path(percentEncoded: false)) else {
            Logger.wineKit.info("DXVK \(archDir) \(dllName) payload not built; skipping for \(exeName)")
            return false
        }

        do {
            try fileManager.copyItem(at: payload, to: dest)
            Logger.wineKit.info("Installed DXVK \(dllName) (\(archDir)) next to \(exeName)")
            return true
        } catch {
            Logger.wineKit.error("Failed to install DXVK \(dllName) for \(exeName): \(error)")
            return false
        }
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

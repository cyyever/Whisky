//
//  GamingPlatform.swift
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

/// A PC gaming storefront whose official installer Whisky can fetch and run into
/// a bottle, so the user does not have to hunt down the right `Setup.exe`.
///
/// Only **Steam** is a validated path on this stack (the whole fork is built
/// around it — webhelper IFEO wrapper, DXVK auto-drop, Proton lock). The others
/// are provided as a convenience and run through the exact same "download the
/// vendor installer, launch it in the bottle" path; their post-install runtime
/// is not specifically tuned here.
///
/// The `installerURL`s are the vendors' stable public installer endpoints. They
/// are the single most likely thing to rot over time — when one 404s, update it
/// here rather than anywhere else.
public struct GamingPlatform: Identifiable, Hashable, Sendable {
    public let id: String
    /// Display name (a proper noun — intentionally not localized).
    public let name: String
    /// SF Symbol shown in the menu.
    public let symbol: String
    /// The vendor's official installer download URL.
    public let installerURL: URL
    /// Filename to save the download as. The extension matters: Wine's `start`
    /// dispatches `.msi` to msiexec and `.exe` directly, so it must be correct.
    public let installerFilename: String
    // `var` (not `let`): a `let` with a default value isn't overridable via the
    // memberwise initializer, so Steam couldn't set installerArgs. Instances are
    // still effectively immutable — all are `static let` constants.
    //
    /// Extra arguments passed to the installer, e.g. a silent-install flag so the
    /// one-click flow doesn't strand the user on an interactive wizard. Only set
    /// where the flag is known-good for that vendor's installer (else interactive).
    public var installerArgs: [String] = []

    // swiftlint:disable line_length
    public static let steam = Self(
        id: "steam", name: "Steam", symbol: "cloud",
        installerURL: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!,
        installerFilename: "SteamSetup.exe",
        installerArgs: ["/S"]  // NSIS silent install — Steam bootstrapper, no wizard
    )

    public static let all: [Self] = [
        steam,
        Self(
            id: "epic", name: "Epic Games", symbol: "e.circle",
            installerURL: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
            installerFilename: "EpicGamesLauncherInstaller.msi"
        ),
        Self(
            id: "gog", name: "GOG Galaxy", symbol: "g.circle",
            installerURL: URL(string: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe")!,
            installerFilename: "GOG_Galaxy_2.0.exe"
        ),
        Self(
            id: "ea", name: "EA app", symbol: "a.circle",
            installerURL: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!,
            installerFilename: "EAappInstaller.exe"
        ),
        Self(
            id: "ubisoft", name: "Ubisoft Connect", symbol: "u.circle",
            installerURL: URL(string: "https://ubistatic3-a.akamaihd.net/orbit/launcher_installer/UbisoftConnectInstaller.exe")!,
            installerFilename: "UbisoftConnectInstaller.exe"
        ),
        Self(
            id: "battlenet", name: "Battle.net", symbol: "b.circle",
            installerURL: URL(string: "https://downloader.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live")!,
            installerFilename: "Battle.net-Setup.exe"
        )
    ]
    // swiftlint:enable line_length
}

public enum GamingPlatformInstaller {
    /// Download `platform`'s official installer (cached per-bottle so a retry or a
    /// second platform doesn't re-fetch) and launch it inside `bottle`. For Steam
    /// we also run `Steam.configure` afterwards so the webhelper wrapper / DXVK
    /// wiring is in place for the first launch.
    ///
    /// Runs the installer with the platform's `installerArgs`: a silent-install
    /// flag where one is known-good for that vendor (Steam passes `/S`), otherwise
    /// no args so the installer's own wizard drives it. `waitForExit` so we only
    /// configure / report completion once the installer has actually finished.
    public static func install(_ platform: GamingPlatform, in bottle: Bottle) async throws {
        let installer = try await download(platform, in: bottle)
        // waitForExit so we only configure / report done once the installer has
        // actually finished — `start` alone is non-blocking.
        try await Wine.runProgram(
            at: installer, args: platform.installerArgs, bottle: bottle, waitForExit: true
        )
        if platform.id == GamingPlatform.steam.id {
            await Steam.configure(in: bottle)
        }
    }

    /// Directory holding downloaded installers for a bottle. Kept next to the
    /// bottle metadata (outside `drive_c`) so it is scoped to the bottle and
    /// removed with it, and never scanned as an installed Windows program.
    private static func cacheDirectory(for bottle: Bottle) -> URL {
        bottle.url.appending(path: "Installers", directoryHint: .isDirectory)
    }

    private static func download(_ platform: GamingPlatform, in bottle: Bottle) async throws -> URL {
        let dir = cacheDirectory(for: bottle)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: platform.installerFilename)

        // Reuse a prior download only if it still looks like a real installer.
        // A truncated transfer or an HTTP-200 HTML error/redirect body would
        // otherwise be cached forever and reused on every retry — validate the
        // magic bytes so a corrupt cache is re-fetched instead.
        if isValidInstaller(dest) {
            Logger.wineKit.info("Reusing cached \(platform.name) installer at \(dest.path)")
            return dest
        }
        try? FileManager.default.removeItem(at: dest)

        Logger.wineKit.info("Downloading \(platform.name) installer from \(platform.installerURL)")
        let (tempURL, response) = try await URLSession.shared.download(from: platform.installerURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw GamingPlatformError.badResponse(platform: platform.name, status: http.statusCode)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        // A 200 can still carry an HTML error page — reject anything that isn't a
        // PE (.exe: "MZ") or MSI compound file (0xD0CF11E0).
        guard isValidInstaller(dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw GamingPlatformError.corruptDownload(platform: platform.name)
        }
        return dest
    }

    /// True if `url` exists and begins with an installer magic number: "MZ" for a
    /// PE `.exe`, or the OLE compound-file signature for an `.msi`.
    private static func isValidInstaller(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), !head.isEmpty else { return false }
        let peMagic: [UInt8] = [0x4D, 0x5A]                                  // "MZ" (PE/exe)
        let oleMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] // MSI compound file
        let bytes = [UInt8](head)
        return bytes.starts(with: peMagic) || bytes.starts(with: oleMagic)
    }
}

public enum GamingPlatformError: LocalizedError {
    case badResponse(platform: String, status: Int)
    case corruptDownload(platform: String)

    public var errorDescription: String? {
        switch self {
        case let .badResponse(platform, status):
            return "Failed to download the \(platform) installer (HTTP \(status))."
        case let .corruptDownload(platform):
            return "The downloaded \(platform) installer was not a valid program — please try again."
        }
    }
}

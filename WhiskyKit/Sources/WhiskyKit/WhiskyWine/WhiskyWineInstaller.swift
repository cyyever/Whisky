//
//  WhiskyWineInstaller.swift
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
import SemanticVersion

public class WhiskyWineInstaller {
    /// The Whisky application folder
    public static let applicationFolder = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appending(path: Bundle.whiskyBundleIdentifier)

    /// The folder of all the libfrary files
    public static let libraryFolder = applicationFolder.appending(path: "Libraries")

    /// URL to the installed `wine` `bin` directory
    public static let binFolder: URL = libraryFolder.appending(path: "Wine").appending(path: "bin")

    /// URL to the Proton (`proton-wine`) `bin` directory that `.proton` bottles
    /// run from. Two install layouts are supported:
    ///   * **side-by-side** — Proton at `Libraries/WineProton`, canonical Whisky
    ///     Wine untouched at ``binFolder`` (`scripts/install-proton.sh` with
    ///     `INSTALL_TO_WHISKY=1`).
    ///   * **replace** — Proton laid directly over `Libraries/Wine` (Whisky Wine
    ///     backed up alongside); no separate `WineProton` dir exists.
    /// Prefer the side-by-side dir when present, otherwise fall back to
    /// ``binFolder`` so `.proton` always resolves to a real install.
    public static var protonBinFolder: URL {
        let sideBySide = libraryFolder.appending(path: "WineProton").appending(path: "bin")
        if FileManager.default.fileExists(atPath: sideBySide.appending(path: "wine64").path) {
            return sideBySide
        }
        return binFolder
    }

    public static func isWhiskyWineInstalled() -> Bool {
        return whiskyWineVersion() != nil
    }

    /// Whether an optional Proton backend is installed (has a `wine64` binary).
    public static func isProtonInstalled() -> Bool {
        FileManager.default.fileExists(atPath: protonBinFolder.appending(path: "wine64").path)
    }

    public static func whiskyWineVersion() -> SemanticVersion? {
        do {
            let versionPlist = libraryFolder
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")

            let decoder = PropertyListDecoder()
            let data = try Data(contentsOf: versionPlist)
            let info = try decoder.decode(WhiskyWineVersion.self, from: data)
            return info.version
        } catch {
            print(error)
            return nil
        }
    }
}

public struct WhiskyWineVersion: Codable {
    public var version = SemanticVersion(1, 0, 0)
}

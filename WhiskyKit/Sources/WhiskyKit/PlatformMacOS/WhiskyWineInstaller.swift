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

    public static func isWhiskyWineInstalled() -> Bool {
        return whiskyWineVersion() != nil
    }

    public static func whiskyWineVersion() -> SemanticVersion? {
        return installedInfo()?.version
    }

    /// Digests of `patches/proton-wine/*.patch`, stamped into the Wine install by
    /// build-proton-x86.sh and into the app by `make install-app`. A version
    /// number cannot do this: the whole series can change while Wine stays
    /// 11.0.0, and the app now depends on defaults those patches carry. Computed
    /// on both sides, so neither can go stale.
    public static func patchSeriesMismatch() -> (installed: String, expected: String)? {
        guard
            let expected = Bundle.main.object(forInfoDictionaryKey: "WhiskyWinePatchDigest") as? String,
            !expected.isEmpty
        else { return nil }  // an app built without the stamp has nothing to claim
        let installed = installedInfo()?.patchSeriesDigest ?? ""
        return installed == expected ? nil : (installed: installed, expected: expected)
    }

    private static func installedInfo() -> WhiskyWineVersion? {
        do {
            let versionPlist =
                libraryFolder
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")

            let decoder = PropertyListDecoder()
            let data = try Data(contentsOf: versionPlist)
            return try decoder.decode(WhiskyWineVersion.self, from: data)
        } catch {
            print(error)
            return nil
        }
    }
}

public struct WhiskyWineVersion: Codable {
    public var version = SemanticVersion(1, 0, 0)
    /// "" for a Wine installed before the stamp existed — itself a mismatch.
    public var patchSeriesDigest: String = ""
}

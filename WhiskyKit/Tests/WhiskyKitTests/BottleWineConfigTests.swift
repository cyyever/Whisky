//
//  BottleWineConfigTests.swift
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
import Testing

@testable import WhiskyKit

struct BottleWineConfigTests {
    @Test func newBottlesUseWindows11() {
        #expect(BottleWineConfig().windowsVersion == .win11)
        #expect(BottleSettings().windowsVersion == .win11)
    }

    @Test(arguments: ["winxp64", "win7", "win8", "win81", "win10", "win11"])
    func storedVersionsRemainReadableUntilWineMigrates(_ version: String) throws {
        let json = #"{"windowsVersion":"\#(version)","avxEnabled":true,"followSystemProxy":false}"#
        let config = try JSONDecoder().decode(BottleWineConfig.self, from: Data(json.utf8))
        #expect(config.windowsVersion.rawValue == version)
        #expect(!config.followSystemProxy)
    }

    @Test(arguments: [#"{"followSystemProxy":false}"#, #"{"windowsVersion":"invalid","followSystemProxy":false}"#])
    func missingOrInvalidVersionUsesWindows11(_ json: String) throws {
        let config = try JSONDecoder().decode(BottleWineConfig.self, from: Data(json.utf8))
        #expect(config.windowsVersion == .win11)
        #expect(!config.followSystemProxy)
    }

    @Test(arguments: [true, false])
    func legacyAvxPreferenceIsIgnored(_ enabled: Bool) throws {
        let json = #"{"avxEnabled":\#(enabled),"followSystemProxy":false}"#
        let config = try JSONDecoder().decode(BottleWineConfig.self, from: Data(json.utf8))
        #expect(!config.followSystemProxy)
        let encoded = try JSONEncoder().encode(config)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["avxEnabled"] == nil)
    }
}

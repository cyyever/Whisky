//
//  BottleSettings.swift
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
import SemanticVersion

/// Decode-time resilience for the bottle-settings structs below.
///
/// Every settings field has a sensible default, and the loader is meant to fall
/// back to it when a value can't be read — the migration comments throughout
/// (`esync → msync`, `win7 → win10`) depend on that. But `decodeIfPresent` only
/// tolerates an *absent* key: a key that is *present but malformed* — a stale
/// on-disk format, a removed enum case, a truncated write, a hand-edit — makes
/// it throw. One field throwing fails the entire `init(from:)`, and the bottle
/// loader reacts by resetting the WHOLE bottle to defaults and persisting that,
/// silently wiping unrelated fields (name, pins, proxy). These helpers keep the
/// blast radius to the single bad field: it falls back to its default while
/// every other field decodes normally.
private extension KeyedDecodingContainer {
    /// The value for `key`, or `defaultValue` if the key is absent OR its stored
    /// value is malformed/unrecognized. Never throws for a field-level problem.
    func decodeResilient<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) -> T {
        (try? decode(type, forKey: key)) ?? defaultValue
    }

    /// Optional value for `key`: `nil` when the key is absent or its value is malformed.
    func decodeResilient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decode(type, forKey: key)
    }
}

public struct PinnedProgram: Codable, Hashable, Equatable {
    public var name: String
    public var url: URL?
    public var removable: Bool

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
        do {
            let volume = try url.resourceValues(forKeys: [.volumeURLKey]).volume
            self.removable = try !(volume?.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal ?? false)
        } catch {
            self.removable = false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = container.decodeResilient(String.self, forKey: .name, default: "")
        self.url = container.decodeResilient(URL.self, forKey: .url)
        self.removable = container.decodeResilient(Bool.self, forKey: .removable, default: false)
    }
}

public struct BottleInfo: Codable, Equatable {
    var name: String = "Bottle"
    var pins: [PinnedProgram] = []
    var blocklist: [URL] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = container.decodeResilient(String.self, forKey: .name, default: "Bottle")
        self.pins = container.decodeResilient([PinnedProgram].self, forKey: .pins, default: [])
        self.blocklist = container.decodeResilient([URL].self, forKey: .blocklist, default: [])
    }
}

public enum WinVersion: String, CaseIterable, Codable, Sendable {
    case winXP = "winxp64"
    case win7 = "win7"
    case win8 = "win8"
    case win81 = "win81"
    case win10 = "win10"
    case win11 = "win11"

    /// Versions offered in the UI. Steam requires Windows 10+ (dropped 7/8/8.1 in
    /// Jan 2024) — older versions break the Steam client, so only these are
    /// user-selectable. The other cases stay in the enum for decode compat.
    public static let selectable: [Self] = [.win10, .win11]

    public func pretty() -> String {
        switch self {
        case .winXP:
            return "Windows XP"
        case .win7:
            return "Windows 7"
        case .win8:
            return "Windows 8"
        case .win81:
            return "Windows 8.1"
        case .win10:
            return "Windows 10"
        case .win11:
            return "Windows 11"
        }
    }
}

public enum EnhancedSync: Codable, Equatable {
    case none, esync, msync
}

public struct BottleWineConfig: Codable, Equatable {
    static let defaultWineVersion = SemanticVersion(11, 11, 0)
    var wineVersion: SemanticVersion = Self.defaultWineVersion
    var windowsVersion: WinVersion = .win10
    var enhancedSync: EnhancedSync = .msync
    var avxEnabled: Bool = false
    var followSystemProxy: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.wineVersion = container.decodeResilient(
            SemanticVersion.self, forKey: .wineVersion, default: Self.defaultWineVersion)
        // Steam requires Windows 10+ (dropped 7/8/8.1 in Jan 2024); an old bottle
        // pinned to XP/7/8/8.1 would break the Steam client, so migrate it to win10
        // — the same decode-migration shape as the `.esync → .msync` fix below.
        // Keeps the Picker (which only offers win10/win11) able to represent every bottle.
        let winVersion = container.decodeResilient(WinVersion.self, forKey: .windowsVersion, default: .win10)
        self.windowsVersion = WinVersion.selectable.contains(winVersion) ? winVersion : .win10
        // esync can't exist on macOS (no eventfd); an old `.esync` selection meant
        // "fast-sync wanted", so migrate it to msync — the working macOS backend.
        // Keeps the Picker (which only offers none/msync) able to represent every bottle.
        let sync = container.decodeResilient(EnhancedSync.self, forKey: .enhancedSync, default: .msync)
        self.enhancedSync = sync == .esync ? .msync : sync
        self.avxEnabled = container.decodeResilient(Bool.self, forKey: .avxEnabled, default: false)
        self.followSystemProxy = container.decodeResilient(Bool.self, forKey: .followSystemProxy, default: true)
    }
}

public struct BottleMetalConfig: Codable, Equatable {
    var metalHud: Bool = false
    var dxrEnabled: Bool = false
    /// DXMT: Metal-native D3D11 (builtin via `make dxmt`). On by default — it is
    /// the working D3D11 path for modern games on Apple Silicon.
    var dxmt: Bool = true
    /// Hide virtual audio devices (Steam Streaming, Teams, loopback) from games.
    /// On by default — some games hang while enumerating them.
    var hideVirtualAudioDevices: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.metalHud = container.decodeResilient(Bool.self, forKey: .metalHud, default: false)
        self.dxrEnabled = container.decodeResilient(Bool.self, forKey: .dxrEnabled, default: false)
        self.dxmt = container.decodeResilient(Bool.self, forKey: .dxmt, default: true)
        self.hideVirtualAudioDevices = container.decodeResilient(
            Bool.self, forKey: .hideVirtualAudioDevices, default: true)
    }
}

public struct BottleSettings: Codable, Equatable {
    static let defaultFileVersion = SemanticVersion(1, 0, 0)

    var fileVersion: SemanticVersion = Self.defaultFileVersion
    private var info: BottleInfo
    private var wineConfig: BottleWineConfig
    private var metalConfig: BottleMetalConfig

    public init() {
        self.info = BottleInfo()
        self.wineConfig = BottleWineConfig()
        self.metalConfig = BottleMetalConfig()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fileVersion = container.decodeResilient(
            SemanticVersion.self, forKey: .fileVersion, default: Self.defaultFileVersion)
        self.info = container.decodeResilient(BottleInfo.self, forKey: .info, default: BottleInfo())
        self.wineConfig = container.decodeResilient(
            BottleWineConfig.self, forKey: .wineConfig, default: BottleWineConfig())
        self.metalConfig = container.decodeResilient(
            BottleMetalConfig.self, forKey: .metalConfig, default: BottleMetalConfig())
    }

    /// The name of this bottle
    public var name: String {
        get { return info.name }
        set { info.name = newValue }
    }

    /// The version of wine used by this bottle
    public var wineVersion: SemanticVersion {
        get { return wineConfig.wineVersion }
        set { wineConfig.wineVersion = newValue }
    }

    /// The version of windows used by this bottle
    public var windowsVersion: WinVersion {
        get { return wineConfig.windowsVersion }
        set { wineConfig.windowsVersion = newValue }
    }

    public var avxEnabled: Bool {
        get { return wineConfig.avxEnabled }
        set { wineConfig.avxEnabled = newValue }
    }

    /// When enabled, the bottle inherits macOS's system proxy configuration so
    /// HTTP(S) clients under Wine (e.g. Steam's self-updater) route through it.
    public var followSystemProxy: Bool {
        get { return wineConfig.followSystemProxy }
        set { wineConfig.followSystemProxy = newValue }
    }

    /// The pinned programs on this bottle
    public var pins: [PinnedProgram] {
        get { return info.pins }
        set { info.pins = newValue }
    }

    /// The blocked applicaitons on this bottle
    public var blocklist: [URL] {
        get { return info.blocklist }
        set { info.blocklist = newValue }
    }

    public var enhancedSync: EnhancedSync {
        get { return wineConfig.enhancedSync }
        set { wineConfig.enhancedSync = newValue }
    }

    public var metalHud: Bool {
        get { return metalConfig.metalHud }
        set { metalConfig.metalHud = newValue }
    }

    public var dxrEnabled: Bool {
        get { return metalConfig.dxrEnabled }
        set { metalConfig.dxrEnabled = newValue }
    }

    /// DXMT: Metal-native D3D11. On by default.
    public var dxmt: Bool {
        get { return metalConfig.dxmt }
        set { metalConfig.dxmt = newValue }
    }

    /// Hide virtual audio devices from games. On by default.
    public var hideVirtualAudioDevices: Bool {
        get { return metalConfig.hideVirtualAudioDevices }
        set { metalConfig.hideVirtualAudioDevices = newValue }
    }

    @discardableResult
    public static func decode(from metadataURL: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: metadataURL.path(percentEncoded: false)) else {
            let settings = Self()
            try settings.encode(to: metadataURL)
            return settings
        }

        let decoder = PropertyListDecoder()
        let data = try Data(contentsOf: metadataURL)
        var settings = try decoder.decode(Self.self, from: data)

        guard settings.fileVersion == Self.defaultFileVersion else {
            Logger.wineKit.warning("Invalid file version `\(settings.fileVersion)`")
            settings = Self()
            try settings.encode(to: metadataURL)
            return settings
        }

        if settings.wineConfig.wineVersion != BottleWineConfig().wineVersion {
            Logger.wineKit.warning("Bottle has a different wine version `\(settings.wineConfig.wineVersion)`")
            settings.wineConfig.wineVersion = BottleWineConfig().wineVersion
            try settings.encode(to: metadataURL)
            return settings
        }

        return settings
    }

    func encode(to metadataUrl: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(self)
        try data.write(to: metadataUrl)
    }

    public func environmentVariables(wineEnv: inout [String: String]) {
        // No WINEDLLOVERRIDES for the D3D/Vulkan stack: proton-wine's load order
        // (patches/proton-wine 0017) defaults d3d9/d3d8/d3d11/d3d10core/dxgi/vulkan-1
        // (+ winemetal on macOS) to builtin — DXVK / DXMT / winevulkan — and, matching
        // on the basename, catches the app-directory loads (Steam CEF's own
        // vulkan-1.dll) that an env override cannot. Nothing to set here.

        switch enhancedSync {
        case .none:
            // msync (mach/__ulock fast-sync) is proton-wine's default on macOS —
            // `do_msync()` treats an unset WINEMSYNC as enabled. So *disabling* it is
            // the only thing an env can do here: WINEMSYNC=0 forces the (slower)
            // wineserver fallback.
            wineEnv.updateValue("0", forKey: "WINEMSYNC")
        case .esync, .msync:
            // Nothing to set: msync is already the default. WINEMSYNC=1 would be
            // redundant, so we leave the env untouched and let the default stand.
            // (`.esync` is decode-migrated to `.msync` — no eventfd on macOS; and
            // WINEESYNC is dead on this stack, so we never touch it either.)
            break
        }

        if metalHud {
            wineEnv.updateValue("1", forKey: "MTL_HUD_ENABLED")
        }

        if avxEnabled {
            wineEnv.updateValue("1", forKey: "ROSETTA_ADVERTISE_AVX")
        }

        if dxrEnabled {
            wineEnv.updateValue("1", forKey: "D3DM_SUPPORT_DXR")
        }

        if hideVirtualAudioDevices {
            wineEnv.updateValue("1", forKey: "WHISKY_HIDE_VIRTUAL_AUDIO")
        }

        if followSystemProxy {
            for (key, value) in SystemProxy.environmentVariables() {
                wineEnv.updateValue(value, forKey: key)
            }
        }
    }
}

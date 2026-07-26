//
//  PlatformServices.swift
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

// MARK: - Platform seam (skeleton)
//
// The abstract boundary between the portable Core (models, PE parsing, Wine/Steam
// orchestration) and the per-OS implementations. Core code depends only on these
// protocols; each OS provides a concrete conformance, injected at startup.
//
// This is a SKELETON for the C++ cross-platform migration (see
// docs/cxx-migration-plan.md). Nothing conforms to these yet — the existing macOS
// code (SystemProxy, Rosetta2) is what will be adapted to conform in a later stage.
//
// Deliberately narrow. Only genuinely *behavioral* per-OS seams are protocols:
//  - ProxyResolver — CFNetwork vs. env parsing.
//  - ArchInfo      — translation detection (sysctl vs. uname).
// Everything else stays out of the seam:
//  - Wine host location + launch env → `WineHostConfig`, plain DATA, not behavior.
//  - Prefix-internal paths (drive_c, Windows↔Unix conversion, registry) → Core,
//    obtained from the wine CLI (`winepath`, `wine reg query`), identical on every
//    OS.
//  - File watching → portable Core (kqueue/DispatchSource, not FSEvents).
//  - Icon rendering, alerts, observation → the frontend layer.

/// Resolves the host's active proxy configuration into the environment a Wine
/// launch needs to route its traffic through that proxy.
///
/// - macOS: CFNetwork system-proxy + PAC evaluation, and SOCKS via a DYLD-injected
///   proxychains (see `SystemProxy`).
/// - FreeBSD/Linux: read `http_proxy`/`all_proxy` env or a config; no CFNetwork,
///   and `LD_PRELOAD` in place of `DYLD_INSERT_LIBRARIES` for the SOCKS shim.
public protocol ProxyResolver: Sendable {
    /// Environment variables to merge into a Wine launch so its traffic follows
    /// the host proxy. Empty when no proxy is configured.
    func launchEnvironment() -> [String: String]
}

/// Host CPU architecture and binary-translation facts that decide how Wine is
/// built and run.
///
/// - macOS / Apple Silicon: the x86_64 Wine build runs under **Rosetta 2**
///   (see `Rosetta2`).
/// - macOS / Intel and FreeBSD / x86_64: native, no translation.
/// - FreeBSD / ARM: no equivalent x86 translator — a real capability gap to flag.
public protocol ArchInfo: Sendable {
    /// Whether an x86_64 translation layer is present and usable for running the
    /// x86_64 Wine build on this host.
    var hasX86TranslationLayer: Bool { get }
}

/// Where the `wine` binaries live and the loader environment to launch them —
/// the one host-bootstrap fact the wine CLI cannot report (you need it *to run*
/// wine). Plain DATA, filled in at startup per host, not a behavioral protocol:
///
/// - macOS: `binFolder` is the bundled Wine path; `launchEnvironment` carries
///   `DYLD_FALLBACK_LIBRARY_PATH`, Rosetta selection, and the KosmicKrisp swap.
/// - FreeBSD/Linux: `binFolder` from `PATH` (`which wine`); `launchEnvironment` is
///   usually empty (standard `LD_LIBRARY_PATH`, native Vulkan ICD).
public struct WineHostConfig: Sendable {
    public let binFolder: URL
    public let launchEnvironment: [String: String]

    public init(binFolder: URL, launchEnvironment: [String: String] = [:]) {
        self.binFolder = binFolder
        self.launchEnvironment = launchEnvironment
    }
}

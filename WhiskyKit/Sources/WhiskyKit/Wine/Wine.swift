//
//  Wine.swift
//  Whisky
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

public class Wine {
    /// The `bin` directory for a bottle's selected Wine backend — the canonical
    /// Path to the installed Wine `bin` directory. Proton is the only backend and
    /// installs over `Libraries/Wine`, so every bottle resolves to the same place.
    /// (The `bottle` argument is kept for call-site stability / future per-bottle Wine.)
    public static func binFolder(for _: Bottle?) -> URL {
        return WhiskyWineInstaller.binFolder
    }
    /// Path to the `wine64` binary for a bottle's selected backend
    public static func wineBinary(for bottle: Bottle?) -> URL {
        binFolder(for: bottle).appending(path: "wine64")
    }
    /// Path to the `wineserver` binary for a bottle's selected backend
    private static func wineserverBinary(for bottle: Bottle?) -> URL {
        binFolder(for: bottle).appending(path: "wineserver")
    }

    /// Run a process on a executable file given by the `executableURL`
    private static func runProcess(
        name: String? = nil, args: [String], environment: [String: String], executableURL: URL, directory: URL? = nil,
        fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.currentDirectoryURL = directory ?? executableURL.deletingLastPathComponent()
        process.environment = environment
        process.qualityOfService = .userInitiated

        Logger.wineKit.info("Running: \(executableURL.path) \(args.joined(separator: " "))")
        Logger.wineKit.info("Environment: \(environment.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

        return try process.runStream(
            name: name ?? args.joined(separator: " "), fileHandle: fileHandle
        )
    }

    /// Run a `wine` process with the given arguments and environment variables returning a stream of output
    private static func runWineProcess(
        name: String? = nil, args: [String], bottle: Bottle?, environment: [String: String] = [:],
        fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        return try runProcess(
            name: name, args: args, environment: environment, executableURL: wineBinary(for: bottle),
            fileHandle: fileHandle
        )
    }

    /// Run a `wineserver` process with the given arguments and environment variables returning a stream of output
    private static func runWineserverProcess(
        name: String? = nil, args: [String], bottle: Bottle?, environment: [String: String] = [:],
        fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        return try runProcess(
            name: name, args: args, environment: environment, executableURL: wineserverBinary(for: bottle),
            fileHandle: fileHandle
        )
    }

    /// Run a `wine` process with the given arguments and environment variables returning a stream of output
    public static func runWineProcess(
        name: String? = nil, args: [String], bottle: Bottle, environment: [String: String] = [:]
    ) throws -> AsyncStream<ProcessOutput> {
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicaitonInfo()
        fileHandle.writeInfo(for: bottle)

        return try runWineProcess(
            name: name, args: args, bottle: bottle,
            environment: constructWineEnvironment(for: bottle, environment: environment),
            fileHandle: fileHandle
        )
    }

    /// Run a `wineserver` process with the given arguments and environment variables returning a stream of output
    public static func runWineserverProcess(
        name: String? = nil, args: [String], bottle: Bottle, environment: [String: String] = [:]
    ) throws -> AsyncStream<ProcessOutput> {
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicaitonInfo()
        fileHandle.writeInfo(for: bottle)

        return try runWineserverProcess(
            name: name, args: args, bottle: bottle,
            environment: constructWineServerEnvironment(for: bottle, environment: environment),
            fileHandle: fileHandle
        )
    }

    /// Execute a `wine start /unix {url}` command returning the output result.
    ///
    /// `start` is non-blocking by default: it launches the program and returns
    /// immediately, so this call resolves while the program is still running
    /// (correct for games). Pass `waitForExit: true` to insert `/wait` so the
    /// call resolves only once the launched program exits — needed for
    /// installers, where callers act on the *result* of the install.
    public static func runProgram(
        at url: URL, args: [String] = [], bottle: Bottle,
        environment: [String: String] = [:], waitForExit: Bool = false
    ) async throws {
        let allArgs = (waitForExit ? ["start", "/wait", "/unix"] : ["start", "/unix"])
            + [url.path(percentEncoded: false)] + args

        // Installer path: stream + log the output. `start /wait` keeps the `wine`
        // process alive until the installer exits, so the stream completes cleanly
        // (no surviving child holds the pipe open).
        if waitForExit {
            for await _ in try Self.runWineProcess(
                name: url.lastPathComponent, args: allArgs, bottle: bottle, environment: environment
            ) { }
            return
        }

        // Fire-and-forget launch (a game, Steam): `start` (no `/wait`) returns as soon
        // as it has launched the program, but the launched program inherits our
        // stdout/stderr — so streaming would keep the pipe's write end open (and, for
        // a busy program, flood us with output at 100% CPU) until that program exits,
        // never returning. Discard output to /dev/null and return once the `wine`
        // launcher itself exits, which is near-immediate.
        let process = Process()
        process.executableURL = wineBinary(for: bottle)
        process.arguments = allArgs
        process.currentDirectoryURL = wineBinary(for: bottle).deletingLastPathComponent()
        process.environment = constructWineEnvironment(for: bottle, environment: environment)
        process.qualityOfService = .userInitiated
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        Logger.wineKit.info("Launching: \(allArgs.joined(separator: " "))")
        try process.run()

        // Bounded wait for the launcher to exit. `wine start` normally exits in well
        // under a second once it has handed the program to wineserver — but assume any
        // wine bug could hang it, and never let that hang the caller (the CLI process,
        // or the GUI's launch task). Poll so we return promptly on the normal exit; if
        // it is still running past the deadline, abandon it: terminate the stuck
        // launcher (the program itself is owned by wineserver, not this process) and
        // return anyway.
        for _ in 0..<300 {   // ~30s at 100ms
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            Logger.wineKit.warning("`wine start` did not exit within ~30s; abandoning the launcher")
            process.terminate()
        }
    }

    public static func generateRunCommand(
        at url: URL, bottle: Bottle, args: String, environment: [String: String]
    ) -> String {
        var wineCmd = "\(wineBinary(for: bottle).esc) start /unix \(url.esc) \(args)"
        let env = constructWineEnvironment(for: bottle, environment: environment)
        for environment in env {
            wineCmd = "\(environment.key)=\"\(environment.value)\" " + wineCmd
        }

        return wineCmd
    }

    /// Run a `wineserver` command with the given arguments and return the output result
    private static func runWineserver(_ args: [String], bottle: Bottle) async throws -> String {
        var result: [ProcessOutput] = []

        for await output in try Self.runWineserverProcess(args: args, bottle: bottle, environment: [:]) {
            result.append(output)
        }

        return result.compactMap { output -> String? in
            switch output {
            case .started, .terminated:
                return nil
            case .message(let message), .error(let message):
                return message
            }
        }.joined()
    }

    @discardableResult
    /// Run a `wine` command with the given arguments and return the output result
    public static func runWine(
        _ args: [String], bottle: Bottle?, environment: [String: String] = [:]
    ) async throws -> String {
        var result: [String] = []
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicaitonInfo()
        var environment = environment

        if let bottle {
            fileHandle.writeInfo(for: bottle)
            environment = constructWineEnvironment(for: bottle, environment: environment)
        }

        for await output in try runWineProcess(
            args: args, bottle: bottle, environment: environment, fileHandle: fileHandle
        ) {
            switch output {
            case .started, .terminated:
                break
            case .message(let message), .error(let message):
                result.append(message)
            }
        }

        return result.joined()
    }

    public static func killBottle(bottle: Bottle) throws {
        Task.detached(priority: .userInitiated) {
            try await runWineserver(["-k"], bottle: bottle)
        }
    }

    /// Construct an environment merging the bottle values with the given values
    private static func constructWineEnvironment(
        for bottle: Bottle, environment: [String: String] = [:]
    ) -> [String: String] {
        let wineLibPath = WhiskyWineInstaller.libraryFolder
            .appending(path: "Wine").appending(path: "lib").path
        var result: [String: String] = [
            "WINEPREFIX": bottle.url.path,
            "WINEDEBUG": "-all",
            // Force IPv4-only name resolution. This Mac (and many behind a
            // proxy/VPN) has no working IPv6, but Steam resolves its CM/directory
            // hosts to IPv6 and hangs at login trying dead IPv6 addresses. Honoured
            // by the WINE_DISABLE_IPV6 hook in dlls/ws2_32/unixlib.c getaddrinfo().
            "WINE_DISABLE_IPV6": "1",
            "DYLD_FALLBACK_LIBRARY_PATH": wineLibPath,
            "GST_DEBUG": "1",
            // Keep DEP on for legacy 32-bit images so Wine doesn't force PROT_EXEC
            // on data pages, which makes DXMT/Metal a slideshow on macOS Tahoe
            // (3Shain/dxmt#161). Honoured by patches/wine/0002-nx-compat-env-var.patch.
            "WINE_NX_COMPAT": "1",
            // Gamepads: skip SDL's GCController backend. On macOS 27.0 beta the
            // GameController framework enumerates Xbox pads but delivers no input
            // (26.0 had the same regression); SDL's HIDAPI/IOKit path reads the
            // HID reports fine and keeps rumble. Revisit when GA fixes it.
            "SDL_JOYSTICK_MFI": "0",
            // Proton only: disable the lsteamclient bridge. Proton redirects the
            // tier0_s64/vstdlib_s64 imports of steamclient64.dll and
            // gameoverlayrenderer64.dll to ntdll so its Linux host-integrated
            // tier0 shims are used for games. That bridge can never reach a Linux
            // Steam on macOS, and when we run the real Windows Steam client the
            // redirect strands g_pMemAllocSteam et al. on unimplemented ntdll
            // stubs (our de-linux'd ntdll lacks those 297 symbols) -> steamclient64
            // DllMain access-violates on a garbage allocator vtable and Steam shows
            // "reinstall Steam". Ignored by Whisky-Wine 11.13 (no such code).
            "PROTON_DISABLE_LSTEAMCLIENT": "1",
            // Proton msync: route MANUAL-reset events (and anonymous auto-reset
            // events) to server-sync; everything else -- semaphore, mutex, named
            // auto-events, msg-queue -- stays on the fast msync path. This kills a
            // full-msync 100%-CPU spin: steam.exe pins a core inside
            // msync_wait_multiple on a rapidly set/reset MANUAL event, and once the
            // update thread is spinning the login window never gets drawn.
            // Reproduced and bisected with
            // scripts/msync-manualevent-spin-test.c: under plain msync the flapping
            // manual event burns ~13.6 CPU-s / 12.6M wakeups; NO_MANUALEVENT drops
            // it to the wineserver baseline (~6.2 CPU-s / 0.6M wakeups), matching
            // WINEMSYNC=0. Coarser lever if it ever regresses: WINEMSYNC_NO_EVENT=1
            // (all events -> server). Ignored when msync is off / lever absent.
            "WINEMSYNC_NO_MANUALEVENT": "1"
        ]
        bottle.settings.environmentVariables(wineEnv: &result)
        guard !environment.isEmpty else { return result }
        result.merge(environment, uniquingKeysWith: { $1 })
        return result
    }

    /// Construct an environment merging the bottle values with the given values
    private static func constructWineServerEnvironment(
        for bottle: Bottle, environment: [String: String] = [:]
    ) -> [String: String] {
        let wineLibPath = WhiskyWineInstaller.libraryFolder
            .appending(path: "Wine").appending(path: "lib").path
        var result: [String: String] = [
            "WINEPREFIX": bottle.url.path,
            "WINEDEBUG": "-all",
            "DYLD_FALLBACK_LIBRARY_PATH": wineLibPath,
            "GST_DEBUG": "1",
            // winedevice.exe (hosting winebus.sys) inherits its unix environment
            // from wineserver, so the gamepad workaround must be set here too.
            "SDL_JOYSTICK_MFI": "0"
        ]
        guard !environment.isEmpty else { return result }
        result.merge(environment, uniquingKeysWith: { $1 })
        return result
    }
}

enum RegistryType: String {
    case dword = "REG_DWORD"
    case string = "REG_SZ"
}

extension Wine {
    public static let logsFolder = FileManager.default.urls(
        for: .libraryDirectory, in: .userDomainMask
    )[0].appending(path: "Logs").appending(path: Bundle.whiskyBundleIdentifier)

    public static func makeFileHandle() throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: Self.logsFolder.path) {
            try FileManager.default.createDirectory(at: Self.logsFolder, withIntermediateDirectories: true)
        }

        let dateString = Date.now.ISO8601Format()
        let fileURL = Self.logsFolder.appending(path: dateString).appendingPathExtension("log")
        try "".write(to: fileURL, atomically: true, encoding: .utf8)
        return try FileHandle(forWritingTo: fileURL)
    }
}

extension Wine {
    private enum RegistryKey: String {
        case currentVersion = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion"#
        case macDriver = #"HKCU\Software\Wine\Mac Driver"#
        case desktop = #"HKCU\Control Panel\Desktop"#
    }

    static func addRegistryKey(
        bottle: Bottle, key: String, name: String, data: String, type: RegistryType
    ) async throws {
        try await runWine(
            ["reg", "add", key, "-v", name, "-t", type.rawValue, "-d", data, "-f"],
            bottle: bottle
        )
    }

    /// Delete a single registry value. Used to clear the retired webhelper
    /// wrapper's IFEO `Debugger` entry from existing bottles; `reg delete` errors
    /// when the value is absent, so callers wrap it in `try?` for an idempotent
    /// no-op on bottles that never had it.
    static func deleteRegistryValue(bottle: Bottle, key: String, name: String) async throws {
        try await runWine(["reg", "delete", key, "-v", name, "-f"], bottle: bottle)
    }

    private static func queryRegistryKey(
        bottle: Bottle, key: String, name: String, type: RegistryType
    ) async throws -> String? {
        let output = try await runWine(["reg", "query", key, "-v", name], bottle: bottle)
        let lines = output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)

        guard let line = lines.first(where: { $0.contains(type.rawValue) }) else { return nil }
        let array = line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let value = array.last else { return nil }
        return String(value)
    }

    public static func changeBuildVersion(bottle: Bottle, version: Int) async throws {
        try await addRegistryKey(bottle: bottle, key: RegistryKey.currentVersion.rawValue,
                                name: "CurrentBuild", data: "\(version)", type: .string)
        try await addRegistryKey(bottle: bottle, key: RegistryKey.currentVersion.rawValue,
                                name: "CurrentBuildNumber", data: "\(version)", type: .string)
    }

    public static func buildVersion(bottle: Bottle) async throws -> String? {
        return try await Self.queryRegistryKey(
            bottle: bottle, key: RegistryKey.currentVersion.rawValue,
            name: "CurrentBuild", type: .string
        )
    }

    public static func retinaMode(bottle: Bottle) async throws -> Bool {
        let values: Set<String> = ["y", "n"]
        guard let output = try await Self.queryRegistryKey(
            bottle: bottle, key: RegistryKey.macDriver.rawValue, name: "RetinaMode", type: .string
        ), values.contains(output) else {
            try await changeRetinaMode(bottle: bottle, retinaMode: false)
            return false
        }
        return output == "y"
    }

    public static func changeRetinaMode(bottle: Bottle, retinaMode: Bool) async throws {
        try await Self.addRegistryKey(
            bottle: bottle, key: RegistryKey.macDriver.rawValue, name: "RetinaMode", data: retinaMode ? "y" : "n",
            type: .string
        )
    }

    public static func dpiResolution(bottle: Bottle) async throws -> Int? {
        guard let output = try await Self.queryRegistryKey(bottle: bottle, key: RegistryKey.desktop.rawValue,
                                                     name: "LogPixels", type: .dword
        ) else { return nil }

        let noPrefix = output.replacingOccurrences(of: "0x", with: "")
        let int = Int(noPrefix, radix: 16)
        guard let int else { return nil }
        return int
    }

    public static func changeDpiResolution(bottle: Bottle, dpi: Int) async throws {
        try await Self.addRegistryKey(
            bottle: bottle, key: RegistryKey.desktop.rawValue, name: "LogPixels", data: String(dpi),
            type: .dword
        )
    }

    @discardableResult
    public static func changeWinVersion(
        bottle: Bottle, win: WinVersion, environment: [String: String] = [:]
    ) async throws -> String {
        return try await Self.runWine(["winecfg", "-v", win.rawValue], bottle: bottle, environment: environment)
    }
}

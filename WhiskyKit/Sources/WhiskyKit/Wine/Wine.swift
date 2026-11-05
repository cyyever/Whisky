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
        // `.environment` replaces, so a bare assignment leaves the bottle with no
        // HOME — the Vulkan loader's ICD search path. Guarded by
        // tests/env-contract-test.sh.
        //
        // DYLD_ is dropped rather than merged: we set DYLD_FALLBACK_LIBRARY_PATH,
        // but an inherited DYLD_LIBRARY_PATH is a *different* key, so the merge
        // never resolves the conflict and dyld searches it first. Running from
        // Xcode injects exactly that, plus DYLD_INSERT_LIBRARIES. Ours are
        // applied afterwards, so this only removes what the launcher inherited —
        // and no launch ever inherited one (8/8 logs carry only our own).
        process.environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("DYLD_") }
            .merging(environment, uniquingKeysWith: { $1 })
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
        // Windows 11 is the fixed target. Migrate older prefixes before their
        // first launch, and only record it after winecfg has completed.
        if bottle.settings.windowsVersion != .win11 {
            try await changeWinVersion(bottle: bottle, win: .win11)
            await MainActor.run {
                bottle.settings.windowsVersion = .win11
            }
        }
        try await enableRetinaMode(bottle: bottle)
        let allArgs =
            (waitForExit ? ["start", "/wait", "/unix"] : ["start", "/unix"])
            + [url.path(percentEncoded: false)] + args

        // Installer path: stream + log the output. `start /wait` keeps the `wine`
        // process alive until the installer exits, so the stream completes cleanly
        // (no surviving child holds the pipe open).
        if waitForExit {
            for await _ in try Self.runWineProcess(
                name: url.lastPathComponent, args: allArgs, bottle: bottle, environment: environment
            ) {}
            return
        }

        // Fire-and-forget launch (a game, Steam): `start` (no `/wait`) returns as soon
        // as it has launched the program, but the launched program inherits our
        // stdout/stderr — so *streaming* would keep the pipe's write end open (and, for
        // a busy program, flood us with output at 100% CPU) until that program exits,
        // never returning. A log **file** has neither problem: nobody reads it, so there
        // is no backpressure and no reader to keep alive, and the launched program
        // inheriting the fd is the point — that is how we get Steam's own stderr after
        // `wine start` is long gone. Return once the launcher itself exits.
        //
        // This used to be /dev/null, which made WINEDEBUG useless on the GUI launch
        // path — the only launch path whose results count for Steam (a bare CLI launch
        // is not equivalent; Steam logs `no bootstrapper found`). Debugging anything
        // that only reproduces under the GUI launch needs somewhere for the trace to
        // land. Default WINEDEBUG is `-all`, so the file stays near-empty unless a
        // bottle or per-program setting asks for channels.
        let process = Process()
        process.executableURL = wineBinary(for: bottle)
        process.arguments = allArgs
        process.currentDirectoryURL = wineBinary(for: bottle).deletingLastPathComponent()
        // As in `runProcess`, merge Whisky's environment with inherited values.
        let wineEnv = constructWineEnvironment(for: bottle, environment: environment)
        process.environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("DYLD_") }
            .merging(wineEnv, uniquingKeysWith: { $1 })
        process.qualityOfService = .userInitiated
        if let fileHandle = try? makeFileHandle() {
            fileHandle.writeApplicaitonInfo()
            fileHandle.writeInfo(for: bottle)
            fileHandle.writeInfo(for: process)
            process.standardOutput = fileHandle
            process.standardError = fileHandle
        } else {
            // Logging is a debugging aid; never let it stop a launch.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        Logger.wineKit.info("Launching: \(allArgs.joined(separator: " "))")
        try process.run()

        // Bounded wait for the launcher to exit. `wine start` normally exits in well
        // under a second once it has handed the program to wineserver — but assume any
        // wine bug could hang it, and never let that hang the caller (the CLI process,
        // or the GUI's launch task). Poll so we return promptly on the normal exit; if
        // it is still running past the deadline, abandon it: terminate the stuck
        // launcher (the program itself is owned by wineserver, not this process) and
        // return anyway.
        for _ in 0..<300 {  // ~30s at 100ms
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            Logger.wineKit.warning("`wine start` did not exit within ~30s; abandoning the launcher")
            process.terminate()
        }
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
        // Only what the launcher alone can know. The constants that used to sit
        // here — WINE_DISABLE_IPV6, WINE_NX_COMPAT, WINEMSYNC_NO_MANUALEVENT,
        // PROTON_DISABLE_LSTEAMCLIENT, SDL_JOYSTICK_MFI — are now defaults in the
        // code that reads them (patches 0011, 0019, 0008, 0031, 0032), each still
        // overridable by setting the variable to "0". A constant set here has to
        // be mirrored by hand in every harness that stands in for a GUI launch,
        // and those mirrors drift.
        var result: [String: String] = [
            "WINEPREFIX": bottle.url.path,
            "WINEDEBUG": "-all",
            "DYLD_FALLBACK_LIBRARY_PATH": wineLibPath,
            // Rosetta reads this before Wine starts. All supported macOS
            // versions translate AVX/AVX2; advertise it so games can detect
            // those instructions without a per-bottle preference.
            "ROSETTA_ADVERTISE_AVX": "1",
            // No GST_PLUGIN_PATH / GST_PLUGIN_SCANNER: GStreamer locates both
            // relative to libgstreamer-1.0.dylib's own load address (dladdr, see
            // priv_gst_get_relocated_libgstreamer), which lands in Wine/lib once
            // build-proton-x86.sh has fixed the install names and rpaths. Setting
            // them made no measurable difference, and a constant here has to be
            // mirrored by hand in every harness that stands in for a GUI launch.
            "GST_DEBUG": "1",
        ]
        bottle.settings.environmentVariables(wineEnv: &result)
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
            "ROSETTA_ADVERTISE_AVX": "1",
            "GST_DEBUG": "1",
        ]
        // The same bottle settings the clients get. WINEMSYNC is the one that
        // must not diverge: server/msync.c has its own do_msync(), so leaving
        // this out let a bottle with enhanced sync set to none run clients on
        // server-sync while the wineserver still believed msync was on. Neither
        // half is wrong on its own, which is what makes it easy to miss --
        // and it silently invalidates any msync A/B run through this path,
        // because only one side of the pair actually changed. Everything else
        // here is inert server-side but is inherited by the processes wineserver
        // spawns.
        bottle.settings.environmentVariables(wineEnv: &result)
        result.merge(environment, uniquingKeysWith: { $1 })
        return result
    }
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
    /// Retina rendering is fixed on for new and existing bottles before launch.
    public static func enableRetinaMode(bottle: Bottle) async throws {
        for await output in try runWineProcess(
            args: [
                "reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "-v", "RetinaMode",
                "-t", "REG_SZ", "-d", "y", "-f",
            ], bottle: bottle
        ) {
            if case .terminated(let process) = output, process.terminationStatus != 0 {
                throw NSError(
                    domain: "WhiskyKit.Wine", code: Int(process.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Enabling Retina mode failed with exit code \(process.terminationStatus).",
                    ]
                )
            }
        }
    }

    @discardableResult
    public static func changeWinVersion(
        bottle: Bottle, win: WinVersion, environment: [String: String] = [:]
    ) async throws -> String {
        var result = ""
        for await output in try runWineProcess(
            args: ["winecfg", "-v", win.rawValue], bottle: bottle, environment: environment
        ) {
            switch output {
            case .started:
                break
            case .message(let message), .error(let message):
                result += message
            case .terminated(let process):
                guard process.terminationStatus == 0 else {
                    throw NSError(
                        domain: "WhiskyKit.Wine", code: Int(process.terminationStatus),
                        userInfo: [
                            NSLocalizedDescriptionKey: "winecfg failed with exit code \(process.terminationStatus)."
                        ]
                    )
                }
            }
        }
        return result
    }
}

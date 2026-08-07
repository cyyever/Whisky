//
//  SystemProxy.swift
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

import CFNetwork
import Foundation
import Network
import Synchronization

/// Reads macOS's active proxy configuration and renders it as the
/// `http_proxy` / `https_proxy` / `no_proxy` environment variables that
/// libcurl-based clients understand (notably Steam's bootstrapper, which
/// otherwise connects directly to its CDN and can stall on a blocked network).
///
/// This reflects the *system* proxy (System Settings › Network › Proxies, which
/// is what a tool like Clash sets when its "system proxy" toggle is on), so it
/// works even when Whisky is launched from the Dock. Automatic proxy
/// configuration (PAC) is resolved by executing the script against a
/// representative outbound URL.
///
/// Note: this does *not* apply to VPN / "TUN" style tunnels, which route traffic
/// transparently at the IP layer and need no proxy variables at all.
public enum SystemProxy {
    /// A representative outbound URL used to resolve which proxy the system would
    /// pick (PAC scripts can return different proxies per host; Steam traffic is
    /// the case we care about here).
    private static let representativeURL = URL(string: "https://store.steampowered.com")!

    public static func environmentVariables() -> [String: String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
            return [:]
        }
        let proxies = resolvedProxies(for: representativeURL, settings: settings)

        // Prefer a SOCKS proxy tunneled via the bundled proxychains-ng: it hooks
        // connect() at the socket layer, so it carries EVERY TCP connection —
        // including Steam's raw-socket CM/connectivity, which no http_proxy env can
        // reach (those go straight out and get reset on a filtering network). http_proxy only helps
        // HTTP-aware clients, so it is the fallback when no SOCKS proxy is set.
        if let socks = socksProxyEnvironment(from: proxies) {
            return socks
        }

        var result: [String: String] = [:]

        for proxy in proxies {
            guard let type = proxy[kCFProxyTypeKey as String] as? String,
                type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String),
                let host = proxy[kCFProxyHostNameKey as String] as? String, !host.isEmpty
            else {
                continue
            }
            // The proxy server speaks HTTP for both schemes (HTTPS via CONNECT).
            // PAC scripts (e.g. Clash's) often advertise the proxy as 0.0.0.0,
            // which isn't a usable connect target — rewrite it to loopback.
            let resolvedHost = host == "0.0.0.0" ? "127.0.0.1" : host
            let port = proxy[kCFProxyPortNumberKey as String] as? Int
            let url = port.map { "http://\(resolvedHost):\($0)" } ?? "http://\(resolvedHost)"
            result["http_proxy"] = url
            result["https_proxy"] = url
            break
        }

        // Hosts the system never proxies (loopback, RFC1918, *.local, …).
        if let settingsDict = settings as? [String: Any],
            let exceptions = settingsDict[kCFNetworkProxiesExceptionsList as String] as? [String],
            !exceptions.isEmpty
        {
            result["no_proxy"] = exceptions.joined(separator: ",")
        }

        // Some clients only look for the uppercase spellings; provide both.
        for (key, value) in Array(result) {
            result[key.uppercased()] = value
        }
        return result
    }

    /// If the system has a SOCKS proxy configured **and** the bundled
    /// proxychains-ng dylib is installed, returns the env that DYLD-injects
    /// proxychains into the (Rosetta) wine process and points it at that SOCKS
    /// proxy — so every raw `connect()`, Steam's CM/connectivity included, is
    /// tunneled. `nil` when there is no SOCKS proxy or the dylib isn't built, so
    /// the caller falls back to the http_proxy path.
    private static func socksProxyEnvironment(from proxies: [[String: Any]]) -> [String: String]? {
        guard
            let socks = proxies.first(where: {
                ($0[kCFProxyTypeKey as String] as? String) == (kCFProxyTypeSOCKS as String)
            }), let host = socks[kCFProxyHostNameKey as String] as? String, !host.isEmpty
        else {
            return nil
        }
        let resolvedHost = host == "0.0.0.0" ? "127.0.0.1" : host
        let port = (socks[kCFProxyPortNumberKey as String] as? Int) ?? 1080

        let dir = WhiskyWineInstaller.libraryFolder.appending(path: "ProxyChains")
        let dylib = dir.appending(path: "libproxychains4.dylib")
        guard FileManager.default.fileExists(atPath: dylib.path(percentEncoded: false)) else {
            return nil  // proxychains-ng not built (`make proxychains`) — fall back to http_proxy
        }

        // Stale-SOCKS fallback. A TUN-style VPN (Geph in TUN mode, or a VPN that
        // was just quit) can leave a SOCKS entry in the system settings pointing at
        // a port nothing is serving (here, 127.0.0.1:9909 with Geph in TUN mode).
        // proxychains' strict_chain fails every connection closed, so injecting at a
        // dead port would black-hole ALL of Wine's TCP — Steam would never reach its
        // CM and login would hang forever, even though the network is fine (the TUN
        // captures traffic at the IP layer regardless). Probe the port; if nothing's
        // listening, fall back to http_proxy / direct instead of poisoning Wine.
        guard isProxyPortReachable(resolvedHost, port) else {
            return nil
        }

        // proxy_dns is deliberately OFF: proxychains' fake-IP DNS remap breaks
        // Steam's manifest HTTPS. DNS resolves directly; only TCP connect() is
        // tunneled through SOCKS (verified: Steam reaches "Connected" this way).
        // localnet keeps loopback/LAN direct: Steam's steam.exe<->steamwebhelper
        // IPC and the SOCKS proxy itself live on 127.0.0.1, and RFC1918/link-local
        // shouldn't be tunneled — only external TCP goes through SOCKS.
        let conf = dir.appending(path: "proxychains.conf")
        let body = """
            strict_chain
            tcp_read_time_out 15000
            tcp_connect_time_out 8000
            localnet 127.0.0.0/255.0.0.0
            localnet 10.0.0.0/255.0.0.0
            localnet 172.16.0.0/255.240.0.0
            localnet 192.168.0.0/255.255.0.0
            localnet 169.254.0.0/255.255.0.0
            [ProxyList]
            socks5 \(resolvedHost) \(port)

            """
        // Only inject proxychains once its config is actually on disk — otherwise
        // the dylib loads with no readable config and aborts inside every (Rosetta)
        // wine process, breaking all launches. Fall back to the http_proxy path.
        do {
            try body.write(to: conf, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        return [
            "DYLD_INSERT_LIBRARIES": dylib.path(percentEncoded: false),
            "PROXYCHAINS_CONF_FILE": conf.path(percentEncoded: false),
        ]
    }

    /// Whether a TCP `connect()` to `host:port` completes within a short deadline.
    /// Used to avoid injecting proxychains at a SOCKS port the system settings
    /// advertise but nothing is actually serving (a stale entry left by a TUN-mode
    /// or just-quit VPN). `[weak connection]` breaks the retain cycle between the
    /// `NWConnection` and its state handler; the system holds the connection while
    /// started, so cancelling it (on success, failure, or timeout) releases both.
    /// A dead loopback port refuses in well under a millisecond; the 400ms cap only
    /// bites a silently-dropped SYN against a remote proxy, and never hangs launch.
    private static func isProxyPortReachable(_ host: String, _ port: Int) -> Bool {
        guard let endpoint = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        // Mutex (not a plain `var`) because the state handler runs on a background
        // queue — Swift 6 forbids mutating a captured local across that boundary.
        let reachable = Mutex(false)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                reachable.withLock { $0 = true }
                connection.cancel()
                semaphore.signal()
            case .failed:
                connection.cancel()
                semaphore.signal()
            default:
                break  // .setup / .preparing / .cancelled — keep waiting for a verdict
            }
        }
        connection.start(queue: .global())
        let timedOut = semaphore.wait(timeout: .now() + .milliseconds(400)) == .timedOut
        if timedOut { connection.cancel() }
        return reachable.withLock { $0 }
    }

    /// The concrete proxies the system would use for `url`, executing any
    /// auto-configuration (PAC) script encountered.
    private static func resolvedProxies(for url: URL, settings: CFDictionary) -> [[String: Any]] {
        guard
            let raw = CFNetworkCopyProxiesForURL(url as CFURL, settings)
                .takeRetainedValue() as? [[String: Any]]
        else {
            return []
        }

        var resolved: [[String: Any]] = []
        for proxy in raw {
            let type = proxy[kCFProxyTypeKey as String] as? String
            if type == (kCFProxyTypeAutoConfigurationURL as String),
                let pacURL = proxy[kCFProxyAutoConfigurationURLKey as String]
            {
                // swiftlint:disable:next force_cast
                resolved.append(contentsOf: executePAC(scriptURL: pacURL as! CFURL, targetURL: url))
            } else {
                resolved.append(proxy)
            }
        }
        return resolved
    }

    /// Synchronously evaluates a PAC script for `targetURL` and returns the
    /// proxies it selects. Bounded so a missing/slow PAC server can't hang launch.
    private static func executePAC(scriptURL: CFURL, targetURL: URL) -> [[String: Any]] {
        final class Box { var proxies: [[String: Any]] = [] }
        let box = Box()

        var context = CFStreamClientContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: CFProxyAutoConfigurationResultCallback = { info, proxyList, error in
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            if error == nil, let list = (proxyList as NSArray) as? [[String: Any]] {
                box.proxies = list
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }

        let source = CFNetworkExecuteProxyAutoConfigurationURL(
            scriptURL, targetURL as CFURL, callback, &context
        )

        let mode = CFRunLoopMode.defaultMode
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, mode)
        CFRunLoopRunInMode(mode, 5, false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, mode)
        return box.proxies
    }
}

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

        var result: [String: String] = [:]

        for proxy in resolvedProxies(for: representativeURL, settings: settings) {
            guard let type = proxy[kCFProxyTypeKey as String] as? String,
                  type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String),
                  let host = proxy[kCFProxyHostNameKey as String] as? String, !host.isEmpty else {
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
           !exceptions.isEmpty {
            result["no_proxy"] = exceptions.joined(separator: ",")
        }

        // Some clients only look for the uppercase spellings; provide both.
        for (key, value) in result {
            result[key.uppercased()] = value
        }
        return result
    }

    /// The concrete proxies the system would use for `url`, executing any
    /// auto-configuration (PAC) script encountered.
    private static func resolvedProxies(for url: URL, settings: CFDictionary) -> [[String: Any]] {
        guard let raw = CFNetworkCopyProxiesForURL(url as CFURL, settings)
            .takeRetainedValue() as? [[String: Any]] else {
            return []
        }

        var resolved: [[String: Any]] = []
        for proxy in raw {
            let type = proxy[kCFProxyTypeKey as String] as? String
            if type == (kCFProxyTypeAutoConfigurationURL as String),
               let pacURL = proxy[kCFProxyAutoConfigurationURLKey as String] {
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

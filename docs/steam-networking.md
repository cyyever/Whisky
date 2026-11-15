# Steam networking

Enable **Follow System Proxy** in the bottle to use the macOS proxy settings.
Whisky uses the bundled proxychains-ng for SOCKS proxies, with HTTP proxy
variables as the fallback. Build proxychains with `make proxychains`.

- SOCKS forwarding covers external TCP connections; it is not a system VPN.
- `proxy_dns` is disabled. DNS is not forwarded by this configuration.
- Whisky checks the SOCKS port before injecting proxychains. A host-side
  connectivity test does not prove that Wine is using the same proxy path.
- With a system VPN, disable **Follow System Proxy** to avoid additionally
  injecting proxychains. Routing and DNS then depend on the VPN configuration.

Implementation: [`SystemProxy.swift`](../WhiskyKit/Sources/WhiskyKit/PlatformMacOS/SystemProxy.swift).

A black Steam window alone does not establish a network failure. Check Steam's
`logs/connection_log.txt`, `logs/cef_log.txt`, and the Whisky launch log separately.

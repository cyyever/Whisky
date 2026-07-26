# Steam networking through a proxy

On a network that filters DNS or resets some connections, Steam under Whisky can
load the store/CDN yet stay **`[Logged Off]`**. This note explains why and what to do.

## Why login fails when the CDN works

Login is done by `steamclient`'s Connection Manager (CM), **not** by `steamwebhelper`
(CEF) — the CDN/HTTPS content you see load is a separate path. The CM opens a
WebSocket-over-TLS to `*.steamserver.net:443` after resolving `api.steampowered.com`
and the CM hosts through the OS resolver (`getaddrinfo` → macOS). So a stuck login is
the CM socket, or its DNS lookups, failing — not the CDN.

## The limitation

Whisky tunnels a bottle through the system SOCKS proxy with proxychains-ng, a
`connect()` hook that only covers **TCP over IPv4** (`SystemProxy.swift`). It cannot
carry **UDP** (so DNS goes direct), **IPv6**, or a component's **own** DNS (Chromium's
built-in resolver does raw UDP:53 + DoH). On a filtering network those direct
lookups/connections are what break.

## What Whisky does

- **All TCP through SOCKS** — CDN and the CM WebSocket (both TCP/443).
- **CEF uses the OS resolver** — the webhelper wrapper appends
  `--disable-async-dns --dns-over-https-mode=off`, so Chromium resolves through Wine's
  `ws2_32` (same path as steamclient) instead of its own DNS/DoH.
- **Prefix hosts file honored** — `patches/proton-wine/0018` makes `getaddrinfo` read
  `C:\windows\system32\drivers\etc\hosts` first (standard Windows behavior Wine
  omitted). An escape hatch to pin a host inside the bottle; not auto-populated.

## The complete fix: a system TUN

Carrying UDP + TCP + IPv6 + DNS uniformly needs an **IP-layer tunnel** — tun2socks, or
a VPN in TUN mode, pointed at the same backend. It routes every packet the Wine process
emits, so Steam's DNS, IPv6, and CM traffic all go through the tunnel with no per-host
maintenance. This lives outside Whisky (a TUN needs a privileged network device);
Whisky just stays out of the way — with no SOCKS proxy reported it sets no proxy vars,
so TUN traffic flows untouched.

Operational: run the tunnel in TUN mode and turn **Follow System Proxy OFF** in the
bottle; launch games from the Steam **Play** button.

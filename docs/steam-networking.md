# Steam networking through a proxy

On a network that filters DNS or resets some connections, Steam under Whisky can
load the store/CDN yet stay **`[Logged Off]`**. This note explains why and what to do.

> **Read this first.** As of 2026-08-07 Steam logs in fully here with **no proxy and
> no TUN** (`RecvMsgClientLogOnResponse 'OK'`, full UI). The long-standing
> "login is blocked, the fix is a system TUN" conclusion was reached *before* the
> DXMT child-HWND fix (`docs/steam-webhelper.md` §0) and was never re-verified; the
> actual blocker was that bug, not the network. What follows is architecture plus
> advice for a genuinely filtering network — not a prerequisite for logging in.

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
- **CEF keeps its built-in resolver** — Chromium's own async DNS resolves the login
  page fine, so the login window paints. Do **not** add `--disable-async-dns` to route
  it through Wine's `ws2_32`: under Wine that system-resolver path returns
  WSAEOPNOTSUPP (`net::ERR_FAILED`) and the login window never loads (verified). The
  CEF flags Whisky sets (`--no-sandbox`, via proton-wine patch `0020`)
  deliberately exclude `--disable-async-dns` for this reason (see `docs/steam-webhelper.md`).
- **Prefix hosts file honored** — `patches/proton-wine/0018` makes `getaddrinfo` read
  `C:\windows\system32\drivers\etc\hosts` first (standard Windows behavior Wine
  omitted). An escape hatch to pin a host inside the bottle; not auto-populated.

## If you do need a tunnel: use a system TUN, not proxychains

Carrying UDP + TCP + IPv6 + DNS uniformly needs an **IP-layer tunnel** — tun2socks, or
a VPN in TUN mode, pointed at the same backend. It routes every packet the Wine process
emits, so Steam's DNS, IPv6, and CM traffic all go through the tunnel with no per-host
maintenance. This lives outside Whisky (a TUN needs a privileged network device);
Whisky just stays out of the way — with no SOCKS proxy reported it sets no proxy vars,
so TUN traffic flows untouched.

Operational: run the tunnel in TUN mode and turn **Follow System Proxy OFF** in the
bottle; launch games from the Steam **Play** button.

## Dead ends (measured, do not redo)

- **`Steam.exe -tcp`**, to force the CM onto TCP so proxychains could tunnel it. The
  flag reached the command line; login still stalled at `OnLoginStateChange 0 1`.
- **`proxy_dns` ON in `proxychains.conf`** (with `remote_dns_subnet 224`). Strictly
  worse: Steam then hung earlier, at `Downloading manifest:
  client-update.steamstatic.com`, at 0% CPU. This is why `SystemProxy.swift` keeps
  `proxy_dns` off. proxychains has no setting that satisfies both — DNS direct fails
  CM login on a filtering network, DNS through the proxy breaks manifest HTTPS.
- **A dead SOCKS port is worse than none.** `strict_chain` fails closed, so every Wine
  `connect()` dies and every host-side probe (`curl`, `nc`) still passes because it
  bypasses the system proxy. `SystemProxy.swift` probes the port for liveness before
  injecting proxychains for this reason.
- There is **no `make steam-helper`** target; the Makefile has `make proxychains`.

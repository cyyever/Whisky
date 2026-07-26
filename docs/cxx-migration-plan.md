# WhiskyKit → cross-platform C++ core: migration plan

Goal: restructure so the portable logic can become a shared **C++ core** driving a
cross-platform frontend (Qt/wxWidgets) on **macOS + FreeBSD**, while macOS keeps
its native SwiftUI shell during the transition (via Swift/C++ interop).

The core is kept **as small as possible** by two rules, applied everywhere:
1. **Don't do what wine can do.** If a bundled wine tool answers the question
   (`winedump`, `winepath`, `wine reg`, `winecfg`), call it — don't reimplement it.
   Deleted code is code the C++ core never has to carry.
2. **Don't put in core what belongs to the OS or the UI.** OS differences hide
   behind a tiny protocol seam; UI concerns live in the frontend.

This doc is the *target architecture* and the staged path to it. Stage 0 (the
`PlatformServices.swift` protocol skeleton + this doc) is done, and the hard-macOS
files are gathered under `PlatformMacOS/`; the rest of the reorg is pending.

## Three layers

```
frontend            SwiftUI app (macOS, today)  ┐ Qt/wx (macOS+FreeBSD, later)
  observation, alerts, icon display, views      ┘ — thin; the real work is below

platform-<os>       concrete conformances to the Core seam
  macOS:   SystemProxy(CFNetwork), Rosetta2(sysctl), bundled-Wine layout + DYLD/
           KosmicKrisp env, Metal/DXMT
  freebsd: env-proxy, uname, PATH-Wine + LD_LIBRARY_PATH, native Vulkan (no DXMT)

core                portable: models, PE/lnk parsing, Wine/Steam orchestration,
                    Steam single-instance guard (pkill/pgrep), file watching
                    (kqueue) — depends only on the platform seam protocols
```

## Principle: delegate to wine, don't reimplement

The biggest lever for a *small* C++ core is to **not port what wine already does**.
Every bottle ships the full wine toolchain (`Wine/bin/winedump`, `winepath`, …), so
prefer a wine tool over a hand-rolled implementation — each one deleted is code the
C++ core never has to carry.

| Whisky does today | wine tool that replaces it | Status |
|---|---|---|
| Hand-rolled PE **import** parse (DXVK d3d9/d3d8 detect) | `winedump -j import <exe>` | bundled; not yet forwarded |
| PE **architecture** (win32/win64) | `winedump -f`, or host `file` | one field |
| Registry read/write | `wine reg query` / `add` | **already forwarded** ✓ |
| Windows↔Unix paths | `winepath -u/-w` | the plan for prefix paths |
| Win version / DPI / retina | `winecfg` / `wine reg` | **already forwarded** ✓ |

The one thing wine tools can't hand back cleanly is a rendered **icon** for the
program list (`PEFile.bestIcon()` → `NSImage`). That keeps a PE/RSRC resource parser
alive — but it is a **frontend** concern, not core. So the parser survives only for
icon display in the UI layer; the **import/arch** logic the *core* needs should
forward to `winedump` and leave core.

Caveat: forwarding spawns a subprocess. For a hot loop (winedump per exe across a big
Steam library) measure first — in-process parsing may still win on speed. The
migration goal (smaller core) and the runtime goal (fewer subprocesses) can conflict;
decide per call site, and never silently drop coverage to save a spawn.

## The platform seam is small

Only genuinely **behavioral** per-OS differences are protocols. Everything else is
data or already portable.

| Concern | Where it goes | Why |
|---|---|---|
| Proxy resolution | `ProxyResolver` **protocol** | CFNetwork+PAC vs. env parsing — real code difference |
| Arch / translation | `ArchInfo` **protocol** | `sysctl proc_translated` vs. `uname` |
| Wine binary location + launch env | `WineHostConfig` **data** | Can't come from wine CLI (bootstrap), but it's just a path + env dict |
| Prefix paths (drive_c, Win↔Unix, registry) | **Core**, via wine CLI | `winepath`, `wine reg query` — identical on every OS |
| File watching (Steam library) | **Core**, kqueue/DispatchSource | FSEvents is macOS-only; kqueue works on Darwin + BSD (or poll) |
| Icon rendering, alerts, observation | **frontend** | UI-toolkit concerns, not OS concerns |

### Why not a richer `WinePaths`/`WineHost` protocol

Most "Wine path" questions are answerable by **calling the wine CLI** (`winepath`,
`reg query`), which is the same everywhere → Core, portable. The only thing wine
*cannot* tell you is where its own binary is and what loader env to launch it with
(chicken-and-egg) — and that is plain **data** (`WineHostConfig`), not behavior. So
no behavioral protocol is needed for it.

## File classification (current WhiskyKit)

**Core (portable, keep):** `BottleSettings`, `ProgramSettings`, `BottleData`,
`GamingPlatform`, `Steam`, `Steam+LaunchGuard`, `Wine` orchestration,
`Extensions/{FileManager,URL,Bundle,FileHandle,Process}`.

**→ delete from core, forward to wine (rule 1):** the PE **import** scan and
**architecture** read (`PE/**` as used by the DXVK auto-drop and the arch label) →
`winedump -j import` / `winedump -f`. The core stops parsing PE bytes for these.

**→ platform-macOS (behind the seam):** `SystemProxy` (→ `ProxyResolver`),
`Rosetta2` (→ `ArchInfo`), `WhiskyWineInstaller` install layout (→ `WineHostConfig`
producer).

**→ Core, but rewrite off macOS API:** `SteamLibraryWatcher` (FSEvents → kqueue).

**→ frontend (UI coupling to peel out):** the PE **icon** path (`BitmapInfo`,
`PE/RSRC/**`, `PortableExecutable.bestIcon()` → `NSImage`) — the *only* reason a PE
resource parser survives, and it belongs to the UI layer, not core;
`Program+Extensions` alert (`NSAlert`); and the **`ObservableObject` conformance on
`Bottle`/`Program`** (SwiftUI) — the models must lose SwiftUI so core is UI-agnostic;
observation moves to a frontend wrapper.

**Examined, kept (no wine equivalent):** `ShellLink` (.lnk → target path for the
Start-menu program list) — wine resolves `.lnk` when launching but exposes no CLI to
read a shortcut's target, so this parse stays in core.

**Dead (delete outright):** `replaceDLLs` (no callers).

## Backend differences to plan around (not just GUI)

- **Rosetta 2 is macOS-only.** FreeBSD/x86 needs no translation; FreeBSD/ARM has no
  equivalent — a hard capability gap.
- **DXMT = Metal = macOS-only.** FreeBSD renders D3D11/10 via wined3d or a Vulkan
  path, not DXMT.
- **KosmicKrisp (Metal-on-Vulkan) is macOS-only.** BSD uses native Mesa Vulkan.
- **Proxy:** CFNetwork on macOS; env/config on BSD.

## Staged path

- **Stage 0 — skeleton (done):** `PlatformServices.swift` (`ProxyResolver`,
  `ArchInfo`, `WineHostConfig`) + this doc, and the hard-macOS files gathered under
  `PlatformMacOS/`. No behavior change; single SPM target; build green.
- **Stage 1 — directory reorg, single SPM target:** group files into `Core/` and
  `PlatformMacOS/`; make `SystemProxy`/`Rosetta2` conform to the seam; build stays
  green throughout. Surfaces every Core→platform reference as a same-target call to
  convert next.
- **Stage 2 — enforce via SPM targets:** split `WhiskyCore` + `WhiskyPlatformMacOS`
  (Core→Platform blocked by the compiler); decouple `Bottle`/`Program` from
  `ObservableObject`; rewrite the FSEvents watcher on kqueue. `WhiskyKit` becomes an
  umbrella re-exporting both so the app's `import WhiskyKit` is unchanged.
- **Stage 3 — C++ core:** port the (now UI- and OS-clean) Core to C++; macOS keeps
  SwiftUI via Swift/C++ interop; add the Qt/wx frontend + a FreeBSD platform backend.

## Frontend toolkit — decide late

The GUI is thin (bottle list + config + launch). Options, in rough order of fit:
share the C++ core and keep **SwiftUI native on macOS** + a second thin frontend for
BSD; or one cross-platform toolkit — **wxWidgets** (native controls, light) or
**Qt** (heavier, larger ecosystem). Pick after the core exists.

# Wine Bug Report: wineboot --init hangs on macOS 26 (Tahoe)

## Title
wineboot --init hangs indefinitely during prefix creation on macOS 26 (Tahoe)

## Version
Wine 11.5 (also reproducible on 11.0-11.4)

## Platform
macOS 26.4 (Tahoe), Apple M2, x86_64 Wine via Rosetta 2

## Related
Bug #58915 (winemac: Only check if event pipe is drained with QS_ALLINPUT)

## Description

Running `wineboot --init` to create a new prefix hangs indefinitely on macOS 26 (Tahoe). The process never completes and must be killed manually.

The hang occurs during the `rundll32 setupapi,InstallHinfSection` step. Despite the fix in commit b3291a27544 (bug #58915), the issue persists on macOS 26.

## Root Cause

rundll32.c creates its window with `WS_VISIBLE` style (line 274):

```c
hWnd = CreateWindowW(L"class_rundll32", L"rundll32", WS_OVERLAPPEDWINDOW|WS_VISIBLE,
      CW_USEDEFAULT, 0, CW_USEDEFAULT, 0, NULL, NULL, NULL, NULL);
```

On macOS 26, creating a visible window triggers this chain:
1. `CreateWindowW` with `WS_VISIBLE` → winemac.drv shows the window
2. `cocoa_window.m:1740` calls `transformProcessToForeground`
3. This sets `NSApplicationActivationPolicyRegular` and activates the app
4. `applicationDidBecomeActive:` fires → calls `sendDisplaysChanged:TRUE`
5. Display-change events are posted to Wine event queues
6. winemac.drv's clipboard manager starts a 2-second `WM_TIMER` (clipboard.c:1328)
7. The message pump inside `CreateWindowW` dispatches these events and timers
8. Processing events triggers more Cocoa activation callbacks → goto step 4

rundll32 never reaches `LoadLibraryW(szDllName)` or `InstallHinfSection` because it's stuck in the message pump inside `CreateWindowW`.

## Evidence

WINEDEBUG trace shows rundll32 (thread 0058) entering `macdrv_ProcessEvents` every 2 seconds and never progressing past window creation:

```
182779.011:0058:trace:event:macdrv_ProcessEvents mask 1cff
182781.011:0058:trace:event:macdrv_ProcessEvents mask 1cff
182783.011:0058:trace:event:macdrv_ProcessEvents mask 1cff
[repeats indefinitely at 2s intervals = CLIPBOARD_UPDATE_DELAY]
```

## Fix

Remove `WS_VISIBLE` from rundll32's window creation. The window is passed to the called DLL function as an HWND parameter; the function can show it if needed.

```diff
-    hWnd = CreateWindowW(L"class_rundll32", L"rundll32", WS_OVERLAPPEDWINDOW|WS_VISIBLE,
+    hWnd = CreateWindowW(L"class_rundll32", L"rundll32", WS_OVERLAPPEDWINDOW,
           CW_USEDEFAULT, 0, CW_USEDEFAULT, 0, NULL, NULL, NULL, NULL);
```

Tested: prefix creation completes successfully with this change on macOS 26.4.

## Workaround

`WINEDLLOVERRIDES="winemac.drv=d" wineboot --init` also works but disables the Mac display driver entirely during init.

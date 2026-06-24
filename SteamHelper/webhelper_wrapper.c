/*
 * webhelper_wrapper.c
 *
 * This file is part of Whisky.
 *
 * A launcher for Steam's steamwebhelper.exe (CEF host), wired up through the
 * image's "Debugger" Image File Execution Options value (see Steam.swift). When
 * Steam starts steamwebhelper.exe, Wine instead runs:
 *
 *     steamwebhelper_wrapper.exe  <full path to steamwebhelper.exe>  <original args...>
 *
 * We launch the genuine binary (kept untouched on disk as steamwebhelper.exe and
 * copied alongside as steamwebhelper_real.exe) and append the flags Steam's CEF
 * needs to render under Wine on macOS:
 *
 *     --no-sandbox          CEF's sandbox hooks into the NT kernel and breaks under Wine
 *     --in-process-gpu      avoids the out-of-process GPU sandbox "cannot reset D3D device" failure
 *     --disable-gpu         force the software render path
 *     --disable-gpu-compositing
 *
 * We launch steamwebhelper_real.exe (a copy under a different name) rather than
 * steamwebhelper.exe so the IFEO Debugger redirect does not recurse, and so the
 * on-disk steamwebhelper.exe stays byte-identical to Valve's binary and passes
 * Steam's startup file verification (otherwise Steam re-downloads it every launch).
 *
 * Built as a GUI subsystem app (-mwindows) so no console window appears; the
 * child is spawned with CREATE_NO_WINDOW for the same reason.
 *
 * Whisky is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version. See https://www.gnu.org/licenses/.
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char *argv[]) {
    char cmdline[32768];
    char realdir[MAX_PATH];
    char *lastslash;
    int offset;

    // argv[1] is the genuine steamwebhelper.exe path Steam tried to launch
    // (injected by the IFEO Debugger redirect). Its directory holds our copy
    // steamwebhelper_real.exe. argv[2..] are Steam's original arguments.
    if (argc < 2) return 1;

    strncpy(realdir, argv[1], MAX_PATH - 1);
    realdir[MAX_PATH - 1] = '\0';
    lastslash = strrchr(realdir, '\\');
    if (lastslash) *(lastslash + 1) = '\0';
    else realdir[0] = '\0';

    // Build command: real exe + original args (argv[2..]) + our extra flags
    offset = snprintf(cmdline, sizeof(cmdline), "\"%ssteamwebhelper_real.exe\"", realdir);
    if (offset < 0 || (size_t)offset >= sizeof(cmdline)) return 1;

    // Check if flags are already present (defensive; child re-invocation)
    int already_patched = 0;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--in-process-gpu") == 0) {
            already_patched = 1;
            break;
        }
    }

    // Append all original arguments with bounds checking
    for (int i = 2; i < argc; i++) {
        int needed;
        if (strchr(argv[i], ' ')) {
            needed = snprintf(cmdline + offset, sizeof(cmdline) - offset,
                              " \"%s\"", argv[i]);
        } else {
            needed = snprintf(cmdline + offset, sizeof(cmdline) - offset,
                              " %s", argv[i]);
        }
        if (needed < 0 || (size_t)(offset + needed) >= sizeof(cmdline)) return 1;
        offset += needed;
    }

    // Append our Wine-compatibility flags only if not already present
    if (!already_patched) {
        int needed = snprintf(cmdline + offset, sizeof(cmdline) - offset,
                              " --no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing");
        if (needed < 0 || (size_t)(offset + needed) >= sizeof(cmdline)) return 1;
    }

    // Launch the real webhelper
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;

    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        return 1;
    }

    // Wait for it to exit and return its exit code
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exitCode;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return exitCode;
}

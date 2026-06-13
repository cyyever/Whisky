/*
 * webhelper_wrapper.c
 *
 * This file is part of Whisky.
 *
 * A drop-in replacement for Steam's steamwebhelper.exe (CEF host). It forwards
 * all original arguments to the genuine binary (renamed steamwebhelper_real.exe
 * in the same directory) and appends the flags required for Steam's CEF to
 * render under Wine on macOS:
 *
 *     --no-sandbox          CEF's sandbox hooks into the NT kernel and breaks under Wine
 *     --in-process-gpu      avoids the out-of-process GPU sandbox "cannot reset D3D device" failure
 *     --disable-gpu         force the software render path
 *     --disable-gpu-compositing
 *
 * Without these flags steamwebhelper renders a black window. Built as a GUI
 * subsystem app (-mwindows) so no console window appears; the child is spawned
 * with CREATE_NO_WINDOW for the same reason.
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
    char exepath[MAX_PATH];
    char *lastslash;
    int offset;

    // Get directory of this exe
    GetModuleFileNameA(NULL, exepath, MAX_PATH);
    lastslash = strrchr(exepath, '\\');
    if (lastslash) *(lastslash + 1) = '\0';

    // Build command: real exe + original args + our extra flags
    offset = snprintf(cmdline, sizeof(cmdline), "\"%ssteamwebhelper_real.exe\"", exepath);
    if (offset < 0 || (size_t)offset >= sizeof(cmdline)) return 1;

    // Check if flags are already present (child process re-invocation)
    int already_patched = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--in-process-gpu") == 0) {
            already_patched = 1;
            break;
        }
    }

    // Append all original arguments with bounds checking
    for (int i = 1; i < argc; i++) {
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

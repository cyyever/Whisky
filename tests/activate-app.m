/*
 * activate-app — make another process's application frontmost, by unix pid.
 *
 *   activate-app <pid> [--wait-seconds N]
 *
 * WHY. Testing whether Wine restores its foreground window on activation needs
 * the app to be activated the way cmd-tab does it, and nothing in the shell can
 * do that: `osascript ... System Events ... set frontmost` needs Accessibility,
 * and macOS will not let a process launched from a terminal take the front by
 * itself. Asking a human to click is worse than useless here — a click carries
 * its own focus event, which is exactly the path that already works, so a test
 * that comes back by clicking cannot tell a fixed driver from a broken one.
 *
 * -[NSRunningApplication activateWithOptions:] needs no permission and is what
 * an app switcher does, so it is the honest stand-in for cmd-tab.
 *
 * Exit: 0 activated, 1 no application for that pid (a process with no window,
 * or not registered with LaunchServices), 2 bad usage.
 */
#import <AppKit/AppKit.h>

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: activate-app <pid>\n");
            return 2;
        }

        pid_t pid = (pid_t)atoi(argv[1]);
        NSRunningApplication *app =
            [NSRunningApplication runningApplicationWithProcessIdentifier:pid];

        if (!app) {
            fprintf(stderr, "no application for pid %d\n", (int)pid);
            return 1;
        }

        BOOL ok = [app activateWithOptions:NSApplicationActivateAllWindows];
        printf("activate pid %d (%s): %s\n", (int)pid,
               [(app.localizedName ?: @"?") UTF8String], ok ? "ok" : "refused");

        /* activateWithOptions returns before the switch has happened. */
        for (int i = 0; i < 40 && !app.active; i++)
            usleep(50 * 1000);

        printf("frontmost now: %s\n", app.active ? "yes" : "no");
        return ok ? 0 : 1;
    }
}

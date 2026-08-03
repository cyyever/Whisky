/* window-visibility-native.m — the native half of the window-visibility repro.
 *
 * Wine creates an NSWindow for a top-level Win32 window, sets a correct frame,
 * calls -orderFront:, and Cocoa reports isVisible=1 — yet the window never
 * appears and WindowServer has no record of it. This tool supplies the two
 * things the Win32 side cannot:
 *
 *   control  — put up an ordinary NSWindow from a plain (non-Wine) x86_64
 *              process, to establish that this machine/session *can* show
 *              windows at all. Without it, "Wine's window is missing" is
 *              unattributable.
 *   query    — ask WindowServer (CGWindowList) which windows it actually knows
 *              about, filtered to a size. This is the objective check: Cocoa's
 *              own isVisible is a per-process belief, CGWindowList is the truth.
 *
 * Usage:
 *   window-visibility-native control <seconds>        put up a 640x480 window
 *   window-visibility-native query <w> <h>            report windows of that size
 *
 * `query` exits 0 if it found at least one such window, 1 if none — so the
 * driver script can branch on it.
 *
 * Build (must be x86_64 to match the Wine side's architecture):
 *   clang -arch x86_64 -fobjc-arc -framework Cocoa \
 *     -o window-visibility-native window-visibility-native.m
 */
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Report every window WindowServer knows of whose size matches, whoever owns
 * it. Matching on size rather than owner/title keeps this honest: Wine's
 * windows come through with an empty title, so a title filter would silently
 * match nothing and look like a failure of the thing we're testing. */
static int query_windowserver(double want_w, double want_h)
{
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    int matches = 0;

    for (NSDictionary *win in (__bridge NSArray *)list)
    {
        NSDictionary *bounds = win[(id)kCGWindowBounds];
        double w = [bounds[@"Width"] doubleValue];
        double h = [bounds[@"Height"] doubleValue];
        NSString *owner = win[(id)kCGWindowOwnerName] ?: @"";
        NSString *name = win[(id)kCGWindowName] ?: @"";

        if (w != want_w || h != want_h) continue;

        printf("  owner='%s' title='%s' at (%.0f,%.0f) onscreen=%d alpha=%.2f layer=%d\n",
               owner.UTF8String, name.UTF8String,
               [bounds[@"X"] doubleValue], [bounds[@"Y"] doubleValue],
               [win[(id)kCGWindowIsOnscreen] intValue],
               [win[(id)kCGWindowAlpha] doubleValue],
               [win[(id)kCGWindowLayer] intValue]);
        matches++;
    }
    CFRelease(list);

    if (!matches) printf("  (no %.0fx%.0f window known to WindowServer)\n", want_w, want_h);
    return matches ? 0 : 1;
}

/* The control: a 640x480 window from a plain process, same size as case [A] of
 * the Wine-side test so both are queried identically. */
static int show_control_window(double seconds)
{
    [NSApplication sharedApplication];
    /* A process with no bundle starts out Prohibited, which bars it from
     * showing UI — the same transition winemac makes via
     * transformProcessToForeground. */
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(100, 100, 640, 480)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [win setTitle:@"native control window"];
    [win setBackgroundColor:[NSColor systemBlueColor]];
    [win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    /* CGWindowList reports the *frame* size (content + title bar), so print
     * that — it is what `query` must be given, not the content size. */
    printf("control: isVisible=%d frame=(%.0f,%.0f %.0fx%.0f) holding %.0fs\n",
           [win isVisible], [win frame].origin.x, [win frame].origin.y,
           [win frame].size.width, [win frame].size.height, seconds);
    printf("QUERYSIZE %.0f %.0f\n", [win frame].size.width, [win frame].size.height);
    fflush(stdout);

    [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:seconds];
    [NSApp run];
    return 0;
}

int main(int argc, const char **argv)
{
    @autoreleasepool
    {
        if (argc >= 2 && !strcmp(argv[1], "control"))
            return show_control_window(argc >= 3 ? atof(argv[2]) : 20.0);

        if (argc >= 4 && !strcmp(argv[1], "query"))
            return query_windowserver(atof(argv[2]), atof(argv[3]));

        fprintf(stderr, "usage: %s control <seconds> | query <width> <height>\n", argv[0]);
        return 2;
    }
}

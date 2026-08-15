/*
 * cocoa-onmainthread-repro — winemac's OnMainThread structure, without Wine.
 *
 *   clang -arch x86_64 -fobjc-arc -framework Cocoa -o repro cocoa-onmainthread-repro.m
 *   arch -x86_64 ./repro [iterations]
 *
 * WHY. A 32-bit DirectShow RenderFile hangs in Wine
 * (tests/gstreamer/dshow-render-test.sh) with the Cocoa main thread wedged:
 * it runs [NSApp run], reaches kCFRunLoopAfterWaiting and never enters another
 * run-loop phase, while a worker thread waits forever for a block it queued.
 * Instrumentation ruled out every winemac-side suspect -- no NSEvent was ever
 * dispatched, no query was ever sent, PerformRequest was entered twice and
 * returned both times, and winemac's only other main-thread sources are a
 * one-shot starter and a disabled event tap.
 *
 * So the remaining question is whether the mechanism itself deadlocks on this
 * OS, independently of Wine. This program is that mechanism and nothing else:
 *
 *   main thread    [NSApp run]
 *   worker thread  append a block to `requests` under a serial queue, signal a
 *                  custom CFRunLoopSource on the main run loop, wait on a
 *                  semaphore -- exactly OnMainThreadAsync + OnMainThread
 *   the block      create and release an NSWindow, which is what
 *                  create_cocoa_window() ends up doing
 *
 * Built for x86_64 on purpose: the Wine failure is 32-bit-only, and 32-bit
 * WoW64 means extra thunks and different timing, so Rosetta is part of the
 * environment under test.
 *
 * Exit 0 if every iteration completes, 1 on the first one that does not.
 */
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>

static NSMutableArray       *requests;
static dispatch_queue_t      requestsManipQueue;
static CFRunLoopSourceRef    requestSource;
static volatile int          iterations = 200;
static volatile int          completed;

/* winemac's PerformRequest: drain the queue on the main thread. */
static void PerformRequest(void *info)
{
    @autoreleasepool
    {
        for (;;)
        {
            /* = nil, not just declared: an uninitialised __block object
             * variable is indeterminate, and ARC releases it at scope exit --
             * a crash in objc_release that looks like an OS problem. */
            __block dispatch_block_t block = nil;

            dispatch_sync(requestsManipQueue, ^{
                if ([requests count])
                {
                    block = requests[0];
                    [requests removeObjectAtIndex:0];
                }
                else
                    block = nil;
            });

            if (!block) break;
            block();
        }
    }
}

/* winemac's OnMainThreadAsync. */
static void OnMainThreadAsync(dispatch_block_t block)
{
    dispatch_block_t copy = [block copy];

    dispatch_sync(requestsManipQueue, ^{ [requests addObject:copy]; });
    CFRunLoopSourceSignal(requestSource);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

/* winemac's OnMainThread, in its no-event-queue form (semaphore wait). */
static void OnMainThread(dispatch_block_t block)
{
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    OnMainThreadAsync(^{
        block();
        dispatch_semaphore_signal(sem);
    });

    /* A deadline rather than FOREVER: the failure under investigation is a
     * hang, and a test that hangs cannot report which iteration hung. */
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15ll * NSEC_PER_SEC)))
    {
        fprintf(stderr, "FAIL  main thread never ran the block (iteration %d)\n", completed + 1);
        exit(1);
    }
}

static void *worker(void *arg)
{
    /* Let [NSApp run] settle first, as winemac's macdrv_init does. */
    usleep(300 * 1000);

    for (completed = 0; completed < iterations; completed++)
    {
        OnMainThread(^{
            @autoreleasepool
            {
                NSWindow *w = [[NSWindow alloc]
                    initWithContentRect:NSMakeRect(100, 100, 320, 200)
                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                         NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                backing:NSBackingStoreBuffered
                                  defer:NO];
                /* releasedWhenClosed defaults to YES for a programmatically
                 * created NSWindow, so -close releases it and ARC releases it
                 * again -- an over-release that crashes in objc_release and
                 * reads like an OS fault rather than a test bug. */
                w.releasedWhenClosed = NO;
                [w close];
            }
        });
        if (((completed + 1) % 25) == 0)
            fprintf(stderr, "      %d/%d\n", completed + 1, iterations);
    }

    printf("pass  %d window creations via OnMainThread\n", iterations);
    exit(0);
}

int main(int argc, char **argv)
{
    CFRunLoopSourceContext ctx = { 0 };
    pthread_t t;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1) iterations = atoi(argv[1]);
    /* A non-numeric or <= 0 argument would loop zero times and print
     * "pass 0 window creations" -- success having tested nothing. */
    if (iterations <= 0)
    {
        fprintf(stderr, "usage: %s [iterations > 0]\n", argv[0]);
        return 2;
    }

    @autoreleasepool
    {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        requests = [[NSMutableArray alloc] init];
        requestsManipQueue = dispatch_queue_create("whisky.requests", NULL);

        ctx.perform = PerformRequest;
        requestSource = CFRunLoopSourceCreate(NULL, 0, &ctx);
        CFRunLoopAddSource(CFRunLoopGetMain(), requestSource, kCFRunLoopCommonModes);

        pthread_create(&t, NULL, worker, NULL);

        /* Never returns; the worker exit()s. */
        [NSApp run];
    }
    return 0;
}

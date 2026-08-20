/* vk-present-probe — the real presentation path, no Wine, no game, no DXVK.
 *
 *   clang -arch x86_64 -fobjc-arc -Wno-deprecated-declarations \
 *         -framework Cocoa -framework QuartzCore -framework ImageIO \
 *         -I<vulkan-headers> -o vk-present-probe vk-present-probe.m \
 *         -L<vulkan-loader> -lvulkan -Wl,-rpath,<vulkan-loader>
 *   VK_DRIVER_FILES=<kk-icd> arch -x86_64 ./vk-present-probe [seconds]
 *
 * Every offscreen probe of KosmicKrisp's draw path passes (21 configs: strips,
 * fans both windings, index/vertex fetch, frames in flight, per-frame CPU
 * vertex writes). The in-game artifact -- a stable diagonal splitting every
 * fullscreen surface, exactly one triangle of a quad's two -- therefore lives
 * in what offscreen rendering cannot reach: the swapchain. And that path has
 * a quad of its own: every present runs kk_CmdBlitImage2 -> vk_meta_blit,
 * a 6-vertex triangle-list blit into the CAMetalDrawable's texture.
 *
 * So: a real NSWindow with a CAMetalLayer, a real VK_EXT_metal_surface
 * swapchain, and a render loop that only CLEARS each frame to an alternating
 * solid colour (even = red, odd = blue) and presents. No app-side geometry at
 * all. If the window ever shows a diagonal split between the two colours,
 * the WSI blit quad lost a triangle -- the game artifact, reproduced in
 * ~200 lines of Vulkan. The probe self-checks: about once a second it
 * captures the window and samples the upper-left and lower-right pixels;
 * the two disagreeing is the split, reported as FAIL and exit code 1.
 */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

#define W 512
#define H 512
#define VK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
    fprintf(stderr, "FAIL  %s = %d\n", #x, r_); exit(1); } } while (0)

#include <time.h>

static CAMetalLayer *layer;
static volatile int seconds = 20;
/* -occlusion: does vkWaitForPresentKHR still return once the window is no
 * longer on screen? SSFIV freezes on a window switch, blocked in exactly that
 * call (thunk32_vkWaitForPresentKHR -> KK's wsi_metal_swapchain_wait_for_present
 * -> a condition-variable wait). Metal stops handing out drawables for an
 * off-screen layer, so a present that never completes strands any waiter that
 * passed UINT64_MAX -- which is what dxvk_presenter.cpp does. */

/* -dropped: make the driver skip registering the presented handler, so no
 * present ever completes on its own. That is the state a switched-away window
 * leaves the swapchain in, and it cannot be produced from the Vulkan side --
 * occluded, hidden, miniaturized and even unattached layers were all measured
 * and all still get their handlers called (4-9 ms), so a test built on those
 * passes without touching the path it claims to cover.
 *
 * Metal has no "discarded" callback -- unlike Wayland's presentation-time
 * protocol, whose discarded event Mesa's Wayland WSI keys off -- so nothing
 * completes these presents but the WSI itself. A caller passing UINT64_MAX
 * (DXVK does) waits forever unless the WSI synthesizes the completion Metal
 * owes it. This mode asserts it does; before the fix it hangs on wait one. */
static volatile enum {
    MODE_SPLIT,      /* the original probe: watch for a torn present blit */
    MODE_OCCLUSION,  /* cmd-tab away with the presented handler intact */
    MODE_DROPPED,    /* presented handler never registered (the recovery path) */
} mode = MODE_SPLIT;
#define present_wait_mode (mode != MODE_SPLIT)
/* Outstanding wait, for the watchdog. The probe has to pass UINT64_MAX to
 * reach the recovery at all -- the driver deliberately leaves finite waits
 * alone, since a caller that named a deadline is entitled to VK_TIMEOUT -- so
 * a broken driver hangs the probe. The watchdog is what turns that back into
 * a verdict instead of a test that prints nothing. */
static volatile uint64_t wait_started_ms;   /* 0 = no wait in flight */

static uint64_t now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void *wait_watchdog(void *arg)
{
    (void)arg;
    for (;;) {
        usleep(250 * 1000);
        uint64_t started = wait_started_ms;
        if (!started)
            continue;
        uint64_t held = now_ms() - started;
        if (held > 5000) {
            fprintf(stderr,
                    "FAIL  vkWaitForPresentKHR has been blocked %.1f s on a present\n"
                    "      that will never be displayed -- the WSI is not synthesizing\n"
                    "      the completion Metal does not send (patches/mesa/0003)\n",
                    held / 1000.0);
            _exit(1);   /* the render thread is inside the wait; nothing else can */
        }
    }
    return NULL;
}
static volatile int occluded = 0;

/* Wall-clock, not frame count: the stall being measured slows the frame
 * counter, so a frame-based restore ends the occlusion before the wait can
 * grow. */
static int occl_secs = 8;
static time_t occl_start = 0;
static double worst_active_ms = 0, worst_occluded_ms = 0;
/* Generous: a FIFO present at 60 Hz completes in ~16 ms, so 2 s of no
 * completion is a hang, not slow compositing. */
#define WAIT_BUDGET_NS (2ull * 1000 * 1000 * 1000)
static int stuck = 0;

/* Sample the probe window's two diagonal corners and report whether they
 * hold DIFFERENT solid colours. Every frame clears the whole window to one
 * colour, so upper-left and lower-right disagreeing means a diagonal split
 * -- the WSI blit lost a triangle. Channel-agnostic (RGBA vs BGRA): a frame
 * is red or blue whichever order the capture uses.
 *
 * Capture goes through /usr/sbin/screencapture -x -l<windowid>: the manual
 * verification path, and CGWindowListCreateImage is obsoleted on macOS 15. */
static int window_split(void)
{
    int winid = 0;
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (list) {
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            NSDictionary *w = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
            if (![w[(id)kCGWindowName] isEqualToString:@"vk-present-probe"]) continue;
            winid = [w[(id)kCGWindowNumber] unsignedIntValue];
            break;
        }
        CFRelease(list);
    }
    if (!winid) return 0;

    const char *path = "/tmp/vk-present-probe-cap.png";
    char cmd[128];
    snprintf(cmd, sizeof(cmd), "/usr/sbin/screencapture -x -l%d %s", winid, path);
    if (system(cmd) != 0) return 0;

    int split = 0;
    NSURL *url = [NSURL fileURLWithPath:@(path)];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (src) {
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        if (img) {
            size_t wpx = CGImageGetWidth(img), hpx = CGImageGetHeight(img);
            int bpp = CGImageGetBitsPerPixel(img) / 8;
            CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(img));
            const uint8_t *px = data ? CFDataGetBytePtr(data) : NULL;
            if (px && wpx >= 8 && hpx >= 8 && bpp >= 3) {
                const uint8_t *ul = px + (hpx / 4 * wpx + wpx / 4) * bpp;
                const uint8_t *lr = px + (3 * hpx / 4 * wpx + 3 * wpx / 4) * bpp;
                int c_ul = (ul[0] > 200 && ul[2] < 50) ? 1 : (ul[2] > 200 && ul[0] < 50) ? 2 : 0;
                int c_lr = (lr[0] > 200 && lr[2] < 50) ? 1 : (lr[2] > 200 && lr[0] < 50) ? 2 : 0;
                split = c_ul && c_lr && c_ul != c_lr;
            }
            if (data) CFRelease(data);
            CGImageRelease(img);
        }
        CFRelease(src);
    }
    remove(path);
    return split;
}

static void *render_thread(void *arg)
{
    VkInstance inst;
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.apiVersion = VK_API_VERSION_1_3;
    const char *iexts[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = 2; ici.ppEnabledExtensionNames = iexts;
    VK(vkCreateInstance(&ici, NULL, &inst));

    VkSurfaceKHR surf;
    VkMetalSurfaceCreateInfoEXT sci = { VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT };
    sci.pLayer = layer;
    PFN_vkCreateMetalSurfaceEXT createSurf =
        (PFN_vkCreateMetalSurfaceEXT)vkGetInstanceProcAddr(inst, "vkCreateMetalSurfaceEXT");
    VK(createSurf(inst, &sci, NULL, &surf));

    uint32_t n = 0;
    VK(vkEnumeratePhysicalDevices(inst, &n, NULL));
    VkPhysicalDevice *devs = calloc(n, sizeof(*devs));
    VK(vkEnumeratePhysicalDevices(inst, &n, devs));
    VkPhysicalDevice phys = devs[0];
    VkPhysicalDeviceProperties pp; vkGetPhysicalDeviceProperties(phys, &pp);
    printf("device: %s\n", pp.deviceName);

    uint32_t qn = 0; vkGetPhysicalDeviceQueueFamilyProperties(phys, &qn, NULL);
    VkQueueFamilyProperties *qf = calloc(qn, sizeof(*qf));
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qn, qf);
    uint32_t qfam = UINT32_MAX;
    for (uint32_t i = 0; i < qn; i++) {
        VkBool32 sup = VK_FALSE;
        vkGetPhysicalDeviceSurfaceSupportKHR(phys, i, surf, &sup);
        if ((qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && sup) { qfam = i; break; }
    }
    if (qfam == UINT32_MAX) { fprintf(stderr, "FAIL  no present queue\n"); exit(1); }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = qfam; qci.queueCount = 1; qci.pQueuePriorities = &prio;
    const char *dexts[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME,
                            VK_KHR_PRESENT_ID_EXTENSION_NAME,
                            VK_KHR_PRESENT_WAIT_EXTENSION_NAME };
    VkPhysicalDevicePresentIdFeaturesKHR pidf = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR };
    pidf.presentId = VK_TRUE;
    VkPhysicalDevicePresentWaitFeaturesKHR pwf = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR };
    pwf.presentWait = VK_TRUE; pwf.pNext = &pidf;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci;
    /* present_wait only in the occlusion run: it is the subject there, and the
     * split probe should not depend on an extension it does not exercise. */
    dci.enabledExtensionCount = present_wait_mode ? 3 : 1;
    dci.ppEnabledExtensionNames = dexts;
    if (present_wait_mode) dci.pNext = &pwf;
    VkDevice dev; VK(vkCreateDevice(phys, &dci, NULL, &dev));
    VkQueue queue; vkGetDeviceQueue(dev, qfam, 0, &queue);

    VkSurfaceCapabilitiesKHR caps;
    VK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(phys, surf, &caps));
    uint32_t fmtn = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(phys, surf, &fmtn, NULL);
    VkSurfaceFormatKHR *fmts = calloc(fmtn, sizeof(*fmts));
    VK(vkGetPhysicalDeviceSurfaceFormatsKHR(phys, surf, &fmtn, fmts));
    VkSurfaceFormatKHR fmt = fmts[0];

    VkSwapchainCreateInfoKHR sc = { VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR };
    sc.surface = surf;
    sc.minImageCount = caps.minImageCount > 3 ? caps.minImageCount : 3;
    sc.imageFormat = fmt.format; sc.imageColorSpace = fmt.colorSpace;
    sc.imageExtent = (VkExtent2D){ W, H };
    sc.imageArrayLayers = 1;
    sc.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    sc.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    sc.preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    sc.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    sc.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    sc.clipped = VK_TRUE;
    VkSwapchainKHR swap; VK(vkCreateSwapchainKHR(dev, &sc, NULL, &swap));

    uint32_t imgn = 0;
    VK(vkGetSwapchainImagesKHR(dev, swap, &imgn, NULL));
    VkImage *imgs = calloc(imgn, sizeof(*imgs));
    VK(vkGetSwapchainImagesKHR(dev, swap, &imgn, imgs));
    printf("swapchain: %u images, fmt %d\n", imgn, fmt.format);

    VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = qfam;
    VkCommandPool pool; VK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cbai.commandPool = pool; cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cbai.commandBufferCount = 1;
    VkCommandBuffer cmd; VK(vkAllocateCommandBuffers(dev, &cbai, &cmd));

    VkSemaphoreCreateInfo semci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VkSemaphore acq, rel;
    VK(vkCreateSemaphore(dev, &semci, NULL, &acq));
    VK(vkCreateSemaphore(dev, &semci, NULL, &rel));
    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence; VK(vkCreateFence(dev, &fci, NULL, &fence));

    int frames = 0, checks = 0, splits = 0, noted = 0;
    time_t start = time(NULL);
    while (time(NULL) - start < seconds) {
        uint32_t idx;
        VkResult ar = vkAcquireNextImageKHR(dev, swap, 500ull * 1000 * 1000, acq, VK_NULL_HANDLE, &idx);
        if (ar == VK_NOT_READY || ar == VK_TIMEOUT) {
            if (ar == VK_NOT_READY && !noted) {
                noted = 1;
                fprintf(stderr, "NOTE  acquire returned VK_NOT_READY with a "
                        "non-zero timeout; the spec requires VK_TIMEOUT here\n");
            }
            continue;
        }
        if (ar != VK_SUCCESS && ar != VK_SUBOPTIMAL_KHR) { fprintf(stderr, "acquire=%d\n", ar); break; }

        VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        VK(vkBeginCommandBuffer(cmd, &bi));
        VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
        b.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        b.image = imgs[idx];
        b.subresourceRange = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        b.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, NULL, 0, NULL, 1, &b);
        /* Even frames red, odd frames blue. The window must always be ONE
         * solid colour; a stable diagonal means the present blit split. */
        VkClearColorValue col = { .float32 = { (frames & 1) ? 0.f : 1.f, 0.f,
                                               (frames & 1) ? 1.f : 0.f, 1.f } };
        vkCmdClearColorImage(cmd, imgs[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &col, 1, &b.subresourceRange);
        VkImageMemoryBarrier p = b;
        p.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        p.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        p.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                             0, 0, NULL, 0, NULL, 1, &p);
        VK(vkEndCommandBuffer(cmd));

        VkPipelineStageFlags wait = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
        si.waitSemaphoreCount = 1; si.pWaitSemaphores = &acq; si.pWaitDstStageMask = &wait;
        si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
        si.signalSemaphoreCount = 1; si.pSignalSemaphores = &rel;
        VK(vkQueueSubmit(queue, 1, &si, fence));

        uint64_t pid = (uint64_t)frames + 1;
        VkPresentIdKHR pidinfo = { VK_STRUCTURE_TYPE_PRESENT_ID_KHR };
        pidinfo.swapchainCount = 1; pidinfo.pPresentIds = &pid;
        VkPresentInfoKHR pi = { VK_STRUCTURE_TYPE_PRESENT_INFO_KHR };
        pi.waitSemaphoreCount = 1; pi.pWaitSemaphores = &rel;
        pi.swapchainCount = 1; pi.pSwapchains = &swap; pi.pImageIndices = &idx;
        if (present_wait_mode) pi.pNext = &pidinfo;
        VkResult pr = vkQueuePresentKHR(queue, &pi);
        if (pr != VK_SUCCESS && pr != VK_SUBOPTIMAL_KHR)
            fprintf(stderr, "present=%d\n", pr);

        if (present_wait_mode && (pr == VK_SUCCESS || pr == VK_SUBOPTIMAL_KHR)) {
            /* Only wait on a present that was actually queued. A rejected
             * present (VK_ERROR_OUT_OF_DATE_KHR is normal when the window
             * leaves the screen) has no id to wait for, and waiting anyway
             * would time out every frame and report a stall that never
             * happened.
             *
             * The game passes UINT64_MAX here and never comes back. A finite
             * timeout turns that hang into a measurement: how long the wait
             * actually took, and whether it ever returned at all. */
            static PFN_vkWaitForPresentKHR waitPresent;
            if (!waitPresent) {
                waitPresent = (PFN_vkWaitForPresentKHR)
                    vkGetDeviceProcAddr(dev, "vkWaitForPresentKHR");
                if (!waitPresent) {
                    /* Silently making no wait calls and then reporting "no
                     * stall" would be a pass from a run that never invoked the
                     * function under test. */
                    fprintf(stderr, "FAIL  no vkWaitForPresentKHR entry point\n");
                    exit(1);
                }
            }
            {
                struct timespec t0, t1;
                clock_gettime(CLOCK_MONOTONIC, &t0);
                wait_started_ms = now_ms();
                VkResult wr = waitPresent(dev, swap, pid,
                                          mode == MODE_DROPPED ? UINT64_MAX
                                                        : WAIT_BUDGET_NS);
                wait_started_ms = 0;
                clock_gettime(CLOCK_MONOTONIC, &t1);
                double ms = (t1.tv_sec - t0.tv_sec) * 1e3 +
                            (t1.tv_nsec - t0.tv_nsec) / 1e6;
                if (occluded) { if (ms > worst_occluded_ms) worst_occluded_ms = ms; }
                else          { if (ms > worst_active_ms)   worst_active_ms   = ms; }
                if (wr == VK_TIMEOUT) {
                    if (!stuck)
                        fprintf(stderr, "FAIL  vkWaitForPresentKHR timed out after "
                                "%.0f ms at frame %d (%s)\n", ms, frames,
                                occluded ? "window OFF screen" : "window on screen");
                    stuck++;
                } else if (wr != VK_SUCCESS) {
                    fprintf(stderr, "note: vkWaitForPresentKHR = %d\n", wr);
                }
            }
        }

        VK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
        VK(vkResetFences(dev, 1, &fence));
        VK(vkResetCommandBuffer(cmd, 0));
        frames++;

        /* Take the window off screen a second in, then bring it back. A
         * miniaturize is what a user switching away actually does, and it is
         * the state in which Metal stops vending drawables. */
        if (mode == MODE_OCCLUSION && frames == 60 && !occl_start) {
            occl_start = time(NULL);
            fprintf(stderr, "-- switching to another app --\n");
            occluded = 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                /* What cmd-tab does: another app becomes active and its
                 * windows come forward. The window is neither hidden nor
                 * miniaturized -- it is deactivated and, once covered, marked
                 * non-visible by the window server. Miniaturize, orderOut and
                 * -[NSApp hide:] were all tried and all behaved identically to
                 * staying on screen, so only the faithful one is kept. */
                for (NSRunningApplication *a in
                     [[NSWorkspace sharedWorkspace] runningApplications]) {
                    if ([a.bundleIdentifier isEqualToString:@"com.apple.finder"]) {
                        [a activateWithOptions:NSApplicationActivateAllWindows];
                        break;
                    }
                }
            });
        }
        if (occluded && time(NULL) - occl_start >= occl_secs) {
            fprintf(stderr, "-- restoring the window --\n");
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp activateIgnoringOtherApps:YES];
            });
            occluded = 0;
        }

        /* Self-check ~once a second: screencapture spawns a process, so doing
         * it every frame would dominate the loop. The verdict (whole window
         * one solid colour, at any instant) is pacing-independent. */
        if ((frames & 63) == 0) {
            checks++;
            if (window_split()) {
                if (!splits)
                    fprintf(stderr, "FAIL  diagonal split in the presented "
                            "window at frame %d\n", frames);
                splits++;
            }
        }
    }
    if (mode == MODE_OCCLUSION && !occl_start) {
        printf("FAIL  the run ended before frame 60, so the window was never "
               "taken off screen --\n      nothing was measured (give it more seconds)\n");
        vkQueueWaitIdle(queue);
        exit(1);
    }
    if (mode == MODE_DROPPED) {
        printf("presented %d frames with no presented handler registered; "
               "worst vkWaitForPresentKHR %.0f ms, %d timeouts\n",
               frames, worst_active_ms, stuck);
        if (stuck || frames < 3) {
            printf("FAIL  presents with no presented handler never complete --\n"
                   "      the WSI is not synthesizing the completion Metal will not send\n");
            vkQueueWaitIdle(queue);
            exit(1);
        }
        /* Completion alone is not the claim: a real presented handler finishes
         * a wait in 4-16 ms, so fast waits here mean the drop hook did not take
         * and the run proved nothing. Only a wait that sat out the grace period
         * can have been ended by the synthesized signal. */
        if (worst_active_ms < 300) {
            printf("FAIL  every wait returned in %.0f ms, far too fast to be the\n"
                   "      synthesized completion -- the presented handler was still\n"
                   "      registered, so this run did not exercise the recovery path\n",
                   worst_active_ms);
            vkQueueWaitIdle(queue);
            exit(1);
        }
        printf("pass  undisplayed presents still complete, and did so via the\n"
               "      synthesized signal (%.0f ms, the grace period)\n", worst_active_ms);
        vkQueueWaitIdle(queue);
        exit(0);
    }
    if (mode == MODE_OCCLUSION) {
        printf("presented %d frames; worst vkWaitForPresentKHR: %.0f ms active, "
               "%.0f ms while switched away; %d timeouts\n",
               frames, worst_active_ms, worst_occluded_ms, stuck);
        if (stuck)
            printf("FAIL  present-wait stalls while the window is off screen --\n"
                   "      a caller passing UINT64_MAX (dxvk_presenter) hangs here\n");
        else
            printf("pass  present-wait always returned within %llu ms\n",
                   WAIT_BUDGET_NS / 1000000ull);
        vkQueueWaitIdle(queue);
        exit(stuck ? 1 : 0);
    }
    printf("presented %d frames, %d window self-checks, %d splits\n",
           frames, checks, splits);
    vkQueueWaitIdle(queue);
    exit(splits ? 1 : 0);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-occlusion")) mode = MODE_OCCLUSION;
        else if (!strcmp(argv[i], "-dropped")) {
            mode = MODE_DROPPED;
            setenv("MESA_VK_WSI_METAL_DROP_PRESENT_HANDLER", "1", 1);
        }
        else if (!strncmp(argv[i], "-away=", 6)) occl_secs = atoi(argv[i] + 6);
        else if (argv[i][0] == '-') {
            /* Otherwise a typo becomes the duration: -droppd would set
             * seconds=0 and the run would exit 0 having tested nothing. */
            fprintf(stderr, "FAIL  unknown option %s\n", argv[i]);
            return 1;
        }
        else seconds = atoi(argv[i]);
    }

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(200, 200, W / 2, H / 2)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        win.title = @"vk-present-probe";
        win.releasedWhenClosed = NO;
        layer = [CAMetalLayer layer];
        layer.drawableSize = CGSizeMake(W, H);
        win.contentView.wantsLayer = YES;
        win.contentView.layer = layer;
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        pthread_t t, wd;
        if (mode == MODE_DROPPED)
            pthread_create(&wd, NULL, wait_watchdog, NULL);
        pthread_create(&t, NULL, render_thread, NULL);
        [NSApp run];
    }
    return 0;
}

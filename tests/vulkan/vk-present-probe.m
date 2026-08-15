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
#include <stdio.h>
#include <stdlib.h>

#define W 512
#define H 512
#define VK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { \
    fprintf(stderr, "FAIL  %s = %d\n", #x, r_); exit(1); } } while (0)

static CAMetalLayer *layer;
static volatile int seconds = 20;

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
    const char *dexts[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = 1; dci.ppEnabledExtensionNames = dexts;
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

        VkPresentInfoKHR pi = { VK_STRUCTURE_TYPE_PRESENT_INFO_KHR };
        pi.waitSemaphoreCount = 1; pi.pWaitSemaphores = &rel;
        pi.swapchainCount = 1; pi.pSwapchains = &swap; pi.pImageIndices = &idx;
        VkResult pr = vkQueuePresentKHR(queue, &pi);
        if (pr != VK_SUCCESS && pr != VK_SUBOPTIMAL_KHR)
            fprintf(stderr, "present=%d\n", pr);

        VK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
        VK(vkResetFences(dev, 1, &fence));
        VK(vkResetCommandBuffer(cmd, 0));
        frames++;

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
    printf("presented %d frames, %d window self-checks, %d splits\n",
           frames, checks, splits);
    vkQueueWaitIdle(queue);
    exit(splits ? 1 : 0);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1) seconds = atoi(argv[1]);

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

        pthread_t t;
        pthread_create(&t, NULL, render_thread, NULL);
        [NSApp run];
    }
    return 0;
}

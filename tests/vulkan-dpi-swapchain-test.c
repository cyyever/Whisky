/*
 * vulkan-dpi-swapchain-test — regression test for Vulkan swapchain presentation
 * on a DPI-unaware window under Retina macOS (RetinaMode="y", LogPixels=192).
 *
 * Covers the Street Fighter IV (SSFIV.exe) / DXVK D3D9 infinite VK_SUBOPTIMAL_KHR
 * loop when d3d9.dpiAware = False:
 *   1. Process stays DPI-unaware (does NOT call SetProcessDPIAware), creating a
 *      640x360 client-area window at 96 DPI.
 *   2. Under RetinaMode="y" + LogPixels=192, winemac.drv creates a 640x360 pt
 *      CAMetalLayer at contentsScale=2.0 (1280x720 physical pixels), while
 *      NtUserGetDpiForWindow(hwnd) == 96 != NtUserGetWinMonitorDpi(MDT_RAW_DPI) == 192,
 *      activating win32u's Vulkan fshack scaling path.
 *   3. Before patch 0034-win32u-vulkan-dpi-surface-extent.patch,
 *      win32u_vkCreateSwapchainKHR() initialized the host swapchain extent from
 *      capabilities.minImageExtent ({1, 1} on KosmicKrisp Metal WSI) instead of
 *      capabilities.currentExtent ({1280, 720}), causing vkQueuePresentKHR() to
 *      return VK_SUBOPTIMAL_KHR (1000001003) on every frame forever.
 *   4. After patch 0034, the host swapchain is created at currentExtent
 *      (1280x720) with VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR cleared, and
 *      vkQueuePresentKHR() returns VK_SUCCESS (0) on every frame.
 *
 * Build (no Vulkan SDK headers or import libs required):
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o vulkan-dpi-swapchain-test.exe \
 *       tests/vulkan-dpi-swapchain-test.c
 *
 * Run against a RetinaMode=y, LogPixels=192 prefix:
 *   wine64 vulkan-dpi-swapchain-test.exe   # exit 0 = pass, 1 = fail
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Minimal Vulkan 1.1 + WSI ABI definitions (no SDK dependency) ---- */

#define VKAPI_PTR __stdcall

typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef int32_t  VkResult;

typedef void    *VkInstance;
typedef void    *VkPhysicalDevice;
typedef void    *VkDevice;
typedef void    *VkQueue;
typedef void    *VkCommandBuffer;

typedef uint64_t VkSurfaceKHR;
typedef uint64_t VkSwapchainKHR;
typedef uint64_t VkImage;
typedef uint64_t VkSemaphore;
typedef uint64_t VkFence;
typedef uint64_t VkCommandPool;

enum {
    VK_SUCCESS                 = 0,
    VK_INCOMPLETE              = 5,
    VK_SUBOPTIMAL_KHR          = 1000001003,
    VK_ERROR_OUT_OF_DATE_KHR   = -1000001004,
};

enum {
    VK_STRUCTURE_TYPE_APPLICATION_INFO               = 0,
    VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO           = 1,
    VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO       = 2,
    VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO             = 3,
    VK_STRUCTURE_TYPE_SUBMIT_INFO                    = 4,
    VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO          = 9,
    VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO       = 39,
    VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO   = 40,
    VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO      = 42,
    VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER           = 45,
    VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR      = 1000001000,
    VK_STRUCTURE_TYPE_PRESENT_INFO_KHR               = 1000001001,
    VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR  = 1000009000,
    VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO  = 1000147000,
};

enum {
    VK_FORMAT_B8G8R8A8_UNORM = 44,
    VK_FORMAT_B8G8R8A8_SRGB  = 50,
};

enum {
    VK_COLOR_SPACE_SRGB_NONLINEAR_KHR = 0,
};

enum {
    VK_IMAGE_LAYOUT_UNDEFINED       = 0,
    VK_IMAGE_LAYOUT_PRESENT_SRC_KHR = 1000001002,
};

enum {
    VK_SHARING_MODE_EXCLUSIVE = 0,
};

enum {
    VK_PRESENT_MODE_FIFO_KHR = 2,
};

enum {
    VK_COMMAND_BUFFER_LEVEL_PRIMARY = 0,
};

#define VK_MAKE_VERSION(maj, min, pat) (((uint32_t)(maj) << 22) | ((uint32_t)(min) << 12) | (uint32_t)(pat))
#define VK_TRUE                                    1U
#define VK_FALSE                                   0U
#define VK_QUEUE_GRAPHICS_BIT                      0x00000001U
#define VK_QUEUE_FAMILY_IGNORED                    (~0U)
#define VK_IMAGE_USAGE_TRANSFER_DST_BIT            0x00000002U
#define VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT        0x00000010U
#define VK_IMAGE_ASPECT_COLOR_BIT                  0x00000001U
#define VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR      0x00000001U
#define VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR          0x00000001U
#define VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR 0x00000004U
#define VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT 0x00000002U
#define VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT     0x00000001U
#define VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT               0x00000001U
#define VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT   0x00000400U
#define VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT            0x00002000U

typedef struct { uint32_t width, height; } VkExtent2D;
typedef struct { uint32_t width, height, depth; } VkExtent3D;

typedef struct {
    int32_t     sType;
    const void *pNext;
    const char *pApplicationName;
    uint32_t    applicationVersion;
    const char *pEngineName;
    uint32_t    engineVersion;
    uint32_t    apiVersion;
} VkApplicationInfo;

typedef struct {
    int32_t                  sType;
    const void              *pNext;
    VkFlags                  flags;
    const VkApplicationInfo *pApplicationInfo;
    uint32_t                 enabledLayerCount;
    const char *const       *ppEnabledLayerNames;
    uint32_t                 enabledExtensionCount;
    const char *const       *ppEnabledExtensionNames;
} VkInstanceCreateInfo;

typedef struct {
    VkFlags    queueFlags;
    uint32_t   queueCount;
    uint32_t   timestampValidBits;
    VkExtent3D minImageTransferGranularity;
} VkQueueFamilyProperties;

typedef struct {
    char     extensionName[256];
    uint32_t specVersion;
} VkExtensionProperties;

typedef struct {
    int32_t      sType;
    const void  *pNext;
    VkFlags      flags;
    uint32_t     queueFamilyIndex;
    uint32_t     queueCount;
    const float *pQueuePriorities;
} VkDeviceQueueCreateInfo;

typedef struct {
    int32_t                        sType;
    const void                    *pNext;
    VkFlags                        flags;
    uint32_t                       queueCreateInfoCount;
    const VkDeviceQueueCreateInfo *pQueueCreateInfos;
    uint32_t                       enabledLayerCount;
    const char *const             *ppEnabledLayerNames;
    uint32_t                       enabledExtensionCount;
    const char *const             *ppEnabledExtensionNames;
    const void                    *pEnabledFeatures;
} VkDeviceCreateInfo;

typedef struct {
    int32_t     sType;
    const void *pNext;
    VkFlags     flags;
    HINSTANCE   hinstance;
    HWND        hwnd;
} VkWin32SurfaceCreateInfoKHR;

typedef struct {
    uint32_t   minImageCount;
    uint32_t   maxImageCount;
    VkExtent2D currentExtent;
    VkExtent2D minImageExtent;
    VkExtent2D maxImageExtent;
    uint32_t   maxImageArrayLayers;
    VkFlags    supportedTransforms;
    int32_t    currentTransform;
    VkFlags    supportedCompositeAlpha;
    VkFlags    supportedUsageFlags;
} VkSurfaceCapabilitiesKHR;

typedef struct {
    int32_t         sType;
    const void     *pNext;
    uint32_t        viewFormatCount;
    const int32_t  *pViewFormats;
} VkImageFormatListCreateInfo;

typedef struct {
    int32_t         sType;
    const void     *pNext;
    VkFlags         flags;
    VkSurfaceKHR    surface;
    uint32_t        minImageCount;
    int32_t         imageFormat;
    int32_t         imageColorSpace;
    VkExtent2D      imageExtent;
    uint32_t        imageArrayLayers;
    VkFlags         imageUsage;
    int32_t         imageSharingMode;
    uint32_t        queueFamilyIndexCount;
    const uint32_t *pQueueFamilyIndices;
    int32_t         preTransform;
    int32_t         compositeAlpha;
    int32_t         presentMode;
    VkBool32        clipped;
    VkSwapchainKHR  oldSwapchain;
} VkSwapchainCreateInfoKHR;

typedef struct {
    int32_t     sType;
    const void *pNext;
    VkFlags     flags;
} VkSemaphoreCreateInfo;

typedef struct {
    int32_t     sType;
    const void *pNext;
    VkFlags     flags;
    uint32_t    queueFamilyIndex;
} VkCommandPoolCreateInfo;

typedef struct {
    int32_t       sType;
    const void   *pNext;
    VkCommandPool commandPool;
    int32_t       level;
    uint32_t      commandBufferCount;
} VkCommandBufferAllocateInfo;

typedef struct {
    int32_t     sType;
    const void *pNext;
    VkFlags     flags;
    const void *pInheritanceInfo;
} VkCommandBufferBeginInfo;

typedef struct {
    VkFlags  aspectMask;
    uint32_t baseMipLevel;
    uint32_t levelCount;
    uint32_t baseArrayLayer;
    uint32_t layerCount;
} VkImageSubresourceRange;

typedef struct {
    int32_t                 sType;
    const void             *pNext;
    VkFlags                 srcAccessMask;
    VkFlags                 dstAccessMask;
    int32_t                 oldLayout;
    int32_t                 newLayout;
    uint32_t                srcQueueFamilyIndex;
    uint32_t                dstQueueFamilyIndex;
    VkImage                 image;
    VkImageSubresourceRange subresourceRange;
} VkImageMemoryBarrier;

typedef struct {
    int32_t                sType;
    const void            *pNext;
    uint32_t               waitSemaphoreCount;
    const VkSemaphore     *pWaitSemaphores;
    const VkFlags         *pWaitDstStageMask;
    uint32_t               commandBufferCount;
    const VkCommandBuffer *pCommandBuffers;
    uint32_t               signalSemaphoreCount;
    const VkSemaphore     *pSignalSemaphores;
} VkSubmitInfo;

typedef struct {
    int32_t               sType;
    const void           *pNext;
    uint32_t              waitSemaphoreCount;
    const VkSemaphore    *pWaitSemaphores;
    uint32_t              swapchainCount;
    const VkSwapchainKHR *pSwapchains;
    const uint32_t       *pImageIndices;
    VkResult             *pResults;
} VkPresentInfoKHR;

typedef void (VKAPI_PTR *PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (VKAPI_PTR *PFN_vkGetInstanceProcAddr)(VkInstance, const char *);
typedef PFN_vkVoidFunction (VKAPI_PTR *PFN_vkGetDeviceProcAddr)(VkDevice, const char *);
typedef VkResult (VKAPI_PTR *PFN_vkCreateInstance)(const VkInstanceCreateInfo *, const void *, VkInstance *);
typedef void     (VKAPI_PTR *PFN_vkDestroyInstance)(VkInstance, const void *);
typedef VkResult (VKAPI_PTR *PFN_vkEnumeratePhysicalDevices)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef void     (VKAPI_PTR *PFN_vkGetPhysicalDeviceQueueFamilyProperties)(VkPhysicalDevice, uint32_t *, VkQueueFamilyProperties *);
typedef VkResult (VKAPI_PTR *PFN_vkEnumerateDeviceExtensionProperties)(VkPhysicalDevice, const char *, uint32_t *, VkExtensionProperties *);
typedef VkResult (VKAPI_PTR *PFN_vkCreateDevice)(VkPhysicalDevice, const VkDeviceCreateInfo *, const void *, VkDevice *);
typedef void     (VKAPI_PTR *PFN_vkDestroyDevice)(VkDevice, const void *);
typedef void     (VKAPI_PTR *PFN_vkGetDeviceQueue)(VkDevice, uint32_t, uint32_t, VkQueue *);
typedef VkResult (VKAPI_PTR *PFN_vkCreateWin32SurfaceKHR)(VkInstance, const VkWin32SurfaceCreateInfoKHR *, const void *, VkSurfaceKHR *);
typedef void     (VKAPI_PTR *PFN_vkDestroySurfaceKHR)(VkInstance, VkSurfaceKHR, const void *);
typedef VkResult (VKAPI_PTR *PFN_vkGetPhysicalDeviceSurfaceSupportKHR)(VkPhysicalDevice, uint32_t, VkSurfaceKHR, VkBool32 *);
typedef VkResult (VKAPI_PTR *PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR)(VkPhysicalDevice, VkSurfaceKHR, VkSurfaceCapabilitiesKHR *);
typedef VkResult (VKAPI_PTR *PFN_vkCreateSwapchainKHR)(VkDevice, const VkSwapchainCreateInfoKHR *, const void *, VkSwapchainKHR *);
typedef void     (VKAPI_PTR *PFN_vkDestroySwapchainKHR)(VkDevice, VkSwapchainKHR, const void *);
typedef VkResult (VKAPI_PTR *PFN_vkGetSwapchainImagesKHR)(VkDevice, VkSwapchainKHR, uint32_t *, VkImage *);
typedef VkResult (VKAPI_PTR *PFN_vkAcquireNextImageKHR)(VkDevice, VkSwapchainKHR, uint64_t, VkSemaphore, VkFence, uint32_t *);
typedef VkResult (VKAPI_PTR *PFN_vkQueuePresentKHR)(VkQueue, const VkPresentInfoKHR *);
typedef VkResult (VKAPI_PTR *PFN_vkCreateSemaphore)(VkDevice, const VkSemaphoreCreateInfo *, const void *, VkSemaphore *);
typedef void     (VKAPI_PTR *PFN_vkDestroySemaphore)(VkDevice, VkSemaphore, const void *);
typedef VkResult (VKAPI_PTR *PFN_vkCreateCommandPool)(VkDevice, const VkCommandPoolCreateInfo *, const void *, VkCommandPool *);
typedef void     (VKAPI_PTR *PFN_vkDestroyCommandPool)(VkDevice, VkCommandPool, const void *);
typedef VkResult (VKAPI_PTR *PFN_vkAllocateCommandBuffers)(VkDevice, const VkCommandBufferAllocateInfo *, VkCommandBuffer *);
typedef VkResult (VKAPI_PTR *PFN_vkBeginCommandBuffer)(VkCommandBuffer, const VkCommandBufferBeginInfo *);
typedef VkResult (VKAPI_PTR *PFN_vkEndCommandBuffer)(VkCommandBuffer);
typedef void     (VKAPI_PTR *PFN_vkCmdPipelineBarrier)(VkCommandBuffer, VkFlags, VkFlags, VkFlags,
                                                       uint32_t, const void *, uint32_t, const void *,
                                                       uint32_t, const VkImageMemoryBarrier *);
typedef VkResult (VKAPI_PTR *PFN_vkQueueSubmit)(VkQueue, uint32_t, const VkSubmitInfo *, VkFence);
typedef VkResult (VKAPI_PTR *PFN_vkQueueWaitIdle)(VkQueue);
typedef VkResult (VKAPI_PTR *PFN_vkDeviceWaitIdle)(VkDevice);

/* ---- Helpers ---- */

static const char *vk_result_str(VkResult r)
{
    switch (r) {
    case VK_SUCCESS:               return "VK_SUCCESS";
    case VK_INCOMPLETE:            return "VK_INCOMPLETE";
    case VK_SUBOPTIMAL_KHR:        return "VK_SUBOPTIMAL_KHR";
    case VK_ERROR_OUT_OF_DATE_KHR: return "VK_ERROR_OUT_OF_DATE_KHR";
    default:                       return "VK_OTHER";
    }
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void pump_messages(int rounds)
{
    MSG msg;
    for (int i = 0; i < rounds; i++) {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    }
}

static DWORD read_reg_dword(const char *subkey, const char *value, DWORD defval)
{
    HKEY key;
    DWORD data = defval, size = sizeof(data), type = 0;
    if (RegOpenKeyExA(HKEY_CURRENT_USER, subkey, 0, KEY_READ, &key) == ERROR_SUCCESS) {
        if (RegQueryValueExA(key, value, NULL, &type, (BYTE *)&data, &size) != ERROR_SUCCESS ||
            type != REG_DWORD)
            data = defval;
        RegCloseKey(key);
    }
    return data;
}

static void read_reg_string(const char *subkey, const char *value, char *out, DWORD out_sz, const char *defval)
{
    HKEY key;
    DWORD type = 0, size = out_sz;
    snprintf(out, out_sz, "%s", defval);
    if (RegOpenKeyExA(HKEY_CURRENT_USER, subkey, 0, KEY_READ, &key) == ERROR_SUCCESS) {
        if (RegQueryValueExA(key, value, NULL, &type, (BYTE *)out, &size) != ERROR_SUCCESS ||
            type != REG_SZ)
            snprintf(out, out_sz, "%s", defval);
        RegCloseKey(key);
    }
}

typedef UINT (WINAPI *PFN_GetDpiForWindow)(HWND);

#define LOAD_IPROC(inst, name) \
    PFN_##name p_##name = (PFN_##name)p_vkGetInstanceProcAddr((inst), #name); \
    if (!p_##name) { fprintf(stderr, "FAIL: missing instance proc %s\n", #name); return 1; }

#define LOAD_DPROC(dev, name) \
    PFN_##name p_##name = (PFN_##name)p_vkGetDeviceProcAddr((dev), #name); \
    if (!p_##name) { fprintf(stderr, "FAIL: missing device proc %s\n", #name); return 1; }

int main(void)
{
    const LONG WANT_W = 640;
    const LONG WANT_H = 360;
    const int NUM_FRAMES = 5;
    int failures = 0;

    /* Deliberately remain DPI-unaware (do NOT call SetProcessDPIAware). */
    DWORD reg_logpixels = read_reg_dword("Control Panel\\Desktop", "LogPixels", 96);
    char retina_mode[32];
    read_reg_string("Software\\Wine\\Mac Driver", "RetinaMode", retina_mode, sizeof(retina_mode), "n");

    HMODULE vk_mod = LoadLibraryA("vulkan-1.dll");
    if (!vk_mod) {
        fprintf(stderr, "FAIL: LoadLibraryA(vulkan-1.dll) failed (err=%lu)\n", GetLastError());
        return 1;
    }

    PFN_vkGetInstanceProcAddr p_vkGetInstanceProcAddr =
        (PFN_vkGetInstanceProcAddr)(void *)GetProcAddress(vk_mod, "vkGetInstanceProcAddr");
    if (!p_vkGetInstanceProcAddr) {
        fprintf(stderr, "FAIL: vkGetInstanceProcAddr not found in vulkan-1.dll\n");
        return 1;
    }

    LOAD_IPROC(NULL, vkCreateInstance);

    /* Create a visible DPI-unaware window with 640x360 client rect. */
    HINSTANCE hinst = GetModuleHandleW(NULL);
    WNDCLASSW wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = hinst;
    wc.lpszClassName = L"WhiskyVkDpiSwapchainTest";
    if (!RegisterClassW(&wc)) {
        fprintf(stderr, "FAIL: RegisterClassW failed (err=%lu)\n", GetLastError());
        return 1;
    }

    RECT rc = { 0, 0, WANT_W, WANT_H };
    DWORD style = WS_OVERLAPPEDWINDOW;
    AdjustWindowRect(&rc, style, FALSE);

    HWND hwnd = CreateWindowExW(
        0, wc.lpszClassName, L"Vulkan DPI Swapchain Test", style,
        100, 100, rc.right - rc.left, rc.bottom - rc.top,
        NULL, NULL, hinst, NULL);
    if (!hwnd) {
        fprintf(stderr, "FAIL: CreateWindowExW failed (err=%lu)\n", GetLastError());
        return 1;
    }

    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    pump_messages(15);

    RECT cr = { 0, 0, 0, 0 };
    GetClientRect(hwnd, &cr);
    LONG client_w = cr.right - cr.left;
    LONG client_h = cr.bottom - cr.top;

    UINT win_dpi = 96;
    HMODULE user32 = GetModuleHandleA("user32.dll");
    if (user32) {
        PFN_GetDpiForWindow p_GetDpiForWindow =
            (PFN_GetDpiForWindow)(void *)GetProcAddress(user32, "GetDpiForWindow");
        if (p_GetDpiForWindow)
            win_dpi = p_GetDpiForWindow(hwnd);
    }

    printf("INFO: DPI-unaware window=%ldx%ld win_dpi=%u reg_LogPixels=%lu RetinaMode=%s\n",
           client_w, client_h, win_dpi, (unsigned long)reg_logpixels, retina_mode);
    if (reg_logpixels <= 96) {
        printf("NOTE: LogPixels=%lu (non-HiDPI prefix; fshack DPI scaling may not activate)\n",
               (unsigned long)reg_logpixels);
    }
    if (client_w != WANT_W || client_h != WANT_H) {
        printf("FAIL: GetClientRect got %ldx%ld, want %ldx%ld\n", client_w, client_h, WANT_W, WANT_H);
        failures++;
    } else {
        printf("PASS: GetClientRect = %ldx%ld\n", client_w, client_h);
    }

    /* Create Vulkan instance with Win32 surface extensions. */
    const char *inst_exts[] = { "VK_KHR_surface", "VK_KHR_win32_surface" };
    VkApplicationInfo app_info;
    memset(&app_info, 0, sizeof(app_info));
    app_info.sType      = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.pApplicationName = "vulkan-dpi-swapchain-test";
    app_info.apiVersion = VK_MAKE_VERSION(1, 1, 0);

    VkInstanceCreateInfo inst_ci;
    memset(&inst_ci, 0, sizeof(inst_ci));
    inst_ci.sType                   = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    inst_ci.pApplicationInfo        = &app_info;
    inst_ci.enabledExtensionCount   = 2;
    inst_ci.ppEnabledExtensionNames = inst_exts;

    VkInstance instance = NULL;
    VkResult vr = p_vkCreateInstance(&inst_ci, NULL, &instance);
    if (vr != VK_SUCCESS) {
        fprintf(stderr, "FAIL: vkCreateInstance returned %d (%s)\n", vr, vk_result_str(vr));
        return 1;
    }

    LOAD_IPROC(instance, vkDestroyInstance);
    LOAD_IPROC(instance, vkEnumeratePhysicalDevices);
    LOAD_IPROC(instance, vkGetPhysicalDeviceQueueFamilyProperties);
    LOAD_IPROC(instance, vkEnumerateDeviceExtensionProperties);
    LOAD_IPROC(instance, vkCreateDevice);
    LOAD_IPROC(instance, vkGetDeviceProcAddr);
    LOAD_IPROC(instance, vkCreateWin32SurfaceKHR);
    LOAD_IPROC(instance, vkDestroySurfaceKHR);
    LOAD_IPROC(instance, vkGetPhysicalDeviceSurfaceSupportKHR);
    LOAD_IPROC(instance, vkGetPhysicalDeviceSurfaceCapabilitiesKHR);

    VkWin32SurfaceCreateInfoKHR surf_ci;
    memset(&surf_ci, 0, sizeof(surf_ci));
    surf_ci.sType     = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
    surf_ci.hinstance = hinst;
    surf_ci.hwnd      = hwnd;

    VkSurfaceKHR surface = 0;
    vr = p_vkCreateWin32SurfaceKHR(instance, &surf_ci, NULL, &surface);
    if (vr != VK_SUCCESS) {
        fprintf(stderr, "FAIL: vkCreateWin32SurfaceKHR returned %d\n", vr);
        return 1;
    }

    /* Pick physical device + graphics/present queue family. */
    uint32_t pd_count = 0;
    vr = p_vkEnumeratePhysicalDevices(instance, &pd_count, NULL);
    if (vr != VK_SUCCESS || pd_count == 0) {
        fprintf(stderr, "FAIL: no Vulkan physical devices (vr=%d, count=%u)\n", vr, pd_count);
        return 1;
    }
    VkPhysicalDevice *pds = calloc(pd_count, sizeof(*pds));
    p_vkEnumeratePhysicalDevices(instance, &pd_count, pds);

    VkPhysicalDevice phys_dev = NULL;
    uint32_t queue_family = UINT32_MAX;
    for (uint32_t i = 0; i < pd_count && !phys_dev; i++) {
        uint32_t qf_count = 0;
        p_vkGetPhysicalDeviceQueueFamilyProperties(pds[i], &qf_count, NULL);
        VkQueueFamilyProperties *qfs = calloc(qf_count, sizeof(*qfs));
        p_vkGetPhysicalDeviceQueueFamilyProperties(pds[i], &qf_count, qfs);
        for (uint32_t q = 0; q < qf_count; q++) {
            VkBool32 supported = VK_FALSE;
            p_vkGetPhysicalDeviceSurfaceSupportKHR(pds[i], q, surface, &supported);
            if ((qfs[q].queueFlags & VK_QUEUE_GRAPHICS_BIT) && supported) {
                phys_dev = pds[i];
                queue_family = q;
                break;
            }
        }
        free(qfs);
    }
    free(pds);
    if (!phys_dev) {
        fprintf(stderr, "FAIL: no physical device supports graphics + Win32 present\n");
        return 1;
    }

    /* Check whether VK_KHR_swapchain_mutable_format is advertised (matches DXVK). */
    int has_mutable_format = 0;
    uint32_t ext_count = 0;
    p_vkEnumerateDeviceExtensionProperties(phys_dev, NULL, &ext_count, NULL);
    if (ext_count > 0) {
        VkExtensionProperties *exts = calloc(ext_count, sizeof(*exts));
        p_vkEnumerateDeviceExtensionProperties(phys_dev, NULL, &ext_count, exts);
        for (uint32_t i = 0; i < ext_count; i++) {
            if (strcmp(exts[i].extensionName, "VK_KHR_swapchain_mutable_format") == 0) {
                has_mutable_format = 1;
                break;
            }
        }
        free(exts);
    }

    const char *dev_exts[2];
    uint32_t dev_ext_count = 0;
    dev_exts[dev_ext_count++] = "VK_KHR_swapchain";
    if (has_mutable_format)
        dev_exts[dev_ext_count++] = "VK_KHR_swapchain_mutable_format";

    float q_prio = 1.0f;
    VkDeviceQueueCreateInfo q_ci;
    memset(&q_ci, 0, sizeof(q_ci));
    q_ci.sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    q_ci.queueFamilyIndex = queue_family;
    q_ci.queueCount       = 1;
    q_ci.pQueuePriorities = &q_prio;

    VkDeviceCreateInfo dev_ci;
    memset(&dev_ci, 0, sizeof(dev_ci));
    dev_ci.sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dev_ci.queueCreateInfoCount    = 1;
    dev_ci.pQueueCreateInfos       = &q_ci;
    dev_ci.enabledExtensionCount   = dev_ext_count;
    dev_ci.ppEnabledExtensionNames = dev_exts;

    VkDevice device = NULL;
    vr = p_vkCreateDevice(phys_dev, &dev_ci, NULL, &device);
    if (vr != VK_SUCCESS) {
        fprintf(stderr, "FAIL: vkCreateDevice returned %d\n", vr);
        return 1;
    }

    LOAD_DPROC(device, vkDestroyDevice);
    LOAD_DPROC(device, vkGetDeviceQueue);
    LOAD_DPROC(device, vkCreateSwapchainKHR);
    LOAD_DPROC(device, vkDestroySwapchainKHR);
    LOAD_DPROC(device, vkGetSwapchainImagesKHR);
    LOAD_DPROC(device, vkAcquireNextImageKHR);
    LOAD_DPROC(device, vkQueuePresentKHR);
    LOAD_DPROC(device, vkCreateSemaphore);
    LOAD_DPROC(device, vkDestroySemaphore);
    LOAD_DPROC(device, vkCreateCommandPool);
    LOAD_DPROC(device, vkDestroyCommandPool);
    LOAD_DPROC(device, vkAllocateCommandBuffers);
    LOAD_DPROC(device, vkBeginCommandBuffer);
    LOAD_DPROC(device, vkEndCommandBuffer);
    LOAD_DPROC(device, vkCmdPipelineBarrier);
    LOAD_DPROC(device, vkQueueSubmit);
    LOAD_DPROC(device, vkQueueWaitIdle);
    LOAD_DPROC(device, vkDeviceWaitIdle);

    VkQueue queue = NULL;
    p_vkGetDeviceQueue(device, queue_family, 0, &queue);

    /* Query surface capabilities and verify client-DPI extent. */
    VkSurfaceCapabilitiesKHR caps;
    memset(&caps, 0, sizeof(caps));
    vr = p_vkGetPhysicalDeviceSurfaceCapabilitiesKHR(phys_dev, surface, &caps);
    if (vr != VK_SUCCESS) {
        fprintf(stderr, "FAIL: vkGetPhysicalDeviceSurfaceCapabilitiesKHR returned %d\n", vr);
        return 1;
    }

    printf("INFO: surface caps currentExtent=%ux%u min=%ux%u max=%ux%u images=%u..%u mutable=%d\n",
           caps.currentExtent.width, caps.currentExtent.height,
           caps.minImageExtent.width, caps.minImageExtent.height,
           caps.maxImageExtent.width, caps.maxImageExtent.height,
           caps.minImageCount, caps.maxImageCount, has_mutable_format);

    if (caps.currentExtent.width != (uint32_t)WANT_W || caps.currentExtent.height != (uint32_t)WANT_H) {
        printf("FAIL: surface currentExtent=%ux%u, want %ldx%ld\n",
               caps.currentExtent.width, caps.currentExtent.height, WANT_W, WANT_H);
        failures++;
    } else {
        printf("PASS: surface currentExtent = %ux%u (matches 96-DPI client rect)\n",
               caps.currentExtent.width, caps.currentExtent.height);
    }

    /* Create swapchain matching DXVK's D3D9 configuration. */
    const int32_t view_formats[2] = { VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_B8G8R8A8_SRGB };
    VkImageFormatListCreateInfo fmt_list;
    memset(&fmt_list, 0, sizeof(fmt_list));
    fmt_list.sType           = VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO;
    fmt_list.viewFormatCount = 2;
    fmt_list.pViewFormats    = view_formats;

    VkSwapchainCreateInfoKHR sc_ci;
    memset(&sc_ci, 0, sizeof(sc_ci));
    sc_ci.sType            = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    sc_ci.surface          = surface;
    sc_ci.minImageCount    = caps.minImageCount;
    sc_ci.imageFormat      = VK_FORMAT_B8G8R8A8_UNORM;
    sc_ci.imageColorSpace  = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    sc_ci.imageExtent      = caps.currentExtent;
    sc_ci.imageArrayLayers = 1;
    sc_ci.imageUsage       = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    sc_ci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    sc_ci.preTransform     = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    sc_ci.compositeAlpha   = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    sc_ci.presentMode      = VK_PRESENT_MODE_FIFO_KHR;
    sc_ci.clipped          = VK_TRUE;
    if (has_mutable_format) {
        sc_ci.flags |= VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR;
        sc_ci.pNext  = &fmt_list;
    }

    VkSwapchainKHR swapchain = 0;
    vr = p_vkCreateSwapchainKHR(device, &sc_ci, NULL, &swapchain);
    if (vr != VK_SUCCESS) {
        fprintf(stderr, "FAIL: vkCreateSwapchainKHR returned %d (%s)\n", vr, vk_result_str(vr));
        return 1;
    }

    uint32_t img_count = 0;
    p_vkGetSwapchainImagesKHR(device, swapchain, &img_count, NULL);
    VkImage *images = calloc(img_count, sizeof(*images));
    p_vkGetSwapchainImagesKHR(device, swapchain, &img_count, images);

    VkSemaphoreCreateInfo sem_ci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, NULL, 0 };
    VkSemaphore acquire_sem = 0, present_sem = 0;
    p_vkCreateSemaphore(device, &sem_ci, NULL, &acquire_sem);
    p_vkCreateSemaphore(device, &sem_ci, NULL, &present_sem);

    VkCommandPoolCreateInfo pool_ci;
    memset(&pool_ci, 0, sizeof(pool_ci));
    pool_ci.sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_ci.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_ci.queueFamilyIndex = queue_family;

    VkCommandPool cmd_pool = 0;
    p_vkCreateCommandPool(device, &pool_ci, NULL, &cmd_pool);

    VkCommandBufferAllocateInfo cb_ai;
    memset(&cb_ai, 0, sizeof(cb_ai));
    cb_ai.sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cb_ai.commandPool        = cmd_pool;
    cb_ai.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cb_ai.commandBufferCount = 1;

    VkCommandBuffer cmd = NULL;
    p_vkAllocateCommandBuffers(device, &cb_ai, &cmd);

    int suboptimal_count = 0;
    for (int frame = 0; frame < NUM_FRAMES; frame++) {
        uint32_t img_idx = 0;
        VkResult acq_res = p_vkAcquireNextImageKHR(
            device, swapchain, UINT64_MAX, acquire_sem, 0, &img_idx);
        if (acq_res < 0) {
            printf("FAIL: frame %d vkAcquireNextImageKHR returned %d (%s)\n",
                   frame, acq_res, vk_result_str(acq_res));
            failures++;
            break;
        }

        VkCommandBufferBeginInfo begin_info = {
            VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
            VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL
        };
        p_vkBeginCommandBuffer(cmd, &begin_info);

        VkImageMemoryBarrier barrier;
        memset(&barrier, 0, sizeof(barrier));
        barrier.sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout           = VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout           = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image               = images[img_idx];
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.layerCount = 1;

        p_vkCmdPipelineBarrier(cmd,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0, 0, NULL, 0, NULL, 1, &barrier);
        p_vkEndCommandBuffer(cmd);

        VkFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submit_info;
        memset(&submit_info, 0, sizeof(submit_info));
        submit_info.sType                = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.waitSemaphoreCount   = 1;
        submit_info.pWaitSemaphores      = &acquire_sem;
        submit_info.pWaitDstStageMask    = &wait_stage;
        submit_info.commandBufferCount   = 1;
        submit_info.pCommandBuffers      = &cmd;
        submit_info.signalSemaphoreCount = 1;
        submit_info.pSignalSemaphores    = &present_sem;

        vr = p_vkQueueSubmit(queue, 1, &submit_info, 0);
        if (vr != VK_SUCCESS) {
            printf("FAIL: frame %d vkQueueSubmit returned %d\n", frame, vr);
            failures++;
            break;
        }

        VkPresentInfoKHR pres_info;
        memset(&pres_info, 0, sizeof(pres_info));
        pres_info.sType              = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        pres_info.waitSemaphoreCount = 1;
        pres_info.pWaitSemaphores    = &present_sem;
        pres_info.swapchainCount     = 1;
        pres_info.pSwapchains        = &swapchain;
        pres_info.pImageIndices      = &img_idx;

        VkResult pres_res = p_vkQueuePresentKHR(queue, &pres_info);
        p_vkQueueWaitIdle(queue);
        pump_messages(2);

        printf("INFO: frame %d acquire=%d (%s) present=%d (%s)\n",
               frame, acq_res, vk_result_str(acq_res), pres_res, vk_result_str(pres_res));

        if (pres_res == VK_SUBOPTIMAL_KHR)
            suboptimal_count++;

        if (frame >= 1 && (acq_res != VK_SUCCESS || pres_res != VK_SUCCESS)) {
            printf("FAIL: frame %d non-optimal presentation (acquire=%d, present=%d)\n",
                   frame, acq_res, pres_res);
            failures++;
        }
    }

    p_vkDeviceWaitIdle(device);
    free(images);
    p_vkDestroyCommandPool(device, cmd_pool, NULL);
    p_vkDestroySemaphore(device, present_sem, NULL);
    p_vkDestroySemaphore(device, acquire_sem, NULL);
    p_vkDestroySwapchainKHR(device, swapchain, NULL);
    p_vkDestroyDevice(device, NULL);
    p_vkDestroySurfaceKHR(instance, surface, NULL);
    p_vkDestroyInstance(instance, NULL);
    DestroyWindow(hwnd);

    if (failures == 0) {
        printf("PASS: all %d frames presented cleanly with VK_SUCCESS (suboptimal=%d)\n",
               NUM_FRAMES, suboptimal_count);
        return 0;
    }

    printf("FAIL: %d check(s) failed (suboptimal_presents=%d/%d)\n",
           failures, suboptimal_count, NUM_FRAMES);
    return 1;
}

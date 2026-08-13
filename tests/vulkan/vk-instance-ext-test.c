/*
 * vk-instance-ext-test — what instance extensions does winevulkan actually offer?
 *
 * Build: i686-w64-mingw32-gcc -O2 -I../../vendor/homebrew-x86/opt/vulkan-headers/include \
 *            -o vk-instance-ext-test.exe vk-instance-ext-test.c
 *        (x86_64-w64-mingw32-gcc for the 64-bit twin; the 32-bit one is what
 *         matters for a 32-bit game. vulkan-loader-test.sh builds it for you.)
 * Run:   wine vk-instance-ext-test.exe        (inside the affected bottle)
 *
 * WHY, rather than reading DXVK's log. DXVK only enables an extension whose
 * specVersion it found while enumerating (dxvk_instance.cpp), while
 * VK_KHR_win32_surface is added unconditionally by the WSI provider -- so its
 * log is a *report* that VK_KHR_surface was not offered, not a choice. This
 * asks directly, and separates "no ICD at all" from "an ICD with no surface
 * extension". vulkan-loader-test.sh wraps it in the two-arm experiment.
 *
 * Loads vulkan-1.dll by name rather than linking an import, so a missing DLL is
 * a diagnosis this prints rather than a loader error that stops it. Hence
 * VK_NO_PROTOTYPES -- vendored headers, no import library, and no transcribed
 * struct layouts in a probe whose job is to be trusted about Vulkan.
 *
 * Exit code is the number of failed checks.
 */
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_WIN32_KHR
#include <windows.h>
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *vk_result_name( VkResult r )
{
    switch (r)
    {
    case VK_SUCCESS:                        return "VK_SUCCESS";
    case VK_ERROR_OUT_OF_HOST_MEMORY:       return "VK_ERROR_OUT_OF_HOST_MEMORY";
    case VK_ERROR_OUT_OF_DEVICE_MEMORY:     return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
    case VK_ERROR_INITIALIZATION_FAILED:    return "VK_ERROR_INITIALIZATION_FAILED";
    case VK_ERROR_LAYER_NOT_PRESENT:        return "VK_ERROR_LAYER_NOT_PRESENT";
    case VK_ERROR_EXTENSION_NOT_PRESENT:    return "VK_ERROR_EXTENSION_NOT_PRESENT";
    case VK_ERROR_INCOMPATIBLE_DRIVER:      return "VK_ERROR_INCOMPATIBLE_DRIVER";
    default:                                return "?";
    }
}

int main( void )
{
    HMODULE vk;
    PFN_vkEnumerateInstanceExtensionProperties pEnumExt;
    PFN_vkCreateInstance pCreate;
    PFN_vkEnumerateInstanceVersion pVersion;
    VkExtensionProperties *props = NULL;
    unsigned int count = 0, i, ver = 0;
    int failures = 0, have_surface = 0, have_win32 = 0;
    VkResult r;

    printf( "process is %d-bit\n\n", (int)(sizeof(void *) * 8) );

    if (!(vk = LoadLibraryA( "vulkan-1.dll" )))
    {
        printf( "FAIL  vulkan-1.dll will not load (%lu) -- nothing below can run\n", GetLastError() );
        return 1;
    }
    printf( "pass  vulkan-1.dll loaded at %p\n", (void *)vk );

    pEnumExt = (PFN_vkEnumerateInstanceExtensionProperties)GetProcAddress( vk, "vkEnumerateInstanceExtensionProperties" );
    pCreate  = (PFN_vkCreateInstance)GetProcAddress( vk, "vkCreateInstance" );
    pVersion = (PFN_vkEnumerateInstanceVersion)GetProcAddress( vk, "vkEnumerateInstanceVersion" );
    if (!pEnumExt || !pCreate)
    {
        printf( "FAIL  vulkan-1.dll is missing vkEnumerateInstanceExtensionProperties/vkCreateInstance\n" );
        return 1;
    }

    if (pVersion && pVersion( &ver ) == VK_SUCCESS)
        printf( "      loader reports API version %u.%u.%u\n",
                (ver >> 22) & 0x7f, (ver >> 12) & 0x3ff, ver & 0xfff );
    else
        printf( "      vkEnumerateInstanceVersion unavailable (a 1.0 loader)\n" );

    printf( "\n1. instance extensions offered\n" );
    r = pEnumExt( NULL, &count, NULL );
    if (r != VK_SUCCESS)
    {
        printf( "   FAIL  enumerate returned %s\n", vk_result_name( r ) );
        return 1;
    }
    printf( "   %u extension(s)\n", count );
    if (count)
    {
        props = (VkExtensionProperties *)calloc( count, sizeof(*props) );
        pEnumExt( NULL, &count, props );
        for (i = 0; i < count; i++)
        {
            printf( "     %s\n", props[i].extensionName );
            if (!strcmp( props[i].extensionName, VK_KHR_SURFACE_EXTENSION_NAME ))       have_surface = 1;
            if (!strcmp( props[i].extensionName, VK_KHR_WIN32_SURFACE_EXTENSION_NAME )) have_win32 = 1;
        }
    }
    /* These two are what DXVK needs, and the pair is the point: win32_surface
     * without surface is the state that makes vkCreateInstance fail. */
    printf( "   %s  VK_KHR_surface\n",       have_surface ? "pass " : "FAIL " );
    printf( "   %s  VK_KHR_win32_surface\n", have_win32   ? "pass " : "FAIL " );
    failures += !have_surface + !have_win32;

    printf( "\n2. create an instance the way DXVK does\n" );
    {
        const char *exts[2]; unsigned int n = 0;
        VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO };
        VkInstanceCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
        VkInstance inst = NULL;

        if (have_surface) exts[n++] = VK_KHR_SURFACE_EXTENSION_NAME;
        if (have_win32)   exts[n++] = VK_KHR_WIN32_SURFACE_EXTENSION_NAME;

        app.pApplicationName = "vk-instance-ext-test";
        app.pEngineName = "DXVK";
        app.apiVersion = VK_API_VERSION_1_3;
        ci.pApplicationInfo = &app;
        ci.enabledExtensionCount = n;
        ci.ppEnabledExtensionNames = exts;

        r = pCreate( &ci, NULL, &inst );
        printf( "   %s  apiVersion 1.3 with %u extension(s) -> %s\n",
                r == VK_SUCCESS ? "pass " : "FAIL ", n, vk_result_name( r ) );
        if (r != VK_SUCCESS)
        {
            failures++;
            /* Retry at 1.0: an ICD that only implements an older API version
             * rejects the higher request with INCOMPATIBLE_DRIVER, and that
             * distinction decides whether the fix is in the driver or in what
             * DXVK asks for. */
            app.apiVersion = VK_API_VERSION_1_0;
            ci.enabledExtensionCount = 0;
            r = pCreate( &ci, NULL, &inst );
            printf( "   %s  retry: apiVersion 1.0, no extensions -> %s\n",
                    r == VK_SUCCESS ? "note " : "FAIL ", vk_result_name( r ) );
            if (r != VK_SUCCESS) failures++;
        }
    }

    printf( "\n%d failed check(s)\n", failures );
    return failures;
}

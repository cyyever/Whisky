/*
 * feature-gate-test — are the driver features our patches relax still missing?
 *
 * Two of our patches exist only because KosmicKrisp did not report a feature
 * that a translation layer demanded:
 *
 *   patches/dxvk/0001          six VkPhysicalDeviceFeatures turned from
 *                              required into optional so DXVK's d3d9 can create
 *                              a device at all
 *   patches/vkd3d-proton/0001  a device-init gate made non-fatal so D3D12
 *                              reaches device creation
 *
 * A relaxation whose feature the driver has since gained is dead weight, and
 * worse than dead: it hides a regression. If KosmicKrisp ever stops reporting
 * one of them again, an enforced requirement fails loudly at device creation,
 * while a relaxed one lets the layer build a pipeline the device cannot honour
 * -- invalid usage, and device loss on some drivers.
 *
 * So this asks the driver directly rather than reading the patch and guessing,
 * and it is meant to be re-run after every `git submodule update` of mesa.
 *
 * This only REPORTS what the driver has; whether a patch still relaxes a given
 * feature is a separate question, answered by feature-gate-test.sh, which owns
 * the verdict. Reporting on driver support alone kept calling four
 * already-narrowed relaxations "dead weight" after they had been removed.
 *
 * Always exits 0 unless the driver could not be queried.
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <string.h>

/* VK_INCOMPLETE is success-class: vkEnumeratePhysicalDevices returns it when
 * more devices exist than the array holds, which is not a reason to abort. */
#define VK(x) do { VkResult r_ = (x); \
    if (r_ != VK_SUCCESS && r_ != VK_INCOMPLETE) { \
        fprintf(stderr, "FAIL  %s = %d\n", #x, r_); return 1; } } while (0)

struct gate {
    const char *feature;
    const char *patch;
    VkBool32    supported;
};

int main(void)
{
    VkInstance inst;
    VkPhysicalDevice phys[8];
    uint32_t count = 8;
    char name[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE] = { 0 };

    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.apiVersion = VK_API_VERSION_1_3;
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &app;
    VK(vkCreateInstance(&ici, NULL, &inst));
    VK(vkEnumeratePhysicalDevices(inst, &count, phys));
    if (!count) { fprintf(stderr, "FAIL  no Vulkan device\n"); return 1; }

    VkPhysicalDeviceRobustness2FeaturesEXT rob2 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
    VkPhysicalDeviceDepthClipEnableFeaturesEXT clip = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT, &rob2 };
    VkPhysicalDeviceFeatures2 f2 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &clip };
    vkGetPhysicalDeviceFeatures2(phys[0], &f2);

    VkPhysicalDeviceTransformFeedbackPropertiesEXT xfbp = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_PROPERTIES_EXT };
    VkPhysicalDeviceTexelBufferAlignmentProperties align = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TEXEL_BUFFER_ALIGNMENT_PROPERTIES, &xfbp };
    VkPhysicalDeviceProperties2 p2 = {
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &align };
    vkGetPhysicalDeviceProperties2(phys[0], &p2);
    memcpy(name, p2.properties.deviceName, sizeof name - 1);
    printf("device: %s\n\n", name);

    struct gate gates[] = {
        { "fillModeNonSolid",    "dxvk/0001",         f2.features.fillModeNonSolid },
        { "geometryShader",      "dxvk/0001",         f2.features.geometryShader },
        { "shaderCullDistance",  "dxvk/0001",         f2.features.shaderCullDistance },
        { "depthClipEnable",     "dxvk/0001",         clip.depthClipEnable },
        { "robustBufferAccess2", "dxvk/0001",         rob2.robustBufferAccess2 },
        { "nullDescriptor",      "dxvk/0001",         rob2.nullDescriptor },
        { "transformFeedbackQueries", "vkd3d-proton/0001", xfbp.transformFeedbackQueries },
        /* Mirror what vkd3d actually tests (libs/vkd3d/device.c): it accepts
         * EITHER the single-texel bool OR an alignment of one byte. Checking
         * only the bool would call the relaxation necessary on a driver vkd3d
         * would have accepted unpatched -- the inverse of the failure this
         * test exists to catch. */
        { "singleTexelAlignment", "vkd3d-proton/0001",
          (align.storageTexelBufferOffsetSingleTexelAlignment ||
           align.storageTexelBufferOffsetAlignmentBytes == 1) &&
          (align.uniformTexelBufferOffsetSingleTexelAlignment ||
           align.uniformTexelBufferOffsetAlignmentBytes == 1) },
    };

    for (size_t i = 0; i < sizeof gates / sizeof gates[0]; i++)
        printf("%-26s %s\n", gates[i].feature,
               gates[i].supported ? "SUPPORTED" : "missing");

    vkDestroyInstance(inst, NULL);
    return 0;
}

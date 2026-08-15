/* Probe SSFIV's missing-triangle artifact with no Wine, no D3D, no game:
 * a native x86_64 (Rosetta) process -> Vulkan loader -> KosmicKrisp -> Metal.
 *
 * OUTCOME so far: every config below renders CORRECTLY on KosmicKrisp
 * (Mesa 82203941) -- strip winding is compensated before the cull test, and
 * non-4-aligned uint16 index offsets fetch the right indices. The negatives
 * exonerate the core draw path and leave DXVK<->KK state translation (vertex
 * fetch offsets, pretransformed-vertex shaders) as the artifact's home. Kept
 * as a regression guard for KosmicKrisp bumps.
 *
 * The in-game artifact: 2D fullscreen draws (loading screens, video) render
 * only the lower-right diagonal half -- one of a quad's two triangles is
 * missing -- and the in-match 3D scene goes fully black. That shape suggests
 * primitive assembly or face culling: a quad drawn as a 4-vertex strip has
 * alternating triangle winding which the rasterizer must compensate before
 * the cull test, and losing that compensation culls exactly one of the two.
 *
 * So: one fullscreen quad, drawn under a matrix of topology x cull x winding,
 * probing one pixel in the upper-left half and one in the lower-right half.
 * The bug's signature is the two probes DISAGREEING on a single draw. The
 * uniform-winding list configs calibrate which facing is which, so a plain
 * "everything culled" stays distinguishable from "half culled".
 *
 * Uses only Vulkan 1.3 core (dynamic rendering + extended dynamic state), the
 * same level KosmicKrisp advertises. Exit code is the number of failures.
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "quad_vert.h"
#include "quad_frag.h"

#define W 64
#define H 64
#define VK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("FAIL  %s = %d\n", #x, r_); return 1; } } while (0)

static VkInstance inst;
static VkPhysicalDevice phys;
static VkDevice dev;
static VkQueue queue;
static uint32_t qfam;

static uint32_t find_mem(uint32_t bits, VkMemoryPropertyFlags props) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & props) == props) return i;
    return UINT32_MAX;
}

static VkShaderModule module(const uint32_t *code, size_t bytes) {
    VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    ci.codeSize = bytes; ci.pCode = code;
    VkShaderModule m; vkCreateShaderModule(dev, &ci, NULL, &m); return m;
}

struct config {
    const char *name;
    VkPrimitiveTopology topo;
    int base, count;                /* push-constant base + vertex count */
    VkCullModeFlags cull;
    VkFrontFace front;
    int indexed;                    /* -1 = non-indexed, else index byte offset */
    /* expected probe state: 2 = both red, 0 = both black, 1 = don't know
     * which of the two frontFace variants survives (resolved at runtime by
     * requiring the CCW/CW pair to disagree); -1 printed on mismatch */
};

int main(void) {
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.apiVersion = VK_API_VERSION_1_3;
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &app;
    VK(vkCreateInstance(&ici, NULL, &inst));

    uint32_t n = 1;
    VK(vkEnumeratePhysicalDevices(inst, &n, &phys));
    VkPhysicalDeviceProperties pp; vkGetPhysicalDeviceProperties(phys, &pp);
    printf("device: %s\n", pp.deviceName);

    uint32_t qn = 0; vkGetPhysicalDeviceQueueFamilyProperties(phys, &qn, NULL);
    VkQueueFamilyProperties *qf = calloc(qn, sizeof(*qf));
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qn, qf);
    qfam = UINT32_MAX;
    for (uint32_t i = 0; i < qn; i++) if (qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { qfam = i; break; }
    if (qfam == UINT32_MAX) { printf("FAIL  no graphics queue\n"); return 1; }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = qfam; qci.queueCount = 1; qci.pQueuePriorities = &prio;
    VkPhysicalDeviceVulkan13Features f13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    f13.dynamicRendering = VK_TRUE;
    VkPhysicalDeviceExtendedDynamicStateFeaturesEXT eds = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT };
    eds.extendedDynamicState = VK_TRUE; eds.pNext = &f13;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.pNext = &eds; dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci;
    VK(vkCreateDevice(phys, &dci, NULL, &dev));
    vkGetDeviceQueue(dev, qfam, 0, &queue);

    VkImageCreateInfo imci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    imci.imageType = VK_IMAGE_TYPE_2D; imci.format = VK_FORMAT_R8G8B8A8_UNORM;
    imci.extent = (VkExtent3D){ W, H, 1 }; imci.mipLevels = 1; imci.arrayLayers = 1;
    imci.samples = VK_SAMPLE_COUNT_1_BIT; imci.tiling = VK_IMAGE_TILING_OPTIMAL;
    imci.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    imci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkImage img; VK(vkCreateImage(dev, &imci, NULL, &img));
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, img, &mr);
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = mr.size; mai.memoryTypeIndex = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkDeviceMemory imem; VK(vkAllocateMemory(dev, &mai, NULL, &imem));
    VK(vkBindImageMemory(dev, img, imem, 0));
    VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    ivci.image = img; ivci.viewType = VK_IMAGE_VIEW_TYPE_2D; ivci.format = imci.format;
    ivci.subresourceRange = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    VkImageView view; VK(vkCreateImageView(dev, &ivci, NULL, &view));

    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = W * H * 4; bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer buf; VK(vkCreateBuffer(dev, &bci, NULL, &buf));
    VkMemoryRequirements bmr; vkGetBufferMemoryRequirements(dev, buf, &bmr);
    VkMemoryAllocateInfo bmai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    bmai.allocationSize = bmr.size;
    bmai.memoryTypeIndex = find_mem(bmr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory bmem; VK(vkAllocateMemory(dev, &bmai, NULL, &bmem));
    VK(vkBindBufferMemory(dev, buf, bmem, 0));

    /* Index buffer for the indexed configs: the quad as a uniform-winding
     * uint16 triangle list against the strip-order vertex array (base=0).
     * The same six indices are stored twice more at +1 and +3 index slots,
     * so binding at byte offsets 2 and 6 draws the identical quad -- Metal
     * constrains indexBufferOffset, and a translator that rounds or rebases
     * it shifts every index and degenerates one triangle: the artifact. */
    static const uint16_t quad_idx[] = {
        0,1,2, 2,1,3,
        0,1,2, 2,1,3,
    };
    /* Layout: [dead][quad @ byte 2][dead][dead][quad @ byte 18] -- both copies
     * start 2 mod 4, the alignment a translator is most likely to mishandle. */
    uint16_t idx_data[1 + 6 + 2 + 6] = { 0xdead };
    memcpy(idx_data + 1, quad_idx, 6 * 2);
    idx_data[7] = 0xdead; idx_data[8] = 0xdead;
    memcpy(idx_data + 9, quad_idx, 6 * 2);
    VkBufferCreateInfo ibci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    ibci.size = sizeof(idx_data); ibci.usage = VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
    VkBuffer ibuf; VK(vkCreateBuffer(dev, &ibci, NULL, &ibuf));
    VkMemoryRequirements imr2; vkGetBufferMemoryRequirements(dev, ibuf, &imr2);
    VkMemoryAllocateInfo imai2 = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    imai2.allocationSize = imr2.size;
    imai2.memoryTypeIndex = find_mem(imr2.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory imem2; VK(vkAllocateMemory(dev, &imai2, NULL, &imem2));
    VK(vkBindBufferMemory(dev, ibuf, imem2, 0));
    { void *ip; VK(vkMapMemory(dev, imem2, 0, VK_WHOLE_SIZE, 0, &ip));
      memcpy(ip, idx_data, sizeof(idx_data)); vkUnmapMemory(dev, imem2); }

    VkPushConstantRange pcr = { VK_SHADER_STAGE_VERTEX_BIT, 0, 4 };
    VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    plci.pushConstantRangeCount = 1; plci.pPushConstantRanges = &pcr;
    VkPipelineLayout layout; VK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

    VkPipelineShaderStageCreateInfo stages[2] = {
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, 0, 0, VK_SHADER_STAGE_VERTEX_BIT,   module(quad_vert_spv, sizeof(quad_vert_spv)), "main", NULL },
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, 0, 0, VK_SHADER_STAGE_FRAGMENT_BIT, module(quad_frag_spv, sizeof(quad_frag_spv)), "main", NULL },
    };
    VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkViewport vp = { 0, 0, W, H, 0, 1 };
    VkRect2D sc = { { 0, 0 }, { W, H } };
    VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
    vps.viewportCount = 1; vps.pViewports = &vp; vps.scissorCount = 1; vps.pScissors = &sc;
    VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
    rs.polygonMode = VK_POLYGON_MODE_FILL; rs.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState cba = { 0 };
    cba.colorWriteMask = 0xf;
    VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
    cb.attachmentCount = 1; cb.pAttachments = &cba;
    VkDynamicState dyn[] = { VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY, VK_DYNAMIC_STATE_CULL_MODE, VK_DYNAMIC_STATE_FRONT_FACE };
    VkPipelineDynamicStateCreateInfo ds = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO };
    ds.dynamicStateCount = 3; ds.pDynamicStates = dyn;
    VkFormat colfmt = VK_FORMAT_R8G8B8A8_UNORM;
    VkPipelineRenderingCreateInfo prc = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO };
    prc.colorAttachmentCount = 1; prc.pColorAttachmentFormats = &colfmt;
    VkGraphicsPipelineCreateInfo gpci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    gpci.pNext = &prc; gpci.stageCount = 2; gpci.pStages = stages;
    gpci.pVertexInputState = &vi; gpci.pInputAssemblyState = &ia; gpci.pViewportState = &vps;
    gpci.pRasterizationState = &rs; gpci.pMultisampleState = &ms; gpci.pColorBlendState = &cb;
    gpci.pDynamicState = &ds; gpci.layout = layout;
    VkPipeline pipe; VK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &pipe));

    VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = qfam;
    VkCommandPool pool; VK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cbai.commandPool = pool; cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cbai.commandBufferCount = 1;
    VkCommandBuffer cmd; VK(vkAllocateCommandBuffers(dev, &cbai, &cmd));

    struct config cfgs[] = {
        { "list6  cull=NONE          ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  4, 6, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        { "strip4 cull=NONE          ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        { "strip4 cull=BACK front=CCW", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        { "strip4 cull=BACK front=CW ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_CLOCKWISE, -1 },
        { "list6  cull=BACK front=CCW", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  4, 6, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        { "list6  cull=BACK front=CW ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  4, 6, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_CLOCKWISE, -1 },
        { "idx16  offset=2  cull=NONE", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  0, 6, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, 2 },
        { "idx16  offset=18 cull=NONE", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  0, 6, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, 18 },
        { "idx16  offset=2  cull=BACK", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  0, 6, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE, 2 },
    };
    enum { NCFG = sizeof(cfgs) / sizeof(cfgs[0]) };
    int results[NCFG][2];  /* [cfg][probe]: 1=red 0=black */
    int failures = 0;

    for (int i = 0; i < NCFG; i++) {
        VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        cbbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        VK(vkBeginCommandBuffer(cmd, &cbbi));

        VkImageMemoryBarrier toColor = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
        toColor.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;  /* discard; we clear */
        toColor.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        toColor.image = img; toColor.subresourceRange = ivci.subresourceRange;
        toColor.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                             0, 0, NULL, 0, NULL, 1, &toColor);

        VkRenderingAttachmentInfo colAtt = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO };
        colAtt.imageView = view; colAtt.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        colAtt.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; colAtt.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        colAtt.clearValue.color.float32[3] = 1;
        VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO };
        ri.renderArea = sc; ri.layerCount = 1; ri.colorAttachmentCount = 1; ri.pColorAttachments = &colAtt;
        vkCmdBeginRendering(cmd, &ri);
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
        vkCmdSetPrimitiveTopology(cmd, cfgs[i].topo);
        vkCmdSetCullMode(cmd, cfgs[i].cull);
        vkCmdSetFrontFace(cmd, cfgs[i].front);
        vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 4, &cfgs[i].base);
        if (cfgs[i].indexed >= 0) {
            vkCmdBindIndexBuffer(cmd, ibuf, cfgs[i].indexed, VK_INDEX_TYPE_UINT16);
            vkCmdDrawIndexed(cmd, cfgs[i].count, 1, 0, 0, 0);
        }
        else
            vkCmdDraw(cmd, cfgs[i].count, 1, 0, 0);
        vkCmdEndRendering(cmd);

        VkImageMemoryBarrier toSrc = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
        toSrc.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL; toSrc.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        toSrc.image = img; toSrc.subresourceRange = ivci.subresourceRange;
        toSrc.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT; toSrc.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, NULL, 0, NULL, 1, &toSrc);
        VkBufferImageCopy copy = { 0 };
        copy.imageSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
        copy.imageExtent = (VkExtent3D){ W, H, 1 };
        vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &copy);
        VK(vkEndCommandBuffer(cmd));

        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
        si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
        VK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
        VK(vkQueueWaitIdle(queue));

        unsigned char *px;
        VK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&px));
        /* Upper-left probe sits inside the quad's first triangle, lower-right
         * inside the second -- the diagonal between them is the artifact's
         * edge, so the pair disagreeing IS the game's bug. */
        unsigned char *ul = px + ((H / 4) * W + (W / 4)) * 4;
        unsigned char *lr = px + ((3 * H / 4) * W + (3 * W / 4)) * 4;
        results[i][0] = ul[0] > 128; results[i][1] = lr[0] > 128;
        vkUnmapMemory(dev, bmem);
        printf("  %s UL=%s LR=%s\n", cfgs[i].name,
               results[i][0] ? "red  " : "BLACK", results[i][1] ? "red  " : "BLACK");
        VK(vkResetCommandBuffer(cmd, 0));
    }

    /* Verdicts. */
    if (!(results[0][0] && results[0][1])) { printf("FAIL  baseline list draw is broken\n"); failures++; }
    if (results[1][0] != results[1][1])    { printf("FAIL  strip w/o cull drops a triangle -- assembly bug\n"); failures++; }
    else if (!results[1][0])               { printf("FAIL  strip w/o cull drew nothing\n"); failures++; }
    if (results[2][0] != results[2][1] || results[3][0] != results[3][1]) {
        printf("FAIL  strip+cull culls only ONE of the two triangles -- the game artifact:\n");
        printf("      strip winding is not being compensated before the cull test\n");
        failures++;
    }
    if (results[2][0] == results[3][0] && results[2][1] == results[3][1]) {
        printf("FAIL  frontFace has no effect on strip+cull\n"); failures++;
    }
    if (results[4][0] != results[4][1] || results[5][0] != results[5][1]) {
        printf("FAIL  list+cull splits a uniform-winding quad\n"); failures++;
    }
    if (results[4][0] == results[5][0]) {
        printf("FAIL  frontFace has no effect on list+cull\n"); failures++;
    }
    for (int i = 6; i < NCFG; i++) {
        if (results[i][0] != results[i][1]) {
            printf("FAIL  %s drops one triangle -- index offset mishandled (the game artifact)\n", cfgs[i].name);
            failures++;
        } else if (!results[i][0]) {
            printf("FAIL  %s drew nothing -- indices misread wholesale\n", cfgs[i].name);
            failures++;
        }
    }

    printf("\n%d failed check(s)\n", failures);
    return failures;
}

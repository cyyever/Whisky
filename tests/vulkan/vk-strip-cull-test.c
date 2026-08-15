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
#include "quad_attr_vert.h"

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

/* create + memory + bind, the five-step dance every probe buffer needs. */
static VkBuffer make_buffer(VkDeviceSize size, VkBufferUsageFlags usage,
                            VkMemoryPropertyFlags props, VkDeviceMemory *mem) {
    VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    ci.size = size; ci.usage = usage;
    VkBuffer buf; vkCreateBuffer(dev, &ci, NULL, &buf);
    VkMemoryRequirements r; vkGetBufferMemoryRequirements(dev, buf, &r);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = r.size;
    ai.memoryTypeIndex = find_mem(r.memoryTypeBits, props);
    vkAllocateMemory(dev, &ai, NULL, mem);
    vkBindBufferMemory(dev, buf, *mem, 0);
    return buf;
}

/* The two diagonal probe pixels every verdict reads: upper-left sits inside
 * the quad's first triangle, lower-right inside the second -- the diagonal
 * between them is the artifact's edge, so the pair disagreeing IS the bug. */
static void probe_pixels(const unsigned char *px, int *ul, int *lr) {
    *ul = px[((H / 4) * W + (W / 4)) * 4] > 128;
    *lr = px[((3 * H / 4) * W + (3 * W / 4)) * 4] > 128;
}

/* Shared recording around every probe draw: UNDEFINED -> COLOR_ATTACHMENT
 * barrier + a clearing beginRendering; the caller binds state and draws;
 * end_color_pass closes the pass and copies the image out for readback. */
static void begin_color_pass(VkCommandBuffer cmd, VkImage img, VkImageView view,
                             VkImageSubresourceRange range, VkRect2D sc) {
    VkImageMemoryBarrier toColor = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    toColor.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;  /* discard; we clear */
    toColor.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    toColor.image = img; toColor.subresourceRange = range;
    toColor.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                         0, 0, NULL, 0, NULL, 1, &toColor);

    VkRenderingAttachmentInfo colAtt = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO };
    colAtt.imageView = view; colAtt.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    colAtt.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; colAtt.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    colAtt.clearValue.color.float32[3] = 1;
    VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO };
    ri.renderArea = sc; ri.layerCount = 1; ri.colorAttachmentCount = 1; ri.pColorAttachments = &colAtt;
    vkCmdBeginRendering(cmd, &ri);
}

static void end_color_pass(VkCommandBuffer cmd, VkImage img,
                           VkImageSubresourceRange range, VkBuffer dst) {
    vkCmdEndRendering(cmd);
    VkImageMemoryBarrier toSrc = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    toSrc.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL; toSrc.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    toSrc.image = img; toSrc.subresourceRange = range;
    toSrc.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT; toSrc.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 1, &toSrc);
    VkBufferImageCopy copy = { 0 };
    copy.imageSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
    copy.imageExtent = (VkExtent3D){ W, H, 1 };
    vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dst, 1, &copy);
}

struct config {
    const char *name;
    VkPrimitiveTopology topo;
    int base, count;                /* push-constant base + vertex count */
    VkCullModeFlags cull;
    VkFrontFace front;
    int indexed;                    /* -1 = non-indexed, else index byte offset */
    int attr;                       /* 1 = fetch positions from a vertex buffer */
    int vb_off;                     /* vertex buffer bind offset (bytes) */
    int first;                      /* firstVertex (draw) / vertexOffset (indexed) */
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

    VkDeviceMemory bmem;
    VkBuffer buf = make_buffer(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                               VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                               &bmem);

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
    VkDeviceMemory imem2;
    VkBuffer ibuf = make_buffer(sizeof(idx_data), VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                &imem2);
    { void *ip; VK(vkMapMemory(dev, imem2, 0, VK_WHOLE_SIZE, 0, &ip));
      memcpy(ip, idx_data, sizeof(idx_data)); vkUnmapMemory(dev, imem2); }

    /* Vertex buffer, 28-byte stride (a D3D9 XYZRHW|DIFFUSE|TEX1 layout).
     * Three copies of the strip-order quad:
     *   slots 0-3   (byte 0)      -- baseline
     *   slots 4-7   (byte 112)    -- reached via firstVertex/vertexOffset = 4
     *   byte 228 = 8*28+4         -- reached via a bind offset that is 4-aligned
     *                                but NOT a multiple of the stride, the shape
     *                                DXVK's UP suballocation produces
     * Everything else is 0x77 filler: a fetch from the wrong slot lands far
     * off-screen instead of accidentally forming the same quad. */
    #define STRIDE 28
    unsigned char vtx_data[STRIDE * 12 + 4 + 2048];
    memset(vtx_data, 0x77, sizeof(vtx_data));
    {
        static const float quad_pos[4][2] = { {-1,-1}, {-1,1}, {1,-1}, {1,1} };
        for (int v = 0; v < 4; v++) {
            memcpy(vtx_data + v * STRIDE,           quad_pos[v], 8);
            memcpy(vtx_data + (4 + v) * STRIDE,     quad_pos[v], 8);
            memcpy(vtx_data + 8 * STRIDE + 4 + v * STRIDE, quad_pos[v], 8);
        }
    }
    VkDeviceMemory vmem;
    VkBuffer vbuf = make_buffer(sizeof(vtx_data), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                &vmem);
    unsigned char *vtx_map;
    VK(vkMapMemory(dev, vmem, 0, VK_WHOLE_SIZE, 0, (void **)&vtx_map));
    memcpy(vtx_map, vtx_data, sizeof(vtx_data));  /* stays mapped: the stress
      phase rewrites it every frame, the way vk_meta's blit path writes fresh
      vertex data on the CPU immediately before every draw. */

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
    VkDynamicState dyn[] = { VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY, VK_DYNAMIC_STATE_CULL_MODE, VK_DYNAMIC_STATE_FRONT_FACE,
                             VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo ds = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO };
    ds.dynamicStateCount = 5; ds.pDynamicStates = dyn;
    VkFormat colfmt = VK_FORMAT_R8G8B8A8_UNORM;
    VkPipelineRenderingCreateInfo prc = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO };
    prc.colorAttachmentCount = 1; prc.pColorAttachmentFormats = &colfmt;
    VkGraphicsPipelineCreateInfo gpci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    gpci.pNext = &prc; gpci.stageCount = 2; gpci.pStages = stages;
    gpci.pVertexInputState = &vi; gpci.pInputAssemblyState = &ia; gpci.pViewportState = &vps;
    gpci.pRasterizationState = &rs; gpci.pMultisampleState = &ms; gpci.pColorBlendState = &cb;
    gpci.pDynamicState = &ds; gpci.layout = layout;
    VkPipeline pipe; VK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &pipe));

    /* The attribute-fetch pipeline: same everything, but positions come from
     * binding 0 at the D3D9-ish stride instead of a shader-side array. */
    VkPipelineShaderStageCreateInfo stagesA[2] = {
        { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, 0, 0, VK_SHADER_STAGE_VERTEX_BIT,   module(quad_attr_vert_spv, sizeof(quad_attr_vert_spv)), "main", NULL },
        stages[1],
    };
    VkVertexInputBindingDescription vbind = { 0, STRIDE, VK_VERTEX_INPUT_RATE_VERTEX };
    VkVertexInputAttributeDescription vattr = { 0, 0, VK_FORMAT_R32G32_SFLOAT, 0 };
    VkPipelineVertexInputStateCreateInfo viA = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    viA.vertexBindingDescriptionCount = 1; viA.pVertexBindingDescriptions = &vbind;
    viA.vertexAttributeDescriptionCount = 1; viA.pVertexAttributeDescriptions = &vattr;
    VkGraphicsPipelineCreateInfo gpciA = gpci;
    gpciA.pStages = stagesA; gpciA.pVertexInputState = &viA;
    VkPipeline pipeA; VK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpciA, NULL, &pipeA));

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
        { "attr   strip4 vb=0 fv=0   ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1, 1, 0, 0 },
        { "attr   strip4 vb=0 fv=4   ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1, 1, 0, 4 },
        { "attr   strip4 vb=228 fv=0 ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1, 1, 8 * STRIDE + 4, 0 },
        { "attr   idx16@2 vo=4       ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  0, 6, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE,  2, 1, 0, 4 },
        { "attr   idx16@18 vo=4 cull ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  0, 6, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE, 18, 1, 0, 4 },
        /* TRIANGLE_FAN: not in core Vulkan, but our DXVK passes D3DPT_TRIANGLEFAN
         * through as this topology verbatim (d3d9_util.cpp), and KosmicKrisp
         * emulates fans on a helper command queue (LunarG XDC 2025) -- the one
         * path the matrix above cannot reach and the D3D9 way to draw the very
         * 2D quads (video, loading screens) that show the artifact in-game.
         * Vertex order TL,BL,TR,BR as a fan = T1 upper-left, T2 lower-right. */
        { "FAN4   bowtie cull=NONE   ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,   0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        { "FANP   perim  cull=NONE   ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,  10, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        { "FANP   perim  cull=BACK CCW", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN, 10, 4, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        { "FANP   perim  cull=BACK CW ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN, 10, 4, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_CLOCKWISE, -1 },
    };
    enum { NCFG = sizeof(cfgs) / sizeof(cfgs[0]) };
    int results[NCFG][2];  /* [cfg][probe]: 1=red 0=black */
    int failures = 0;

    for (int i = 0; i < NCFG; i++) {
        VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        cbbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        VK(vkBeginCommandBuffer(cmd, &cbbi));
        begin_color_pass(cmd, img, view, ivci.subresourceRange, sc);
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, cfgs[i].attr ? pipeA : pipe);
        vkCmdSetViewport(cmd, 0, 1, &vp);
        vkCmdSetScissor(cmd, 0, 1, &sc);
        vkCmdSetPrimitiveTopology(cmd, cfgs[i].topo);
        vkCmdSetCullMode(cmd, cfgs[i].cull);
        vkCmdSetFrontFace(cmd, cfgs[i].front);
        if (cfgs[i].attr) {
            VkDeviceSize off = cfgs[i].vb_off;
            vkCmdBindVertexBuffers(cmd, 0, 1, &vbuf, &off);
        }
        else
            vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 4, &cfgs[i].base);
        if (cfgs[i].indexed >= 0) {
            vkCmdBindIndexBuffer(cmd, ibuf, cfgs[i].indexed, VK_INDEX_TYPE_UINT16);
            vkCmdDrawIndexed(cmd, cfgs[i].count, 1, 0, cfgs[i].first, 0);
        }
        else
            vkCmdDraw(cmd, cfgs[i].count, 1, cfgs[i].first, 0);
        end_color_pass(cmd, img, ivci.subresourceRange, buf);
        VK(vkEndCommandBuffer(cmd));

        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
        si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
        VK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
        VK(vkQueueWaitIdle(queue));

        unsigned char *px;
        VK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&px));
        probe_pixels(px, &results[i][0], &results[i][1]);
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
    /* Perimeter-order fan: uniform winding, so cull must keep or drop BOTH.
     * A split here is the game artifact on the exact topology DXVK emits. */
    {
        int a = NCFG - 3, b = NCFG - 2, c = NCFG - 1;
        if (results[a][0] != results[a][1] || results[b][0] != results[b][1] || results[c][0] != results[c][1]) {
            printf("FAIL  uniform-winding FAN splits under cull -- fan emulation winding bug\n");
            failures++;
        }
        if (results[b][0] == results[c][0] && results[b][1] == results[c][1]) {
            printf("FAIL  frontFace has no effect on fan+cull\n");
            failures++;
        }
    }
    for (int i = 6; i < NCFG - 3; i++) {
        if (results[i][0] != results[i][1]) {
            printf("FAIL  %s drops one triangle (the game artifact)\n", cfgs[i].name);
            failures++;
        } else if (!results[i][0] && cfgs[i].cull == VK_CULL_MODE_NONE) {
            printf("FAIL  %s drew nothing\n", cfgs[i].name);
            failures++;
        }
    }

    /* Stress phase: the single-shot matrix above waits the queue idle around
     * every draw, which hides exactly the class the artifact needs -- frames
     * in flight. This phase replays the presentation blit's shape: a
     * 6-vertex triangle LIST whose vertex data the CPU writes IMMEDIATELY
     * before the draw, into host-visible memory, every single frame
     * (vk_meta_draw_rects feeding kk_CmdBlitImage2 feeding every present).
     * The content ALTERNATES -- even frames a full quad, odd frames only the
     * lower-right triangle -- at a rotating buffer offset, with two frames
     * in flight and per-frame readback, the cadence of a real swapchain
     * during video playback. A coherency or residency lapse makes the GPU
     * read the OTHER parity's data, and the full-quad frame loses exactly
     * one triangle. */
    {
        enum { FRAMES = 400, INFLIGHT = 2 };
        VkCommandBuffer cmds[INFLIGHT];
        VkFence fences[INFLIGHT];
        VkBuffer rb[INFLIGHT];
        VkDeviceMemory rbmem[INFLIGHT];
        unsigned char *rbmap[INFLIGHT];
        VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
        ai.commandPool = pool; ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ai.commandBufferCount = INFLIGHT;
        VK(vkAllocateCommandBuffers(dev, &ai, cmds));
        for (int f = 0; f < INFLIGHT; f++) {
            VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, VK_FENCE_CREATE_SIGNALED_BIT };
            VK(vkCreateFence(dev, &fci, NULL, &fences[f]));
            rb[f] = make_buffer(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                &rbmem[f]);
            VK(vkMapMemory(dev, rbmem[f], 0, VK_WHOLE_SIZE, 0, (void **)&rbmap[f]));
        }
        int bad = 0, first_bad = -1;
        for (int frame = 0; frame < FRAMES; frame++) {
            int f = frame % INFLIGHT;
            VK(vkWaitForFences(dev, 1, &fences[f], VK_TRUE, UINT64_MAX));
            /* Check the frame that just completed on this slot. */
            if (frame >= INFLIGHT) {
                int ul, lr;
                probe_pixels(rbmap[f], &ul, &lr);
                /* Completed slot ran frame `frame - INFLIGHT` (same parity,
                 * INFLIGHT == 2): even = full quad, both probes red; odd =
                 * lower-right triangle only. A parity mismatch means the GPU
                 * consumed the OTHER frame's vertex bytes. */
                int cf = frame - INFLIGHT;
                int full = !(cf & 1);
                if (full ? (ul != lr || !ul) : (ul || !lr)) {
                    bad++; if (first_bad < 0) first_bad = cf;
                }
            }
            VK(vkResetFences(dev, 1, &fences[f]));
            VK(vkResetCommandBuffer(cmds[f], 0));
            VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
            bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            VK(vkBeginCommandBuffer(cmds[f], &bi));
            begin_color_pass(cmds[f], img, view, ivci.subresourceRange, sc);
            {
                int slot = frame & 1;
                VkDeviceSize off = STRIDE * 12 + 4 + slot * 1024;
                unsigned char *dst = vtx_map + off;
                static const float fullq[6][2] = {
                    {-1,-1},{-1,1},{1,-1},  {1,-1},{-1,1},{1,1} };
                static const float halfq[6][2] = {
                    {-1,1},{1,1},{1,-1},    {1,-1},{1,1},{1,-1} }; /* LR tri, T2 degenerate */
                const float (*src)[2] = slot ? halfq : fullq;
                for (int v = 0; v < 6; v++)
                    memcpy(dst + v * STRIDE, src[v], 8);
                vkCmdBindPipeline(cmds[f], VK_PIPELINE_BIND_POINT_GRAPHICS, pipeA);
                vkCmdSetViewport(cmds[f], 0, 1, &vp);
                vkCmdSetScissor(cmds[f], 0, 1, &sc);
                vkCmdSetPrimitiveTopology(cmds[f], VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
                vkCmdBindVertexBuffers(cmds[f], 0, 1, &vbuf, &off);
                vkCmdDraw(cmds[f], 6, 1, 0, 0);
            }
            end_color_pass(cmds[f], img, ivci.subresourceRange, rb[f]);
            VK(vkEndCommandBuffer(cmds[f]));
            VkSubmitInfo s2 = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
            s2.commandBufferCount = 1; s2.pCommandBuffers = &cmds[f];
            VK(vkQueueSubmit(queue, 1, &s2, fences[f]));
        }
        VK(vkQueueWaitIdle(queue));
        if (bad) {
            printf("FAIL  blit-shape stress: %d/%d in-flight frames lost a triangle (first at frame %d)\n",
                   bad, FRAMES - INFLIGHT, first_bad);
            printf("      the GPU is consuming another in-flight frame's CPU-written vertex data\n");
            failures++;
        } else {
            printf("  blit-shape stress: %d frames, %d in flight -- all intact\n", FRAMES, INFLIGHT);
        }
    }

    printf("\n%d failed check(s)\n", failures);
    return failures;
}

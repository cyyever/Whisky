/* Probe SSFIV's missing-triangle artifact with no Wine, no D3D, no game:
 * a native x86_64 (Rosetta) process -> Vulkan loader -> KosmicKrisp -> Metal.
 *
 * OUTCOME: the artifact was primitive restart applied to a NON-indexed draw.
 * With no index buffer the unroll kernel reads vertex IDs, and the runtime's
 * restart index is 0 until an index buffer is first bound, so vertex 0 -- a
 * fan's hub -- read as a restart marker and a 4-vertex fan emitted one
 * triangle instead of two. Fixed in patches/mesa/0002; the restart pairs at
 * the end of the matrix are what caught it and now guard it.
 *
 * Everything else here came out negative and is kept as a regression guard:
 * strip winding is compensated before the cull test, non-4-aligned uint16
 * index offsets fetch the right indices, and the fan/strip unroll holds under
 * in-flight load. Run it after every KosmicKrisp bump.
 *
 * The in-game artifact: 2D fullscreen draws (loading screens, video) rendered
 * only the lower-right diagonal half -- one of a quad's two triangles
 * missing. The shape first suggested primitive assembly or face culling,
 * which is what the topology x cull x winding matrix below was built to test;
 * those all passed, and the answer turned out to be one rung further in, in
 * how the fan is decomposed.
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

/* Fan probes, strictly INSIDE one triangle of the quad each and clear of both
 * diagonals: (12,36) is inside only the fan's first triangle (v0,v1,v2),
 * (52,36) only the second (v0,v2,v3). The generic probes sit exactly ON the
 * quad's main diagonal, where a single triangle's edge fill can light BOTH --
 * useless for telling "one triangle missing" from "both drawn". */
static void fan_probe(const unsigned char *px, int *t1, int *t2) {
    *t1 = px[(36 * W + 12) * 4] > 128;
    *t2 = px[(36 * W + 52) * 4] > 128;
}

/* One offscreen render target: image + backing memory + view. The stress
 * phases need one PER FRAME IN FLIGHT. Sharing a single image across them
 * would be a write-after-read hazard -- begin_color_pass's acquire barrier
 * uses TOP_OF_PIPE/no src access, so it orders against nothing, and the next
 * frame's clear could land while the previous frame's copy-out is still
 * reading. A frame reading its neighbour's geometry would then be blamed on
 * the shared unroll heap, which is the one thing these phases exist to
 * measure. Separate targets remove the hazard without a barrier, which would
 * serialize the frames and destroy the overlap the phases depend on. */
struct rt { VkImage img; VkDeviceMemory mem; VkImageView view; };

/* Every image here is a single-level, single-layer colour target. */
static const VkImageSubresourceRange COLOR_RANGE = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };

#define TRY(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) return r_; } while (0)
static VkResult make_rt(struct rt *r) {
    VkImageCreateInfo ici = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    ici.imageType = VK_IMAGE_TYPE_2D; ici.format = VK_FORMAT_R8G8B8A8_UNORM;
    ici.extent = (VkExtent3D){ W, H, 1 }; ici.mipLevels = 1; ici.arrayLayers = 1;
    ici.samples = VK_SAMPLE_COUNT_1_BIT; ici.tiling = VK_IMAGE_TILING_OPTIMAL;
    ici.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    TRY(vkCreateImage(dev, &ici, NULL, &r->img));
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, r->img, &mr);
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    TRY(vkAllocateMemory(dev, &mai, NULL, &r->mem));
    TRY(vkBindImageMemory(dev, r->img, r->mem, 0));
    VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    vci.image = r->img; vci.viewType = VK_IMAGE_VIEW_TYPE_2D; vci.format = ici.format;
    vci.subresourceRange = COLOR_RANGE;
    TRY(vkCreateImageView(dev, &vci, NULL, &r->view));
    return VK_SUCCESS;
}
#undef TRY

static void free_rt(struct rt r) {
    vkDestroyImageView(dev, r.view, NULL);
    vkDestroyImage(dev, r.img, NULL);
    vkFreeMemory(dev, r.mem, NULL);
}

/* Every dynamic state this file's pipelines declare, set together. Recording a
 * command buffer that leaves one undefined is not a crash but a silent lie:
 * with restart coming out VK_TRUE, requires_unroll_index_promotion() returns
 * false and the uint16 strips take the native Metal path, so the unroll stress
 * reports "all intact" having exercised no unroll at all. One call site means
 * the next phase added here cannot reintroduce that. */
static void bind_probe_state(VkCommandBuffer cmd, VkViewport vp, VkRect2D sc,
                             VkPrimitiveTopology topo, VkCullModeFlags cull,
                             VkFrontFace front, VkBool32 restart) {
    vkCmdSetViewport(cmd, 0, 1, &vp);
    vkCmdSetScissor(cmd, 0, 1, &sc);
    vkCmdSetPrimitiveTopology(cmd, topo);
    vkCmdSetCullMode(cmd, cull);
    vkCmdSetFrontFace(cmd, front);
    vkCmdSetPrimitiveRestartEnable(cmd, restart);
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
    int restart;                    /* primitiveRestartEnable (ignored on non-indexed draws) */
    int fanprobe;                   /* read the strict-interior probes, not the diagonal pair */
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
    VkPhysicalDeviceExtendedDynamicState2FeaturesEXT eds2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT };
    eds2.extendedDynamicState2 = VK_TRUE; eds2.pNext = &f13;
    VkPhysicalDeviceExtendedDynamicStateFeaturesEXT eds = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT };
    eds.extendedDynamicState = VK_TRUE; eds.pNext = &eds2;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.pNext = &eds; dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci;
    VK(vkCreateDevice(phys, &dci, NULL, &dev));
    vkGetDeviceQueue(dev, qfam, 0, &queue);

    /* The single-shot target. Per-frame ones come from the same helper. */
    struct rt main_rt; VK(make_rt(&main_rt));
    VkImage img = main_rt.img;
    VkImageView view = main_rt.view;

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

    /* Fan-stress index buffer: [0,1,2,3] selects the full-quad fan at
     * FANV_OFF slots 0-3, [4,5,6,7] the lower-right-only fan at slots 4-7.
     * uint16 indices with restart disabled is exactly the shape that sends a
     * TRIANGLE_FAN through KosmicKrisp's kk_unroll_geometry. */
    static const uint16_t fan_idx[20] = { 0,1,2,3, 4,5,6,7, 8,9,10,11, 12,13,14,15, 16,17,18,19 };
    VkDeviceMemory fanmem;
    VkBuffer fanibuf = make_buffer(sizeof(fan_idx), VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                                   VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                   &fanmem);
    { void *ip; VK(vkMapMemory(dev, fanmem, 0, VK_WHOLE_SIZE, 0, &ip));
      memcpy(ip, fan_idx, sizeof(fan_idx)); vkUnmapMemory(dev, fanmem); }

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
    /* Fan-stress vertices sit past the blit-shape phase's rotating region
     * (STRIDE*12+4 + 2*1024 bytes) so nothing per-frame rewrites them. */
    #define FANV_OFF (STRIDE * 12 + 4 + 2048 + 256)
    unsigned char vtx_data[FANV_OFF + 20 * STRIDE];
    memset(vtx_data, 0x77, sizeof(vtx_data));
    {
        static const float quad_pos[4][2] = { {-1,-1}, {-1,1}, {1,-1}, {1,1} };
        for (int v = 0; v < 4; v++) {
            memcpy(vtx_data + v * STRIDE,           quad_pos[v], 8);
            memcpy(vtx_data + (4 + v) * STRIDE,     quad_pos[v], 8);
            memcpy(vtx_data + 8 * STRIDE + 4 + v * STRIDE, quad_pos[v], 8);
        }
        /* Fan-unroll variants, four vertices each: the bowtie quad (strip
         * order as a fan -- two triangles of opposite winding), a real
         * perimeter-order quad, first triangle collapsed (T2 only), second
         * collapsed (T1 only), and all vertices off-screen (nothing draws).
         * The stress below alternates perimeter-full vs T2-only so the two
         * in-flight command buffers unroll DIFFERENT index content. */
        static const float fan_perim[4][2] = { {-1,-1}, {1,-1}, {1,1}, {-1,1} };
        static const float fan_lr[4][2] = { {-1,-1}, {-1,-1}, {1,-1}, {1,1} };
        static const float fan_ul[4][2] = { {-1,-1}, {-1,1}, {1,-1}, {1,-1} };
        /* Genuinely off-screen: every coordinate >= 5, so no triangle crosses
         * the viewport (unlike +-90, which spans NDC and COVERS it). */
        static const float fan_off[4][2] = { {5,5}, {6,5}, {5,6}, {6,6} };
        for (int v = 0; v < 4; v++) {
            memcpy(vtx_data + FANV_OFF + v * STRIDE,          quad_pos[v], 8);
            memcpy(vtx_data + FANV_OFF + (4 + v) * STRIDE,    fan_lr[v], 8);
            memcpy(vtx_data + FANV_OFF + (8 + v) * STRIDE,    fan_ul[v], 8);
            memcpy(vtx_data + FANV_OFF + (12 + v) * STRIDE,   fan_off[v], 8);
            memcpy(vtx_data + FANV_OFF + (16 + v) * STRIDE,   fan_perim[v], 8);
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
                             VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR,
                             VK_DYNAMIC_STATE_PRIMITIVE_RESTART_ENABLE };
    VkPipelineDynamicStateCreateInfo ds = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO };
    ds.dynamicStateCount = sizeof(dyn) / sizeof(dyn[0]); ds.pDynamicStates = dyn;
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

    /* Config ids. Used as designated-initializer indices below, so a row and
     * its name cannot drift apart: inserting or reordering rows is inert, and
     * a verdict naming a config always reads that config. The earlier scheme
     * addressed rows by distance from the end of the table, which silently
     * retargeted every verdict whenever the table grew. */
    enum {
        CFG_LIST6_NONE, CFG_STRIP4_NONE, CFG_STRIP4_BACK_CCW, CFG_STRIP4_BACK_CW,
        CFG_LIST6_BACK_CCW, CFG_LIST6_BACK_CW,
        CFG_IDX16_2_NONE, CFG_IDX16_18_NONE, CFG_IDX16_2_BACK,
        CFG_ATTR_VB0_FV0, CFG_ATTR_VB0_FV4, CFG_ATTR_VB228, CFG_ATTR_IDX2_VO4,
        CFG_ATTR_IDX18_VO4_CULL,
        CFG_FAN4_BOWTIE, FAN_NONE, FAN_CCW, FAN_CW,
        RST_ON, RST_OFF, RST_CULL_ON, RST_CULL_OFF, RST_STRIP_ON, RST_STRIP_OFF,
        NCFG
    };

    struct config cfgs[NCFG] = {
        [CFG_LIST6_NONE] = { "list6  cull=NONE          ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  4, 6, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        [CFG_STRIP4_NONE] = { "strip4 cull=NONE          ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        [CFG_STRIP4_BACK_CCW] = { "strip4 cull=BACK front=CCW", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        [CFG_STRIP4_BACK_CW] = { "strip4 cull=BACK front=CW ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_CLOCKWISE, -1 },
        [CFG_LIST6_BACK_CCW] = { "list6  cull=BACK front=CCW", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  4, 6, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        [CFG_LIST6_BACK_CW] = { "list6  cull=BACK front=CW ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  4, 6, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_CLOCKWISE, -1 },
        [CFG_IDX16_2_NONE] = { "idx16  offset=2  cull=NONE", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  0, 6, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, 2 },
        [CFG_IDX16_18_NONE] = { "idx16  offset=18 cull=NONE", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  0, 6, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, 18 },
        [CFG_IDX16_2_BACK] = { "idx16  offset=2  cull=BACK", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  0, 6, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE, 2 },
        [CFG_ATTR_VB0_FV0] = { "attr   strip4 vb=0 fv=0   ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1, 1, 0, 0 },
        [CFG_ATTR_VB0_FV4] = { "attr   strip4 vb=0 fv=4   ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1, 1, 0, 4 },
        [CFG_ATTR_VB228] = { "attr   strip4 vb=228 fv=0 ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1, 1, 8 * STRIDE + 4, 0 },
        [CFG_ATTR_IDX2_VO4] = { "attr   idx16@2 vo=4       ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  0, 6, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE,  2, 1, 0, 4 },
        [CFG_ATTR_IDX18_VO4_CULL] = { "attr   idx16@18 vo=4 cull ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,  0, 6, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE, 18, 1, 0, 4 },
        /* TRIANGLE_FAN: not in core Vulkan, but our DXVK passes D3DPT_TRIANGLEFAN
         * through as this topology verbatim (d3d9_util.cpp), and KosmicKrisp
         * emulates fans on a helper command queue (LunarG XDC 2025) -- the one
         * path the matrix above cannot reach and the D3D9 way to draw the very
         * 2D quads (video, loading screens) that show the artifact in-game.
         * Vertex order TL,BL,TR,BR as a fan = T1 upper-left, T2 lower-right. */
        [CFG_FAN4_BOWTIE] = { "FAN4   bowtie cull=NONE   ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,   0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        [FAN_NONE] = { "FANP   perim  cull=NONE   ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,  10, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        [FAN_CCW] = { "FANP   perim  cull=BACK CCW", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN, 10, 4, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
        [FAN_CW] = { "FANP   perim  cull=BACK CW ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN, 10, 4, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_CLOCKWISE, -1 },
        /* primitiveRestartEnable on a NON-indexed draw. The Vulkan spec confines
         * primitive restart to indexed draws ("This enable only applies to
         * indexed draws"), so all four of these must render the full quad --
         * the flag is required to be inert here. SSFIV reaches this state on
         * 1623 of its fullscreen 2D quads: DXVK leaves restart enabled, and with
         * no index buffer bound the runtime's restart index is still 0, so a
         * driver that feeds vertex IDs through its restart comparison sees
         * vertex 0 -- the fan's hub -- as a restart marker and emits one
         * triangle instead of two. Probed strictly inside each triangle
         * (fanprobe), since the generic pair sits on the diagonal the artifact
         * cuts along and cannot tell "one triangle" from "two". */
        [RST_ON] = { "FANP   perim  restart=ON  ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,  10, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1, .restart = 1, .fanprobe = 1 },
        [RST_OFF] = { "FANP   perim  restart=OFF ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,  10, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1, .fanprobe = 1 },
        [RST_CULL_ON] = { "FANP   cullCW restart=ON  ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,  10, 4, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_CLOCKWISE,         -1, .restart = 1, .fanprobe = 1 },
        [RST_CULL_OFF] = { "FANP   cullCW restart=OFF ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN,  10, 4, VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_CLOCKWISE,         -1, .fanprobe = 1 },
        [RST_STRIP_ON] = { "strip4 restart=ON         ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1, .restart = 1 },
        [RST_STRIP_OFF] = { "strip4 restart=OFF        ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, 0, 4, VK_CULL_MODE_NONE,     VK_FRONT_FACE_COUNTER_CLOCKWISE, -1 },
    };
    int results[NCFG][2];  /* [cfg][probe]: 1=red 0=black */
    int failures = 0;

    for (int i = 0; i < NCFG; i++) {
        VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        cbbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        VK(vkBeginCommandBuffer(cmd, &cbbi));
        begin_color_pass(cmd, img, view, COLOR_RANGE, sc);
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, cfgs[i].attr ? pipeA : pipe);
        bind_probe_state(cmd, vp, sc, cfgs[i].topo, cfgs[i].cull, cfgs[i].front,
                         cfgs[i].restart ? VK_TRUE : VK_FALSE);
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
        end_color_pass(cmd, img, COLOR_RANGE, buf);
        VK(vkEndCommandBuffer(cmd));

        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
        si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
        VK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
        VK(vkQueueWaitIdle(queue));

        unsigned char *px;
        VK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&px));
        if (cfgs[i].fanprobe)
            fan_probe(px, &results[i][0], &results[i][1]);
        else
            probe_pixels(px, &results[i][0], &results[i][1]);
        vkUnmapMemory(dev, bmem);
        printf("  %s UL=%s LR=%s\n", cfgs[i].name,
               results[i][0] ? "red  " : "BLACK", results[i][1] ? "red  " : "BLACK");
        VK(vkResetCommandBuffer(cmd, 0));
    }

    /* Verdicts. */
    if (!(results[CFG_LIST6_NONE][0] && results[CFG_LIST6_NONE][1])) { printf("FAIL  baseline list draw is broken\n"); failures++; }
    if (results[CFG_STRIP4_NONE][0] != results[CFG_STRIP4_NONE][1])    { printf("FAIL  strip w/o cull drops a triangle -- assembly bug\n"); failures++; }
    else if (!results[CFG_STRIP4_NONE][0])               { printf("FAIL  strip w/o cull drew nothing\n"); failures++; }
    if (results[CFG_STRIP4_BACK_CCW][0] != results[CFG_STRIP4_BACK_CCW][1] ||
        results[CFG_STRIP4_BACK_CW][0] != results[CFG_STRIP4_BACK_CW][1]) {
        printf("FAIL  strip+cull culls only ONE of the two triangles -- the game artifact:\n");
        printf("      strip winding is not being compensated before the cull test\n");
        failures++;
    }
    if (results[CFG_STRIP4_BACK_CCW][0] == results[CFG_STRIP4_BACK_CW][0] &&
        results[CFG_STRIP4_BACK_CCW][1] == results[CFG_STRIP4_BACK_CW][1]) {
        printf("FAIL  frontFace has no effect on strip+cull\n"); failures++;
    }
    if (results[CFG_LIST6_BACK_CCW][0] != results[CFG_LIST6_BACK_CCW][1] ||
        results[CFG_LIST6_BACK_CW][0] != results[CFG_LIST6_BACK_CW][1]) {
        printf("FAIL  list+cull splits a uniform-winding quad\n"); failures++;
    }
    if (results[CFG_LIST6_BACK_CCW][0] == results[CFG_LIST6_BACK_CW][0]) {
        printf("FAIL  frontFace has no effect on list+cull\n"); failures++;
    }

    /* Perimeter-order fan: uniform winding, so cull must keep or drop BOTH.
     * A split here is the game artifact on the exact topology DXVK emits. */
    {
        int a = FAN_NONE, b = FAN_CCW, c = FAN_CW;
        if (results[a][0] != results[a][1] || results[b][0] != results[b][1] || results[c][0] != results[c][1]) {
            printf("FAIL  uniform-winding FAN splits under cull -- fan emulation winding bug\n");
            failures++;
        }
        if (results[b][0] == results[c][0] && results[b][1] == results[c][1]) {
            printf("FAIL  frontFace has no effect on fan+cull\n");
            failures++;
        }
    }

    /* primitiveRestartEnable must not change a NON-indexed draw at all: the
     * spec scopes primitive restart to indexed draws. Any of these losing a
     * triangle is the SSFIV artifact, reproduced without Wine or D3D. */
    {
        /* Each restart=ON config paired with its twin: the same draw, same
         * probe pixels, differing only in the flag. Equal results is the whole
         * requirement. Comparing against a twin rather than against "must be
         * lit" keeps the pair whose correct answer is an empty image
         * (back-face culled) honest, and pairing only same-probe configs keeps
         * an unrelated fan regression from being reported as a restart bug --
         * the diagonal probes and the strict-interior probes disagree about a
         * half-quad by construction. */
        struct { int on, off; } pairs[] = {
            { RST_ON,       RST_OFF },       /* perim fan, cull NONE    */
            { RST_CULL_ON,  RST_CULL_OFF },  /* perim fan, cull BACK/CW */
            { RST_STRIP_ON, RST_STRIP_OFF }, /* strip4,    cull NONE    */
        };
        for (unsigned k = 0; k < sizeof(pairs) / sizeof(pairs[0]); k++) {
            int on = pairs[k].on, off = pairs[k].off;
            if (results[on][0] != results[off][0] || results[on][1] != results[off][1]) {
                printf("FAIL  %s differs from the same draw with restart OFF\n"
                       "      (%s%s vs %s%s) -- primitive restart is being applied to a\n"
                       "      non-indexed draw, so vertex ID 0 reads as the restart index\n",
                       cfgs[on].name,
                       results[on][0] ? "red " : "BLACK", results[on][1] ? "/red " : "/BLACK",
                       results[off][0] ? "red " : "BLACK", results[off][1] ? "/red " : "/BLACK");
                failures++;
            }
        }
        /* The twins are only a reference if the reference itself is right:
         * (RST_CULL_OFF is excluded -- its correct result is an empty image.)
         * assert the restart-off perimeter fan covers BOTH triangles, read
         * with the strict-interior probes (the matrix's diagonal pair cannot
         * see a missing half). Without this, a fan that lost a triangle
         * however the flag is set would pass every pair above. */
        int refs[] = { RST_OFF, RST_STRIP_OFF };
        for (unsigned k = 0; k < sizeof(refs) / sizeof(refs[0]); k++) {
            if (!results[refs[k]][0] || !results[refs[k]][1]) {
                printf("FAIL  %s does not cover both triangles -- the pair above is\n"
                       "      comparing two dead configs, not measuring restart\n",
                       cfgs[refs[k]].name);
                failures++;
            }
        }
    }
    /* Sweep the middle configs; the perimeter-fan and restart blocks above own
     * their own verdicts (theirs include cases whose correct result is empty). */
    for (int i = CFG_IDX16_2_NONE; i <= CFG_FAN4_BOWTIE; i++) {
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
        struct rt rts[INFLIGHT];   /* one target per frame: see make_rt */
        VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
        ai.commandPool = pool; ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ai.commandBufferCount = INFLIGHT;
        VK(vkAllocateCommandBuffers(dev, &ai, cmds));
        for (int f = 0; f < INFLIGHT; f++) {
            VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, VK_FENCE_CREATE_SIGNALED_BIT };
            VK(vkCreateFence(dev, &fci, NULL, &fences[f]));
            VK(make_rt(&rts[f]));
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
            begin_color_pass(cmds[f], rts[f].img, rts[f].view, COLOR_RANGE, sc);
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
                bind_probe_state(cmds[f], vp, sc,
                                 VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                                 VK_CULL_MODE_NONE,
                                 VK_FRONT_FACE_COUNTER_CLOCKWISE, VK_FALSE);
                vkCmdBindVertexBuffers(cmds[f], 0, 1, &vbuf, &off);
                vkCmdDraw(cmds[f], 6, 1, 0, 0);
            }
            end_color_pass(cmds[f], rts[f].img, COLOR_RANGE, rb[f]);
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
        for (int f = 0; f < INFLIGHT; f++) {
            vkUnmapMemory(dev, rbmem[f]);
            vkDestroyBuffer(dev, rb[f], NULL);
            vkFreeMemory(dev, rbmem[f], NULL);
            vkDestroyFence(dev, fences[f], NULL);
            free_rt(rts[f]);
        }
        vkFreeCommandBuffers(dev, pool, INFLIGHT, cmds);
    }

    /* Fan-unroll stress: same in-flight cadence as above, but the draws are
     * indexed uint16 TRIANGLE_FANs -- the game's 2D quads. KosmicKrisp has no
     * Metal fan primitive and restart-promotes these through
     * kk_unroll_geometry, which writes the decomposed index stream into a
     * DEVICE-GLOBAL 128MB heap and zeroes that heap's allocation pointer at
     * the START of every command buffer using it (kk_heap). Two command
     * buffers in flight therefore allocate the SAME region and the later
     * unroll overwrites the earlier frame's indices before its draws consume
     * them -- Metal orders command buffers' submission, not their completion.
     * The two frames unroll DIFFERENT index content (full quad vs
     * lower-right-only) so aliasing shows up as a parity violation, and
     * unlike the phase above every buffer here is STATIC -- nothing is
     * rewritten per frame, so no other mechanism can produce a wrong frame.
     * DRAWS unrolled fan draws per frame approximates the game's unroll churn
     * (loading screens log thousands) and leaves the tail draws -- the ones a
     * following command buffer's reset can reach -- as the last thing
     * rendered, where the readback probes them. */
    {
        /* 2000 unroll kernel launches per frame is real GPU work (~ms), the
         * backlog under which a following command buffer could begin while
         * this one still executes. */
        enum { FRAMES = 400, INFLIGHT = 2, DRAWS = 2000 };
        static const struct { const char *name; VkPrimitiveTopology topo; } topologies[] = {
            { "fan  ", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN },
            { "strip", VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP },
        };
        for (int t = 0; t < 2; t++) {
        VkCommandBuffer cmds[INFLIGHT];
        VkFence fences[INFLIGHT];
        VkBuffer rb[INFLIGHT];
        VkDeviceMemory rbmem[INFLIGHT];
        unsigned char *rbmap[INFLIGHT];
        struct rt rts[INFLIGHT];   /* one target per frame: see make_rt */
        VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
        ai.commandPool = pool; ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ai.commandBufferCount = INFLIGHT;
        VK(vkAllocateCommandBuffers(dev, &ai, cmds));
        for (int f = 0; f < INFLIGHT; f++) {
            VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, VK_FENCE_CREATE_SIGNALED_BIT };
            VK(vkCreateFence(dev, &fci, NULL, &fences[f]));
            VK(make_rt(&rts[f]));
            rb[f] = make_buffer(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                &rbmem[f]);
            VK(vkMapMemory(dev, rbmem[f], 0, VK_WHOLE_SIZE, 0, (void **)&rbmap[f]));
        }
        int bad = 0, first_bad = -1;
        /* Calibration: the two stress parities plus diagnostics, single-shot
         * at queue-idle. If a variant does not read its expected probes here,
         * the stress verdict below measures a broken config, not cross-frame
         * aliasing. Same data as both topologies: strip order (v0..v3) tiles
         * the quad as T1={x+y<=64}/T2={x+y>=64}; fan perimeter order tiles it
         * as T1/T2 by the other diagonal; fan_lr kills T1 under FAN and the
         * first strip triangle under STRIP, leaving exactly T2 either way. */
        static const struct { const char *name; int off, eul, elr; } variants[] = {
            { "quad    ", 16, 1, 1 },   /* perim order: full quad as a fan */
            { "T2-only ", 4,  0, 1 },
            { "T1-only ", 8,  1, 0 },
            { "offscrn ", 12, 0, 0 },
            { "bowtie  ", 0,  1, 1 },   /* quad_pos: full quad as a strip */
        };
        /* Which vertex order tiles the quad depends on the topology: fans
         * want perimeter order, strips want the strip order (quad_pos). */
        int quad_off = t == 0 ? 16 : 0;
        int vari_ok = 1;
        for (int v = 0; v < 5; v++) {
            /* The bowtie vertex order only forms a quad as a fan; under strip
             * it is the same tiling as the strip order. The off-screen points
             * draw nothing under either. Expected values hold for both. */
            VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
            bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            VK(vkBeginCommandBuffer(cmd, &bi));
            begin_color_pass(cmd, img, view, COLOR_RANGE, sc);
            {
                VkDeviceSize voff = FANV_OFF;
                vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeA);
                bind_probe_state(cmd, vp, sc, topologies[t].topo,
                                 VK_CULL_MODE_NONE,
                                 VK_FRONT_FACE_COUNTER_CLOCKWISE, VK_FALSE);
                vkCmdBindVertexBuffers(cmd, 0, 1, &vbuf, &voff);
                vkCmdBindIndexBuffer(cmd, fanibuf,
                                     (variants[v].off == 16 ? quad_off : variants[v].off)
                                        * sizeof(uint16_t), VK_INDEX_TYPE_UINT16);
                for (int d = 0; d < DRAWS; d++)
                    vkCmdDrawIndexed(cmd, 4, 1, 0, 0, 0);
            }
            end_color_pass(cmd, img, COLOR_RANGE, buf);
            VK(vkEndCommandBuffer(cmd));
            VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
            si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
            VK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
            VK(vkQueueWaitIdle(queue));
            unsigned char *px;
            VK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&px));
            int ul, lr;
            fan_probe(px, &ul, &lr);
            printf("  %s calib %s: T1=%s T2=%s\n", topologies[t].name, variants[v].name,
                   ul ? "red  " : "BLACK", lr ? "red  " : "BLACK");
            if (ul != variants[v].eul || lr != variants[v].elr) {
                vari_ok = 0;
                /* What actually rendered: one char per 2x2 px block. */
                for (int y = 0; y < H; y += 2) {
                    printf("       ");
                    for (int x = 0; x < W; x += 2)
                        putchar(px[(y * W + x) * 4] > 128 ? '#' : '.');
                    putchar('\n');
                }
            }
            vkUnmapMemory(dev, bmem);
            VK(vkResetCommandBuffer(cmd, 0));
        }
        if (!vari_ok) {
            printf("FAIL  %s calib: a variant mismatched its expected probes -- fix the config before trusting the stress\n",
                   topologies[t].name);
            failures++;
        }
        for (int frame = 0; frame < FRAMES; frame++) {
            int f = frame % INFLIGHT;
            VK(vkWaitForFences(dev, 1, &fences[f], VK_TRUE, UINT64_MAX));
            /* Completed slot ran frame `frame - INFLIGHT` (same parity,
             * INFLIGHT == 2): even = full quad (both probes red), odd = the
             * T2 triangle only. The other parity's unrolled indices in the
             * shared heap produce exactly the opposite. */
            if (frame >= INFLIGHT) {
                int ul, lr;
                fan_probe(rbmap[f], &ul, &lr);
                int cf = frame - INFLIGHT;
                int full = !(cf & 1);
                if (full ? (ul != lr || !ul) : (ul || !lr)) {
                    bad++; if (first_bad < 0) first_bad = cf;
                    if (bad <= 5)
                        printf("       frame %d (%s): T1=%s T2=%s\n", cf,
                               full ? "quad" : "T2-only",
                               ul ? "red" : "BLACK", lr ? "red" : "BLACK");
                }
            }
            VK(vkResetFences(dev, 1, &fences[f]));
            VK(vkResetCommandBuffer(cmds[f], 0));
            VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
            bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            VK(vkBeginCommandBuffer(cmds[f], &bi));
            begin_color_pass(cmds[f], rts[f].img, rts[f].view, COLOR_RANGE, sc);
            {
                VkDeviceSize voff = FANV_OFF;
                vkCmdBindPipeline(cmds[f], VK_PIPELINE_BIND_POINT_GRAPHICS, pipeA);
                bind_probe_state(cmds[f], vp, sc, topologies[t].topo,
                                 VK_CULL_MODE_NONE,
                                 VK_FRONT_FACE_COUNTER_CLOCKWISE, VK_FALSE);
                vkCmdBindVertexBuffers(cmds[f], 0, 1, &vbuf, &voff);
                vkCmdBindIndexBuffer(cmds[f], fanibuf,
                                     (frame & 1 ? 4 : quad_off) * sizeof(uint16_t), VK_INDEX_TYPE_UINT16);
                for (int d = 0; d < DRAWS; d++)
                    vkCmdDrawIndexed(cmds[f], 4, 1, 0, 0, 0);
            }
            end_color_pass(cmds[f], rts[f].img, COLOR_RANGE, rb[f]);
            VK(vkEndCommandBuffer(cmds[f]));
            VkSubmitInfo s2 = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
            s2.commandBufferCount = 1; s2.pCommandBuffers = &cmds[f];
            VK(vkQueueSubmit(queue, 1, &s2, fences[f]));
        }
        VK(vkQueueWaitIdle(queue));
        if (bad) {
            printf("FAIL  %s unroll stress: %d/%d in-flight frames drew the OTHER frame's geometry (first at frame %d)\n",
                   topologies[t].name, bad, FRAMES - INFLIGHT, first_bad);
            printf("      the shared unroll heap is not safe across command buffers in flight\n");
            failures++;
        } else {
            printf("  %s unroll stress: %d frames x %d unrolled draws, %d in flight -- all intact\n",
                   topologies[t].name, FRAMES, DRAWS, INFLIGHT);
        }
        for (int f = 0; f < INFLIGHT; f++) {
            vkUnmapMemory(dev, rbmem[f]);
            vkDestroyBuffer(dev, rb[f], NULL);
            vkFreeMemory(dev, rbmem[f], NULL);
            vkDestroyFence(dev, fences[f], NULL);
            free_rt(rts[f]);
        }
        vkFreeCommandBuffers(dev, pool, INFLIGHT, cmds);
        }
    }

    printf("\n%d failed check(s)\n", failures);
    return failures;
}

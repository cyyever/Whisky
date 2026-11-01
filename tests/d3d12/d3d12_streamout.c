/* Headless D3D12 stream-output test. A VS writes one float4 per vertex,
 * computed from SV_VertexID. With no pixel shader and rasterization disabled,
 * two triangles' worth of vertices stream out to a buffer, and an SO
 * statistics query counts the primitives. It checks all 6 captured vertices,
 * BufferFilledSize, and the query.
 *
 * This is the path vkd3d-proton maps to VK_EXT_transform_feedback. KosmicKrisp
 * emulates that with a passthrough geometry shader (mesa!44928). The other
 * probes never bind an SO target, so only this one runs that code. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <string.h>

#define VERTS 6
#define STRIDE 16
#define FILLED_OFFSET 256 /* BufferFilledSize counter, after the vertex data */
#define CHECK(hr, msg) do { if (FAILED(hr)) { printf("%s: 0x%08lx\n", msg, (unsigned long)(hr)); return 1; } } while (0)

static const char *VS_SRC =
    "struct o { float4 pos : SV_Position; float4 data : TEXCOORD0; };\n"
    "o main(uint id : SV_VertexID) {\n"
    "    o r; r.pos = float4(0, 0, 0, 1);\n"
    "    r.data = float4(id, id * 2, id * 3, 7);\n"
    "    return r; }\n";

static ID3D12Resource *buffer(ID3D12Device *dev, D3D12_HEAP_TYPE type, UINT64 size,
                              D3D12_RESOURCE_STATES state)
{
    D3D12_HEAP_PROPERTIES hp = { type, 0, 0, 0, 0 };
    D3D12_RESOURCE_DESC rd = { 0 };
    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = size;
    rd.Height = 1; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ID3D12Resource *res = NULL;
    /* Committed resources are zero-initialized, so BufferFilledSize starts at 0. */
    if (FAILED(ID3D12Device_CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &rd, state,
            NULL, &IID_ID3D12Resource, (void **)&res)))
        return NULL;
    return res;
}

int main(void)
{
    ID3D12Device *dev = NULL;
    HRESULT hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    CHECK(hr, "D3D12CreateDevice");

    ID3DBlob *vs = NULL, *err = NULL;
    hr = D3DCompile(VS_SRC, strlen(VS_SRC), "vs", NULL, NULL, "main", "vs_5_0", 0, 0, &vs, &err);
    if (FAILED(hr)) {
        printf("D3DCompile: 0x%08lx %s\n", (unsigned long)hr,
               err ? (char *)ID3D10Blob_GetBufferPointer(err) : "");
        return 1;
    }

    D3D12_ROOT_SIGNATURE_DESC rsd = { 0 };
    rsd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_STREAM_OUTPUT;
    ID3DBlob *rsBlob = NULL;
    hr = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &rsBlob, &err);
    CHECK(hr, "SerializeRootSignature");
    ID3D12RootSignature *rootSig = NULL;
    hr = ID3D12Device_CreateRootSignature(dev, 0,
        ID3D10Blob_GetBufferPointer(rsBlob), ID3D10Blob_GetBufferSize(rsBlob),
        &IID_ID3D12RootSignature, (void **)&rootSig);
    CHECK(hr, "CreateRootSignature");

    D3D12_SO_DECLARATION_ENTRY so = { 0, "TEXCOORD", 0, 0, 4, 0 };
    UINT stride = STRIDE;
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pso = { 0 };
    pso.pRootSignature = rootSig;
    pso.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vs);
    pso.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vs);
    pso.StreamOutput.pSODeclaration = &so;
    pso.StreamOutput.NumEntries = 1;
    pso.StreamOutput.pBufferStrides = &stride;
    pso.StreamOutput.NumStrides = 1;
    pso.StreamOutput.RasterizedStream = D3D12_SO_NO_RASTERIZED_STREAM;
    pso.SampleMask = ~0u;
    pso.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pso.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pso.RasterizerState.DepthClipEnable = TRUE;
    pso.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pso.SampleDesc.Count = 1;
    ID3D12PipelineState *pipeline = NULL;
    hr = ID3D12Device_CreateGraphicsPipelineState(dev, &pso, &IID_ID3D12PipelineState, (void **)&pipeline);
    CHECK(hr, "CreateGraphicsPipelineState(stream output)");

    ID3D12Resource *soBuf = buffer(dev, D3D12_HEAP_TYPE_DEFAULT, FILLED_OFFSET + 16,
                                   D3D12_RESOURCE_STATE_STREAM_OUT);
    ID3D12Resource *readback = buffer(dev, D3D12_HEAP_TYPE_READBACK, FILLED_OFFSET + 16,
                                      D3D12_RESOURCE_STATE_COPY_DEST);
    ID3D12Resource *queryOut = buffer(dev, D3D12_HEAP_TYPE_READBACK,
                                      sizeof(D3D12_QUERY_DATA_SO_STATISTICS),
                                      D3D12_RESOURCE_STATE_COPY_DEST);
    if (!soBuf || !readback || !queryOut) { printf("CreateCommittedResource failed\n"); return 1; }

    D3D12_QUERY_HEAP_DESC qhd = { D3D12_QUERY_HEAP_TYPE_SO_STATISTICS, 1, 0 };
    ID3D12QueryHeap *qheap = NULL;
    hr = ID3D12Device_CreateQueryHeap(dev, &qhd, &IID_ID3D12QueryHeap, (void **)&qheap);
    CHECK(hr, "CreateQueryHeap(SO statistics)");

    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT, 0, 0, 0 };
    ID3D12CommandQueue *q = NULL;
    hr = ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&q);
    CHECK(hr, "CreateCommandQueue");
    ID3D12CommandAllocator *alloc = NULL;
    hr = ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT,
        &IID_ID3D12CommandAllocator, (void **)&alloc);
    CHECK(hr, "CreateCommandAllocator");
    ID3D12GraphicsCommandList *cl = NULL;
    hr = ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, pipeline,
        &IID_ID3D12GraphicsCommandList, (void **)&cl);
    CHECK(hr, "CreateCommandList");

    D3D12_GPU_VIRTUAL_ADDRESS va = ID3D12Resource_GetGPUVirtualAddress(soBuf);
    D3D12_STREAM_OUTPUT_BUFFER_VIEW view = { va, FILLED_OFFSET, va + FILLED_OFFSET };
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(cl, rootSig);
    ID3D12GraphicsCommandList_SetPipelineState(cl, pipeline);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(cl, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D12GraphicsCommandList_SOSetTargets(cl, 0, 1, &view);
    ID3D12GraphicsCommandList_BeginQuery(cl, qheap, D3D12_QUERY_TYPE_SO_STATISTICS_STREAM0, 0);
    ID3D12GraphicsCommandList_DrawInstanced(cl, VERTS, 1, 0, 0);
    ID3D12GraphicsCommandList_EndQuery(cl, qheap, D3D12_QUERY_TYPE_SO_STATISTICS_STREAM0, 0);
    ID3D12GraphicsCommandList_ResolveQueryData(cl, qheap, D3D12_QUERY_TYPE_SO_STATISTICS_STREAM0,
        0, 1, queryOut, 0);

    D3D12_RESOURCE_BARRIER bar = { 0 };
    bar.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    bar.Transition.pResource = soBuf;
    bar.Transition.StateBefore = D3D12_RESOURCE_STATE_STREAM_OUT;
    bar.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    bar.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    ID3D12GraphicsCommandList_ResourceBarrier(cl, 1, &bar);
    ID3D12GraphicsCommandList_CopyResource(cl, readback, soBuf);
    hr = ID3D12GraphicsCommandList_Close(cl);
    CHECK(hr, "Close");

    ID3D12CommandList *lists[] = { (ID3D12CommandList *)cl };
    ID3D12CommandQueue_ExecuteCommandLists(q, 1, lists);
    ID3D12Fence *fence = NULL;
    hr = ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence);
    CHECK(hr, "CreateFence");
    ID3D12CommandQueue_Signal(q, fence, 1);
    HANDLE ev = CreateEventW(NULL, FALSE, FALSE, NULL);
    ID3D12Fence_SetEventOnCompletion(fence, 1, ev);
    if (WaitForSingleObject(ev, 10000) != WAIT_OBJECT_0) { printf("Fence wait: TIMEOUT\n"); return 1; }

    int bad = 0;
    float *data = NULL;
    D3D12_RANGE range = { 0, FILLED_OFFSET + 16 };
    hr = ID3D12Resource_Map(readback, 0, &range, (void **)&data);
    CHECK(hr, "Map(stream output)");
    for (unsigned i = 0; i < VERTS; i++) {
        const float *v = data + i * 4;
        if (v[0] != i || v[1] != i * 2 || v[2] != i * 3 || v[3] != 7) {
            printf("  vertex %u = (%g %g %g %g), want (%u %u %u 7)\n",
                   i, v[0], v[1], v[2], v[3], i, i * 2, i * 3);
            bad++;
        }
    }
    UINT64 filled = *(UINT64 *)((char *)data + FILLED_OFFSET);
    printf("BufferFilledSize: %llu (want %u)\n", (unsigned long long)filled, VERTS * STRIDE);
    if (filled != VERTS * STRIDE) bad++;

    D3D12_QUERY_DATA_SO_STATISTICS *stats = NULL;
    D3D12_RANGE qrange = { 0, sizeof(*stats) };
    hr = ID3D12Resource_Map(queryOut, 0, &qrange, (void **)&stats);
    CHECK(hr, "Map(query)");
    printf("SO statistics: written %llu, needed %llu (want 2, 2)\n",
           (unsigned long long)stats->NumPrimitivesWritten,
           (unsigned long long)stats->PrimitivesStorageNeeded);
    if (stats->NumPrimitivesWritten != 2 || stats->PrimitivesStorageNeeded != 2) bad++;

    printf(bad ? "FAILED\n" : "ALL OK\n");
    return bad ? 1 : 0;
}

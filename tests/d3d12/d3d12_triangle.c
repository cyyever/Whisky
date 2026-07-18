/* Headless D3D12 graphics test: render a green fullscreen triangle into an
 * offscreen R8G8B8A8 render target, read back a pixel, verify it is green.
 * Exercises the graphics pipeline / render-target path (vkd3d-proton uses
 * dynamic rendering internally) — the path gated by the
 * VK_EXT_dynamic_rendering_unused_attachments warning. */
#define COBJMACROS
#define INITGUID
#define WIDL_EXPLICIT_AGGREGATE_RETURNS
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <string.h>

#define W 64
#define H 64
#define CHECK(hr, msg) do { if (FAILED(hr)) { printf("%s: 0x%08lx\n", msg, (unsigned long)(hr)); return 1; } } while (0)

static const char *VS_SRC =
    "float4 main(uint vid : SV_VertexID) : SV_Position {\n"
    "  float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
    "  return float4(p[vid], 0, 1);\n"
    "}\n";
static const char *PS_SRC =
    "float4 main() : SV_Target { return float4(0,1,0,1); }\n"; /* green */

static ID3DBlob *compile(const char *src, const char *target) {
    ID3DBlob *blob = NULL, *err = NULL;
    HRESULT hr = D3DCompile(src, strlen(src), "s", NULL, NULL, "main", target, 0, 0, &blob, &err);
    if (FAILED(hr)) { printf("D3DCompile(%s): 0x%08lx %s\n", target, (unsigned long)hr,
                             err ? (char *)ID3D10Blob_GetBufferPointer(err) : ""); return NULL; }
    return blob;
}

int main(void)
{
    ID3D12Device *dev = NULL;
    HRESULT hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    CHECK(hr, "D3D12CreateDevice");

    ID3DBlob *vs = compile(VS_SRC, "vs_5_0");
    ID3DBlob *ps = compile(PS_SRC, "ps_5_0");
    if (!vs || !ps) return 1;
    printf("D3DCompile vs/ps: OK\n");

    /* Empty root signature. */
    D3D12_ROOT_SIGNATURE_DESC rsd = { 0 };
    rsd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ID3DBlob *rsBlob = NULL, *err = NULL;
    hr = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &rsBlob, &err);
    CHECK(hr, "SerializeRootSignature");
    ID3D12RootSignature *rootSig = NULL;
    hr = ID3D12Device_CreateRootSignature(dev, 0, ID3D10Blob_GetBufferPointer(rsBlob),
        ID3D10Blob_GetBufferSize(rsBlob), &IID_ID3D12RootSignature, (void **)&rootSig);
    CHECK(hr, "CreateRootSignature");

    D3D12_GRAPHICS_PIPELINE_STATE_DESC pso = { 0 };
    pso.pRootSignature = rootSig;
    pso.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vs);
    pso.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vs);
    pso.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(ps);
    pso.PS.BytecodeLength = ID3D10Blob_GetBufferSize(ps);
    pso.SampleMask = ~0u;
    pso.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pso.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pso.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pso.NumRenderTargets = 1;
    pso.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pso.SampleDesc.Count = 1;
    ID3D12PipelineState *pipeline = NULL;
    hr = ID3D12Device_CreateGraphicsPipelineState(dev, &pso, &IID_ID3D12PipelineState, (void **)&pipeline);
    CHECK(hr, "CreateGraphicsPipelineState");
    printf("CreateGraphicsPipelineState: OK\n");

    /* Render target (default heap) + RTV heap + readback buffer. */
    D3D12_HEAP_PROPERTIES hpDefault = { D3D12_HEAP_TYPE_DEFAULT, 0, 0, 0, 0 };
    D3D12_HEAP_PROPERTIES hpReadback = { D3D12_HEAP_TYPE_READBACK, 0, 0, 0, 0 };
    D3D12_RESOURCE_DESC td = { 0 };
    td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    td.Width = W; td.Height = H; td.DepthOrArraySize = 1; td.MipLevels = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    D3D12_CLEAR_VALUE clear = { DXGI_FORMAT_R8G8B8A8_UNORM, { { 0, 0, 0, 1 } } };
    ID3D12Resource *rt = NULL;
    hr = ID3D12Device_CreateCommittedResource(dev, &hpDefault, D3D12_HEAP_FLAG_NONE, &td,
        D3D12_RESOURCE_STATE_RENDER_TARGET, &clear, &IID_ID3D12Resource, (void **)&rt);
    CHECK(hr, "CreateCommittedResource(RT)");

    D3D12_DESCRIPTOR_HEAP_DESC rtvHeapDesc = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1, 0, 0 };
    ID3D12DescriptorHeap *rtvHeap = NULL;
    hr = ID3D12Device_CreateDescriptorHeap(dev, &rtvHeapDesc, &IID_ID3D12DescriptorHeap, (void **)&rtvHeap);
    CHECK(hr, "CreateDescriptorHeap");
    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    rtvHeap->lpVtbl->GetCPUDescriptorHandleForHeapStart(rtvHeap, &rtv);
    ID3D12Device_CreateRenderTargetView(dev, rt, NULL, rtv);

    UINT rowPitch = (W * 4 + 255) & ~255u;   /* 256-aligned */
    D3D12_RESOURCE_DESC bd = { 0 };
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    bd.Width = rowPitch * H; bd.Height = 1; bd.DepthOrArraySize = 1; bd.MipLevels = 1;
    bd.SampleDesc.Count = 1; bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ID3D12Resource *readback = NULL;
    hr = ID3D12Device_CreateCommittedResource(dev, &hpReadback, D3D12_HEAP_FLAG_NONE, &bd,
        D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback);
    CHECK(hr, "CreateCommittedResource(readback)");

    /* Commands. */
    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT, 0, 0, 0 };
    ID3D12CommandQueue *q = NULL;
    ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&q);
    ID3D12CommandAllocator *alloc = NULL;
    ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc);
    ID3D12GraphicsCommandList *cl = NULL;
    hr = ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, pipeline,
        &IID_ID3D12GraphicsCommandList, (void **)&cl);
    CHECK(hr, "CreateCommandList");

    D3D12_VIEWPORT vp = { 0, 0, (float)W, (float)H, 0, 1 };
    D3D12_RECT sc = { 0, 0, W, H };
    ID3D12GraphicsCommandList_RSSetViewports(cl, 1, &vp);
    ID3D12GraphicsCommandList_RSSetScissorRects(cl, 1, &sc);
    ID3D12GraphicsCommandList_OMSetRenderTargets(cl, 1, &rtv, FALSE, NULL);
    float black[4] = { 0, 0, 0, 1 };
    ID3D12GraphicsCommandList_ClearRenderTargetView(cl, rtv, black, 0, NULL);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(cl, rootSig);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(cl, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D12GraphicsCommandList_DrawInstanced(cl, 3, 1, 0, 0);

    D3D12_RESOURCE_BARRIER bar = { 0 };
    bar.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    bar.Transition.pResource = rt;
    bar.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    bar.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    bar.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    ID3D12GraphicsCommandList_ResourceBarrier(cl, 1, &bar);

    D3D12_TEXTURE_COPY_LOCATION dst = { 0 }, src = { 0 };
    dst.pResource = readback;
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    dst.PlacedFootprint.Footprint.Width = W;
    dst.PlacedFootprint.Footprint.Height = H;
    dst.PlacedFootprint.Footprint.Depth = 1;
    dst.PlacedFootprint.Footprint.RowPitch = rowPitch;
    src.pResource = rt;
    src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    src.SubresourceIndex = 0;
    ID3D12GraphicsCommandList_CopyTextureRegion(cl, &dst, 0, 0, 0, &src, NULL);
    hr = ID3D12GraphicsCommandList_Close(cl);
    CHECK(hr, "Close");

    ID3D12CommandList *lists[] = { (ID3D12CommandList *)cl };
    ID3D12CommandQueue_ExecuteCommandLists(q, 1, lists);
    ID3D12Fence *fence = NULL;
    ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence);
    ID3D12CommandQueue_Signal(q, fence, 1);
    HANDLE ev = CreateEventW(NULL, FALSE, FALSE, NULL);
    ID3D12Fence_SetEventOnCompletion(fence, 1, ev);
    if (WaitForSingleObject(ev, 10000) != WAIT_OBJECT_0) { printf("Fence wait: TIMEOUT\n"); return 1; }
    printf("Draw + fence: OK\n");

    unsigned char *pix = NULL;
    hr = ID3D12Resource_Map(readback, 0, NULL, (void **)&pix);
    CHECK(hr, "Map");
    /* Center pixel. */
    unsigned char *c = pix + (H / 2) * rowPitch + (W / 2) * 4;
    printf("center RGBA = %u,%u,%u,%u (want 0,255,0,255)\n", c[0], c[1], c[2], c[3]);
    int green = (c[0] == 0 && c[1] == 255 && c[2] == 0);
    printf(green ? "ALL OK\n" : "FAILED\n");
    return green ? 0 : 1;
}

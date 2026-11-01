/* Headless D3D12 pixel-readback tests: triangle, multiple render targets,
 * depth rejection, and stencil rejection. Each checks every pixel and alpha.
 * Run through tests/d3d12/run.sh against the installed vkd3d-proton builtins. */
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
    "  return float4(p[vid], 0.5, 1);\n"
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

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "triangle";
    int mrt = !strcmp(mode, "mrt"), depth = !strcmp(mode, "depth");
    int stencil = !strcmp(mode, "stencil");
    if (strcmp(mode, "triangle") && !mrt && !depth && !stencil) {
        fprintf(stderr, "Unknown case: %s\n", mode); return 2;
    }
    unsigned targets = mrt ? 2 : 1;
    printf("Rendering case: %s\n", mode);
    ID3D12Device *dev = NULL;
    HRESULT hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    CHECK(hr, "D3D12CreateDevice");

    ID3DBlob *vs = compile(VS_SRC, "vs_5_0");
    const char *mrt_ps = "struct O { float4 a : SV_Target0; float4 b : SV_Target1; }; "
        "O main() { O o; o.a=float4(0,1,0,1); o.b=float4(0,0,1,1); return o; }";
    ID3DBlob *ps = compile(mrt ? mrt_ps : PS_SRC, "ps_5_0");
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
    pso.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pso.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pso.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pso.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pso.DepthStencilState.DepthEnable = depth;
    pso.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
    pso.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
    pso.DepthStencilState.StencilEnable = stencil;
    pso.DepthStencilState.StencilReadMask = 0xff;
    pso.DepthStencilState.StencilWriteMask = 0xff;
    pso.DepthStencilState.FrontFace.StencilFunc = D3D12_COMPARISON_FUNC_EQUAL;
    pso.DepthStencilState.FrontFace.StencilFailOp = D3D12_STENCIL_OP_KEEP;
    pso.DepthStencilState.FrontFace.StencilDepthFailOp = D3D12_STENCIL_OP_KEEP;
    pso.DepthStencilState.FrontFace.StencilPassOp = D3D12_STENCIL_OP_KEEP;
    pso.DepthStencilState.BackFace = pso.DepthStencilState.FrontFace;
    if (depth || stencil) pso.DSVFormat = DXGI_FORMAT_D24_UNORM_S8_UINT;
    pso.NumRenderTargets = targets;
    pso.RTVFormats[1] = mrt ? DXGI_FORMAT_R8G8B8A8_UNORM : DXGI_FORMAT_UNKNOWN;
    pso.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pso.SampleDesc.Count = 1;
    ID3D12PipelineState *pipeline = NULL;
    hr = ID3D12Device_CreateGraphicsPipelineState(dev, &pso, &IID_ID3D12PipelineState, (void **)&pipeline);
    CHECK(hr, "CreateGraphicsPipelineState");
    printf("CreateGraphicsPipelineState: OK\n");
    ID3D12PipelineState *rejectedPipeline = NULL;
    if (depth || stencil) {
        ID3DBlob *red = compile("float4 main() : SV_Target { return float4(1,0,0,1); }", "ps_5_0");
        if (!red) return 1;
        pso.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(red);
        pso.PS.BytecodeLength = ID3D10Blob_GetBufferSize(red);
        hr = ID3D12Device_CreateGraphicsPipelineState(dev, &pso, &IID_ID3D12PipelineState,
            (void **)&rejectedPipeline);
        CHECK(hr, "CreateGraphicsPipelineState(rejected red)");
        ID3D10Blob_Release(red);
    }

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
    ID3D12Resource *rt[2] = { NULL, NULL };
    D3D12_DESCRIPTOR_HEAP_DESC rtvHeapDesc = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, targets, 0, 0 };
    ID3D12DescriptorHeap *rtvHeap = NULL;
    hr = ID3D12Device_CreateDescriptorHeap(dev, &rtvHeapDesc, &IID_ID3D12DescriptorHeap, (void **)&rtvHeap);
    CHECK(hr, "CreateDescriptorHeap(RTV)");
    D3D12_CPU_DESCRIPTOR_HANDLE rtv[2];
    rtvHeap->lpVtbl->GetCPUDescriptorHandleForHeapStart(rtvHeap, &rtv[0]);
    rtv[1].ptr = rtv[0].ptr + ID3D12Device_GetDescriptorHandleIncrementSize(dev, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    for (unsigned i = 0; i < targets; ++i) {
        hr = ID3D12Device_CreateCommittedResource(dev, &hpDefault, D3D12_HEAP_FLAG_NONE, &td,
            D3D12_RESOURCE_STATE_RENDER_TARGET, &clear, &IID_ID3D12Resource, (void **)&rt[i]);
        CHECK(hr, "CreateCommittedResource(RT)");
        ID3D12Device_CreateRenderTargetView(dev, rt[i], NULL, rtv[i]);
    }
    ID3D12Resource *ds = NULL;
    ID3D12DescriptorHeap *dsHeap = NULL;
    D3D12_CPU_DESCRIPTOR_HANDLE dsv = { 0 };
    if (depth || stencil) {
        td.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
        td.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
        D3D12_CLEAR_VALUE dsClear = { 0 };
        dsClear.Format = td.Format;
        dsClear.DepthStencil.Depth = 1.0f;
        dsClear.DepthStencil.Stencil = 1;
        hr = ID3D12Device_CreateCommittedResource(dev, &hpDefault, D3D12_HEAP_FLAG_NONE, &td,
            D3D12_RESOURCE_STATE_DEPTH_WRITE, &dsClear, &IID_ID3D12Resource, (void **)&ds);
        CHECK(hr, "CreateCommittedResource(depth/stencil)");
        D3D12_DESCRIPTOR_HEAP_DESC desc = { D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1, 0, 0 };
        hr = ID3D12Device_CreateDescriptorHeap(dev, &desc, &IID_ID3D12DescriptorHeap, (void **)&dsHeap);
        CHECK(hr, "CreateDescriptorHeap(DSV)");
        dsHeap->lpVtbl->GetCPUDescriptorHandleForHeapStart(dsHeap, &dsv);
        ID3D12Device_CreateDepthStencilView(dev, ds, NULL, dsv);
    }

    UINT rowPitch = (W * 4 + 255) & ~255u;   /* 256-aligned */
    D3D12_RESOURCE_DESC bd = { 0 };
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    bd.Width = rowPitch * H * targets; bd.Height = 1; bd.DepthOrArraySize = 1; bd.MipLevels = 1;
    bd.SampleDesc.Count = 1; bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ID3D12Resource *readback = NULL;
    hr = ID3D12Device_CreateCommittedResource(dev, &hpReadback, D3D12_HEAP_FLAG_NONE, &bd,
        D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback);
    CHECK(hr, "CreateCommittedResource(readback)");

    /* Commands. */
    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT, 0, 0, 0 };
    ID3D12CommandQueue *q = NULL;
    hr = ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&q);
    CHECK(hr, "CreateCommandQueue");
    ID3D12CommandAllocator *alloc = NULL;
    hr = ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc);
    CHECK(hr, "CreateCommandAllocator");
    ID3D12GraphicsCommandList *cl = NULL;
    hr = ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, pipeline,
        &IID_ID3D12GraphicsCommandList, (void **)&cl);
    CHECK(hr, "CreateCommandList");

    D3D12_VIEWPORT vp = { 0, 0, (float)W, (float)H, 0, 1 };
    D3D12_RECT sc = { 0, 0, W, H };
    ID3D12GraphicsCommandList_RSSetViewports(cl, 1, &vp);
    ID3D12GraphicsCommandList_RSSetScissorRects(cl, 1, &sc);
    ID3D12GraphicsCommandList_OMSetRenderTargets(cl, targets, rtv, FALSE, ds ? &dsv : NULL);
    float black[4] = { 0, 0, 0, 1 };
    for (unsigned i = 0; i < targets; ++i)
        ID3D12GraphicsCommandList_ClearRenderTargetView(cl, rtv[i], black, 0, NULL);
    if (ds) ID3D12GraphicsCommandList_ClearDepthStencilView(cl, dsv,
        D3D12_CLEAR_FLAG_DEPTH | D3D12_CLEAR_FLAG_STENCIL, 1.0f, 1, 0, NULL);
    if (stencil) ID3D12GraphicsCommandList_OMSetStencilRef(cl, 1);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(cl, rootSig);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(cl, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D12GraphicsCommandList_DrawInstanced(cl, 3, 1, 0, 0);

    if (rejectedPipeline) {
        // Equal depth fails LESS after the green draw writes depth; a mismatched
        // stencil reference fails EQUAL. Either broken test paints the target red.
        ID3D12GraphicsCommandList_SetPipelineState(cl, rejectedPipeline);
        if (stencil) ID3D12GraphicsCommandList_OMSetStencilRef(cl, 0);
        ID3D12GraphicsCommandList_DrawInstanced(cl, 3, 1, 0, 0);
    }

    for (unsigned i = 0; i < targets; ++i) {
        D3D12_RESOURCE_BARRIER bar = { 0 };
        bar.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        bar.Transition.pResource = rt[i];
        bar.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
        bar.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
        bar.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        ID3D12GraphicsCommandList_ResourceBarrier(cl, 1, &bar);

        D3D12_TEXTURE_COPY_LOCATION dst = { 0 }, src = { 0 };
        dst.pResource = readback;
        dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        dst.PlacedFootprint.Offset = (UINT64)i * rowPitch * H;
        dst.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        dst.PlacedFootprint.Footprint.Width = W;
        dst.PlacedFootprint.Footprint.Height = H;
        dst.PlacedFootprint.Footprint.Depth = 1;
        dst.PlacedFootprint.Footprint.RowPitch = rowPitch;
        src.pResource = rt[i];
        src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        src.SubresourceIndex = 0;
        ID3D12GraphicsCommandList_CopyTextureRegion(cl, &dst, 0, 0, 0, &src, NULL);
    }
    hr = ID3D12GraphicsCommandList_Close(cl);
    CHECK(hr, "Close");

    ID3D12CommandList *lists[] = { (ID3D12CommandList *)cl };
    ID3D12CommandQueue_ExecuteCommandLists(q, 1, lists);
    ID3D12Fence *fence = NULL;
    hr = ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence);
    CHECK(hr, "CreateFence");
    hr = ID3D12CommandQueue_Signal(q, fence, 1);
    CHECK(hr, "Signal");
    HANDLE ev = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!ev) return 1;
    hr = ID3D12Fence_SetEventOnCompletion(fence, 1, ev);
    CHECK(hr, "SetEventOnCompletion");
    if (WaitForSingleObject(ev, 10000) != WAIT_OBJECT_0) { printf("Fence wait: TIMEOUT\n"); return 1; }
    printf("Draw + fence: OK\n");

    unsigned char *pix = NULL;
    hr = ID3D12Resource_Map(readback, 0, NULL, (void **)&pix);
    CHECK(hr, "Map");
    unsigned bad = 0;
    for (unsigned i = 0; i < targets; ++i)
        for (unsigned y = 0; y < H; ++y)
            for (unsigned x = 0; x < W; ++x) {
                unsigned char *c = pix + i * rowPitch * H + y * rowPitch + x * 4;
                if (c[0] != 0 || c[1] != (i ? 0 : 255) || c[2] != (i ? 255 : 0) || c[3] != 255) {
                    if (bad < 4) printf("target %u pixel %u,%u: %u,%u,%u,%u\n", i,x,y,c[0],c[1],c[2],c[3]);
                    ++bad;
                }
            }
    D3D12_RANGE written = { 0, 0 };
    ID3D12Resource_Unmap(readback, 0, &written);
    CloseHandle(ev);
    printf("%u mismatched pixels across %u target(s)\n", bad, targets);
    printf(bad ? "FAILED\n" : "ALL OK\n");
    return bad ? 1 : 0;
}

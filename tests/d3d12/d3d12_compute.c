/* Headless D3D12 compute test: compile an HLSL compute shader (DXBC via
 * D3DCompile), run a dispatch that writes buf[i]=i*2 through a root UAV, read
 * back and verify. Exercises the shader-compile + pipeline + dispatch path on
 * vkd3d-proton -> KosmicKrisp/Metal, past bare device creation. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <string.h>

#define N 64
#define CHECK(hr, msg) do { if (FAILED(hr)) { printf("%s: 0x%08lx\n", msg, (unsigned long)(hr)); return 1; } } while (0)

static const char *CS_SRC =
    "RWStructuredBuffer<uint> buf : register(u0);\n"
    "[numthreads(64,1,1)]\n"
    "void main(uint3 id : SV_DispatchThreadID) { buf[id.x] = id.x * 2; }\n";

int main(void)
{
    ID3D12Device *dev = NULL;
    HRESULT hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    CHECK(hr, "D3D12CreateDevice");

    /* Compile the compute shader to DXBC (cs_5_0). */
    ID3DBlob *cs = NULL, *err = NULL;
    hr = D3DCompile(CS_SRC, strlen(CS_SRC), "cs", NULL, NULL, "main", "cs_5_0", 0, 0, &cs, &err);
    if (FAILED(hr)) {
        printf("D3DCompile: 0x%08lx %s\n", (unsigned long)hr,
               err ? (char *)ID3D10Blob_GetBufferPointer(err) : "");
        return 1;
    }
    printf("D3DCompile cs_5_0: OK (%zu bytes)\n", (size_t)ID3D10Blob_GetBufferSize(cs));

    /* Root signature: a single root UAV at u0 (no descriptor heap needed). */
    D3D12_ROOT_PARAMETER rp = { 0 };
    rp.ParameterType = D3D12_ROOT_PARAMETER_TYPE_UAV;
    rp.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    rp.Descriptor.ShaderRegister = 0;
    D3D12_ROOT_SIGNATURE_DESC rsd = { 0 };
    rsd.NumParameters = 1;
    rsd.pParameters = &rp;
    ID3DBlob *rsBlob = NULL;
    hr = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &rsBlob, &err);
    CHECK(hr, "SerializeRootSignature");
    ID3D12RootSignature *rootSig = NULL;
    hr = ID3D12Device_CreateRootSignature(dev, 0,
        ID3D10Blob_GetBufferPointer(rsBlob), ID3D10Blob_GetBufferSize(rsBlob),
        &IID_ID3D12RootSignature, (void **)&rootSig);
    CHECK(hr, "CreateRootSignature");

    D3D12_COMPUTE_PIPELINE_STATE_DESC pso = { 0 };
    pso.pRootSignature = rootSig;
    pso.CS.pShaderBytecode = ID3D10Blob_GetBufferPointer(cs);
    pso.CS.BytecodeLength = ID3D10Blob_GetBufferSize(cs);
    ID3D12PipelineState *pipeline = NULL;
    hr = ID3D12Device_CreateComputePipelineState(dev, &pso, &IID_ID3D12PipelineState, (void **)&pipeline);
    CHECK(hr, "CreateComputePipelineState");
    printf("CreateComputePipelineState: OK\n");

    /* UAV buffer (default heap) + readback buffer. */
    D3D12_HEAP_PROPERTIES hpDefault = { D3D12_HEAP_TYPE_DEFAULT, 0, 0, 0, 0 };
    D3D12_HEAP_PROPERTIES hpReadback = { D3D12_HEAP_TYPE_READBACK, 0, 0, 0, 0 };
    D3D12_RESOURCE_DESC rd = { 0 };
    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = N * sizeof(unsigned);
    rd.Height = 1; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;

    ID3D12Resource *buf = NULL;
    hr = ID3D12Device_CreateCommittedResource(dev, &hpDefault, D3D12_HEAP_FLAG_NONE, &rd,
        D3D12_RESOURCE_STATE_UNORDERED_ACCESS, NULL, &IID_ID3D12Resource, (void **)&buf);
    CHECK(hr, "CreateCommittedResource(UAV)");

    rd.Flags = D3D12_RESOURCE_FLAG_NONE;
    ID3D12Resource *readback = NULL;
    hr = ID3D12Device_CreateCommittedResource(dev, &hpReadback, D3D12_HEAP_FLAG_NONE, &rd,
        D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&readback);
    CHECK(hr, "CreateCommittedResource(readback)");

    /* Command infrastructure. */
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

    ID3D12GraphicsCommandList_SetComputeRootSignature(cl, rootSig);
    ID3D12GraphicsCommandList_SetPipelineState(cl, pipeline);
    ID3D12GraphicsCommandList_SetComputeRootUnorderedAccessView(cl, 0,
        ID3D12Resource_GetGPUVirtualAddress(buf));
    ID3D12GraphicsCommandList_Dispatch(cl, 1, 1, 1);

    D3D12_RESOURCE_BARRIER bar = { 0 };
    bar.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    bar.Transition.pResource = buf;
    bar.Transition.StateBefore = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    bar.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    bar.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    ID3D12GraphicsCommandList_ResourceBarrier(cl, 1, &bar);
    ID3D12GraphicsCommandList_CopyResource(cl, readback, buf);
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
    printf("Dispatch + fence: OK\n");

    unsigned *data = NULL;
    D3D12_RANGE readRange = { 0, N * sizeof(unsigned) };
    hr = ID3D12Resource_Map(readback, 0, &readRange, (void **)&data);
    CHECK(hr, "Map");
    int bad = 0;
    for (unsigned i = 0; i < N; i++) if (data[i] != i * 2) { if (bad < 4) printf("  buf[%u]=%u want %u\n", i, data[i], i*2); bad++; }
    printf("verify: %s (%d/%d bad)\n", bad ? "MISMATCH" : "OK", bad, N);
    printf(bad ? "FAILED\n" : "ALL OK\n");
    return bad ? 1 : 0;
}

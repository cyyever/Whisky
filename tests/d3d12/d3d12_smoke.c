/* Minimal headless D3D12 smoke test: device + queue + fence signal/wait. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <stdio.h>

int main(void)
{
    ID3D12Device *dev = NULL;
    HRESULT hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0,
                                   &IID_ID3D12Device, (void **)&dev);
    printf("D3D12CreateDevice(FL11_0): 0x%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 1;

    D3D12_FEATURE_DATA_ARCHITECTURE arch = { 0 };
    ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_ARCHITECTURE, &arch, sizeof(arch));
    printf("UMA: %d, CacheCoherentUMA: %d\n", arch.UMA, arch.CacheCoherentUMA);

    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT, 0, 0, 0 };
    ID3D12CommandQueue *q = NULL;
    hr = ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&q);
    printf("CreateCommandQueue: 0x%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 1;

    ID3D12Fence *f = NULL;
    hr = ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE,
                                  &IID_ID3D12Fence, (void **)&f);
    printf("CreateFence: 0x%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 1;

    hr = ID3D12CommandQueue_Signal(q, f, 1);
    printf("Queue Signal: 0x%08lx\n", (unsigned long)hr);

    HANDLE ev = CreateEventW(NULL, FALSE, FALSE, NULL);
    ID3D12Fence_SetEventOnCompletion(f, 1, ev);
    DWORD w = WaitForSingleObject(ev, 10000);
    printf("Fence wait: %s\n", w == WAIT_OBJECT_0 ? "OK" : "TIMEOUT");

    printf(w == WAIT_OBJECT_0 ? "ALL OK\n" : "FAILED\n");
    return w == WAIT_OBJECT_0 ? 0 : 1;
}

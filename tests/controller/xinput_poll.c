#include <windows.h>
#include <stdio.h>
typedef struct { DWORD dwPacketNumber; struct { WORD wButtons; BYTE bLeftTrigger, bRightTrigger; SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY; } G; } XI_STATE;
typedef DWORD (WINAPI *GS_t)(DWORD, XI_STATE *);
int main(void) {
    HMODULE xi = LoadLibraryA("xinput1_4.dll");
    GS_t GetState = (GS_t)GetProcAddress(xi, "XInputGetState");
    XI_STATE st, prev = {0};
    DWORD t0 = GetTickCount();
    int reports = 0;
    while (GetTickCount() - t0 < 8000) {
        if (GetState(0, &st) == 0 && (st.dwPacketNumber != prev.dwPacketNumber)) {
            reports++;
            if (memcmp(&st.G, &prev.G, sizeof(st.G)))
                printf("pkt=%lu buttons=%04x LX=%d LY=%d LT=%u RT=%u\n",
                       st.dwPacketNumber, st.G.wButtons, st.G.sThumbLX, st.G.sThumbLY, st.G.bLeftTrigger, st.G.bRightTrigger);
            prev = st;
        }
        Sleep(16);
    }
    printf("total packet updates in 8s: %d\n", reports);
    return 0;
}

/* XInput + winmm probe: does the controller reach Windows APIs inside Wine? */
#include <windows.h>
#include <stdio.h>

typedef struct {
    DWORD dwPacketNumber;
    struct { WORD wButtons; BYTE bLeftTrigger, bRightTrigger;
             SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY; } Gamepad;
} XI_STATE;
typedef DWORD (WINAPI *XInputGetState_t)(DWORD, XI_STATE *);

int main(void)
{
    HMODULE xi = LoadLibraryA("xinput1_4.dll");
    if (!xi) xi = LoadLibraryA("xinput1_3.dll");
    printf("xinput dll: %p\n", (void *)xi);
    if (xi) {
        XInputGetState_t GetState = (XInputGetState_t)GetProcAddress(xi, "XInputGetState");
        for (DWORD i = 0; i < 4; i++) {
            XI_STATE st;
            DWORD r = GetState(i, &st);
            printf("XInputGetState(%lu) = %lu%s\n", i, r,
                   r == 0 ? "  <-- CONNECTED" : (r == 1167 ? " (not connected)" : " (?)"));
            if (r == 0)
                printf("    buttons=%04x LX=%d LY=%d LT=%u RT=%u\n",
                       st.Gamepad.wButtons, st.Gamepad.sThumbLX, st.Gamepad.sThumbLY,
                       st.Gamepad.bLeftTrigger, st.Gamepad.bRightTrigger);
        }
    }

    UINT n = joyGetNumDevs(), found = 0;
    for (UINT i = 0; i < n && found < 8; i++) {
        JOYCAPSA caps;
        if (joyGetDevCapsA(i, &caps, sizeof(caps)) == JOYERR_NOERROR) {
            JOYINFOEX info = { .dwSize = sizeof(info), .dwFlags = JOY_RETURNALL };
            if (joyGetPosEx(i, &info) == JOYERR_NOERROR) {
                printf("winmm joy[%u]: '%s' mid=%04x pid=%04x\n",
                       i, caps.szPname, caps.wMid, caps.wPid);
                found++;
            }
        }
    }
    printf("winmm active joysticks: %u\n", found);
    return 0;
}

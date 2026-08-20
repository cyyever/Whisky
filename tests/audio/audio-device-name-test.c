/*
 * audio-device-name-test — can an app read the audio devices' names?
 *
 *   wine audio-device-name-test.exe
 *
 * WHY. Tracing SSFIV's audio with +dsound,+mmdevapi turned up, on every run:
 *
 *   warn:dsound:send_device GetValue(FriendlyName) failed: 80004005
 *   warn:mmdevapi:MMDevPropStore_OpenPropKey Opening key L"{35BEB78A-...}" failed with 6
 *
 * The game's menu is silent while its opening movie plays with sound, and
 * those are different paths -- the movie is a DirectShow graph, the engine
 * imports DSOUND.dll and enumerates devices itself. An enumeration that hands
 * back a device with no name is a plausible way for an engine to decide it
 * found nothing usable.
 *
 * Plausible, not proven: the same trace shows the game going on to create a
 * device and thirteen buffers, so the warning may be cosmetic. This test
 * settles the narrower question it can settle -- whether the names are
 * readable at all -- and does it in a second instead of a game session.
 *
 * Two enumerations, because a game may use either:
 *   1. DirectSoundEnumerate, the DSOUND.dll path SSFIV imports
 *   2. IMMDeviceEnumerator + IPropertyStore, the mmdevapi path underneath it,
 *      which is where the failing OpenPropKey actually lives
 *
 * Exit: 0 every device has a name, 1 setup failure, 2 a device has no name.
 */
#define COBJMACROS
/* INITGUID: mingw ships no import library carrying CLSID_MMDeviceEnumerator or
 * the PKEY_ symbols, so they have to be instantiated here. */
#define INITGUID
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>   /* dsound.h uses LPWAVEFORMATEX without declaring it */
#include <dsound.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>
#include <propvarutil.h>
#include <stdio.h>

/* Names can be non-ASCII -- this machine has a Chinese-named Multi-Output
 * Device -- and %ls emits nothing for those and swallows the rest of the line.
 * An early version of this probe hid the one device worth looking at that way. */
static void print_ascii(const WCHAR *w)
{
    for (; *w; w++)
        putchar(*w < 128 ? (char)*w : '?');
}

static int g_dsound_devices;
static int g_dsound_unnamed;

static BOOL CALLBACK enum_cb(LPGUID guid, LPCSTR desc, LPCSTR mod, void *ctx)
{
    (void)guid; (void)ctx;
    g_dsound_devices++;
    /* A primary-device entry with a NULL guid is normal; an empty description
     * is not -- that is the string an engine shows and sometimes matches on. */
    if (!desc || !*desc) {
        printf("   FAIL device %d has no description (module %s)\n",
               g_dsound_devices, mod && *mod ? mod : "(none)");
        g_dsound_unnamed++;
    } else {
        printf("   device %d: \"%s\"%s%s\n", g_dsound_devices, desc,
               mod && *mod ? " via " : "", mod && *mod ? mod : "");
    }
    return TRUE;
}

static int check_mmdevapi(void)
{
    IMMDeviceEnumerator *devenum = NULL;
    IMMDeviceCollection *coll = NULL;
    UINT count = 0;
    int unnamed = 0;
    HRESULT hr;

    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IMMDeviceEnumerator, (void **)&devenum);
    if (FAILED(hr)) { printf("   CoCreateInstance(MMDeviceEnumerator) = 0x%08lx\n", (unsigned long)hr); return -1; }

    hr = IMMDeviceEnumerator_EnumAudioEndpoints(devenum, eRender, DEVICE_STATE_ACTIVE, &coll);
    if (FAILED(hr)) { printf("   EnumAudioEndpoints = 0x%08lx\n", (unsigned long)hr); goto done; }

    /* Which endpoint an app that just asks for "the default" actually gets.
     * macOS has two defaults -- Default Output Device (where apps play) and
     * Default System Output Device (where alerts play) -- and they can differ.
     * If winecoreaudio maps the wrong one, every app that opens the default
     * lands on a device the user is not listening to. */
    static const struct { ERole role; const char *name; } roles[] = {
        { eConsole, "eConsole" }, { eMultimedia, "eMultimedia" },
        { eCommunications, "eCommunications" },
    };
    for (unsigned r = 0; r < 3; r++) {
        IMMDevice *def = NULL;
        if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(devenum, eRender,
                                                               roles[r].role, &def))) {
            /* Counted, not just printed: an app that opens the default and gets
             * nothing is the failure mode this probe is looking for. */
            printf("   FAIL default(%s): none\n", roles[r].name);
            unnamed++;
            continue;
        }
        IPropertyStore *dp = NULL;
        if (SUCCEEDED(IMMDevice_OpenPropertyStore(def, STGM_READ, &dp))) {
            PROPVARIANT dv;
            PropVariantInit(&dv);
            if (SUCCEEDED(IPropertyStore_GetValue(dp, &PKEY_Device_FriendlyName, &dv))
                && dv.vt == VT_LPWSTR && dv.pwszVal) {
                printf("   default(%-15s): ", roles[r].name);
                print_ascii(dv.pwszVal);
                putchar('\n');
            } else {
                printf("   FAIL default(%s): name unreadable\n", roles[r].name);
                unnamed++;
            }
            PropVariantClear(&dv);
            IPropertyStore_Release(dp);
        } else {
            printf("   FAIL default(%s): property store unreadable\n", roles[r].name);
            unnamed++;
        }
        IMMDevice_Release(def);
    }

    IMMDeviceCollection_GetCount(coll, &count);
    printf("   %u active render endpoint(s)\n", count);

    for (UINT i = 0; i < count; i++) {
        IMMDevice *dev = NULL;
        IPropertyStore *props = NULL;
        PROPVARIANT v;

        if (FAILED(IMMDeviceCollection_Item(coll, i, &dev))) {
            printf("   FAIL endpoint %u: cannot be materialised\n", i);
            unnamed++;
            continue;
        }

        /* This is the call the game's trace shows failing. */
        hr = IMMDevice_OpenPropertyStore(dev, STGM_READ, &props);
        if (FAILED(hr)) {
            printf("   FAIL endpoint %u: OpenPropertyStore = 0x%08lx\n", i, (unsigned long)hr);
            unnamed++;
            IMMDevice_Release(dev);
            continue;
        }

        PropVariantInit(&v);
        hr = IPropertyStore_GetValue(props, &PKEY_Device_FriendlyName, &v);
        if (FAILED(hr) || v.vt != VT_LPWSTR || !v.pwszVal || !*v.pwszVal) {
            printf("   FAIL endpoint %u: GetValue(FriendlyName) = 0x%08lx\n", i, (unsigned long)hr);
            unnamed++;
        } else {
            printf("   endpoint %u: \"", i);
            print_ascii(v.pwszVal);
            printf("\"\n");
        }
        PropVariantClear(&v);
        IPropertyStore_Release(props);
        IMMDevice_Release(dev);
    }

done:
    if (coll) IMMDeviceCollection_Release(coll);
    if (devenum) IMMDeviceEnumerator_Release(devenum);
    return unnamed;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    if (FAILED(CoInitialize(NULL))) { printf("FAIL  CoInitialize\n"); return 1; }

    printf("DirectSoundEnumerate:\n");
    HRESULT hr = DirectSoundEnumerateA(enum_cb, NULL);
    if (FAILED(hr)) { printf("FAIL  DirectSoundEnumerate = 0x%08lx\n", (unsigned long)hr); return 1; }
    if (!g_dsound_devices) {
        printf("FAIL  no DirectSound devices at all -- an engine has nothing to open\n");
        return 2;
    }

    printf("mmdevapi:\n");
    int mm_unnamed = check_mmdevapi();
    if (mm_unnamed < 0) return 1;

    printf("\n");
    if (g_dsound_unnamed || mm_unnamed) {
        printf("FAIL  %d DirectSound device(s) and %d endpoint(s) have no readable name\n"
               "      -- an engine that matches on the name finds nothing to play through\n",
               g_dsound_unnamed, mm_unnamed);
        return 2;
    }
    printf("pass  all %d DirectSound device(s) and every endpoint are named\n",
           g_dsound_devices);
    return 0;
}

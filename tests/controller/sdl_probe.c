/* SDL joystick enumeration probe — mimics winebus bus_sdl.c conditions.
 * Modes: plain | runloop | thread
 *   plain:   SDL_Init on main thread, no CFRunLoop pump (closest to a bare process)
 *   runloop: pump CFRunLoopRunInMode before init (SDL#11742 workaround)
 *   thread:  run everything on a secondary pthread (winebus runs SDL off-main)
 */
#include <SDL.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static int probe(int pump_runloop)
{
    if (pump_runloop)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);

    if (SDL_Init(SDL_INIT_GAMECONTROLLER | SDL_INIT_HAPTIC) < 0) {
        printf("SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    printf("SDL %d.%d.%d initialized\n", SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_PATCHLEVEL);

    /* winebus waits for SDL_JOYDEVICEADDED via SDL_WaitEventTimeout */
    for (int t = 0; t < 30; t++) {
        SDL_Event e;
        while (SDL_WaitEventTimeout(&e, 100)) {
            if (e.type == SDL_JOYDEVICEADDED)
                printf("event: SDL_JOYDEVICEADDED which=%d\n", (int)e.jdevice.which);
            if (e.type == SDL_CONTROLLERDEVICEADDED)
                printf("event: SDL_CONTROLLERDEVICEADDED which=%d\n", (int)e.cdevice.which);
        }
    }

    int n = SDL_NumJoysticks();
    printf("SDL_NumJoysticks = %d\n", n);
    for (int i = 0; i < n; i++) {
        SDL_Joystick *js = SDL_JoystickOpen(i);
        printf("  [%d] name='%s' gamecontroller=%d vid=%04x pid=%04x\n",
               i, SDL_JoystickNameForIndex(i), SDL_IsGameController(i),
               SDL_JoystickGetDeviceVendor(i), SDL_JoystickGetDeviceProduct(i));
        if (js) SDL_JoystickClose(js);
    }
    SDL_Quit();
    return n > 0 ? 0 : 2;
}

static void *thread_main(void *arg)
{
    static long ret;
    ret = probe(0);
    return &ret;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "plain";
    printf("=== mode: %s ===\n", mode);
    if (!strcmp(mode, "thread")) {
        pthread_t th;
        void *ret = NULL;
        pthread_create(&th, NULL, thread_main, NULL);
        pthread_join(th, &ret);
        return ret ? (int)*(long *)ret : 1;
    }
    return probe(!strcmp(mode, "runloop"));
}

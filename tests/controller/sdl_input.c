#include <SDL.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "bg"))
        SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    if (SDL_Init(SDL_INIT_GAMECONTROLLER | SDL_INIT_HAPTIC) < 0) return 1;
    SDL_GameController *gc = NULL;
    Uint32 t0 = SDL_GetTicks();
    int changes = 0; Sint16 plx = 0; Uint8 pa = 0;
    while (SDL_GetTicks() - t0 < 8000) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_CONTROLLERDEVICEADDED && !gc) {
                gc = SDL_GameControllerOpen(e.cdevice.which);
                printf("opened: %s\n", SDL_GameControllerName(gc));
            }
            if (e.type == SDL_CONTROLLERBUTTONDOWN) { printf("event: button %d down\n", e.cbutton.button); changes++; }
            if (e.type == SDL_CONTROLLERAXISMOTION && abs(e.caxis.value) > 8000) changes++;
        }
        if (gc) {
            Sint16 lx = SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_LEFTX);
            Uint8 a = SDL_GameControllerGetButton(gc, SDL_CONTROLLER_BUTTON_A);
            if (a != pa || abs(lx - plx) > 8000) { printf("poll: A=%u LX=%d\n", a, lx); pa = a; plx = lx; changes++; }
        }
        SDL_Delay(16);
    }
    printf("total input changes: %d\n", changes);
    return 0;
}

/*
 * midi-numdevs-test — does counting MIDI output devices return?
 *
 *   wine64 midi-numdevs-test.exe
 *
 * The whole of the 32-bit DirectShow hang reduces to this call. With debug
 * symbols the stack under a hung RenderFile is:
 *
 *   autoplug -> EnumMatchingFilters -> ICreateDevEnum_CreateClassEnumerator
 *   -> devenum_factory_CreateClassEnumerator -> register_midiout_devices
 *   -> midiOutGetNumDevs -> MMDRV_Init -> OpenDriverA("mmdevapi.dll")
 *   -> DriverProc(DRV_LOAD) -> MIDI_CALL(midi_init)
 *   -> unix_midi_init -> MIDIClientCreate       (winecoreaudio.drv/coremidi.c)
 *
 * i.e. DirectShow only gets there because enumerating filters counts MIDI
 * devices. Nothing about video, quartz or GStreamer is required to reproduce
 * it -- if this hangs, they were all bystanders.
 */
#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>

int main( void )
{
    UINT n;

    setvbuf( stdout, NULL, _IONBF, 0 );
    printf( "      calling midiOutGetNumDevs\n" );
    n = midiOutGetNumDevs();
    printf( "pass  midiOutGetNumDevs returned %u\n", n );
    return 0;
}

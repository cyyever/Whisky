/* Build: x86_64-w64-mingw32-g++ system-font-test.cpp -o system-font-test.exe
 *        -ldwrite -lgdi32 -static-libgcc -static-libstdc++
 * Run after a fresh wineserver start. An optional argument asserts system DPI.
 * To reproduce the registry regression in a disposable prefix, replace a cached
 * external default-font entry under Windows NT/CurrentVersion/Fonts with a bare
 * filename absent from windows/Fonts, stop wineserver, and run this test again.
 */
#include <windows.h>
#include <dwrite.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    SetProcessDPIAware();
    NONCLIENTMETRICSW metrics = {};
    metrics.cbSize = sizeof(metrics);
    if (!SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0)) return 1;
    HDC dc = GetDC(NULL);
    int dpi = GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(NULL, dc);
    printf("Default UI font: %ls; DPI: %d\n", metrics.lfMessageFont.lfFaceName, dpi);
    if (argc > 1 && dpi != atoi(argv[1])) return 1;

    IDWriteFactory *factory = nullptr;
    HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                    reinterpret_cast<IUnknown **>(&factory));
    if (FAILED(hr)) return 1;
    IDWriteFontCollection *collection = nullptr;
    hr = factory->GetSystemFontCollection(&collection);
    if (FAILED(hr)) return 1;
    UINT32 index = 0;
    BOOL exists = FALSE;
    hr = collection->FindFamilyName(metrics.lfMessageFont.lfFaceName, &index, &exists);
    printf("DirectWrite default family: hr=%lx exists=%d\n", hr, exists);
    if (FAILED(hr) || !exists) return 1;
    IDWriteFontFamily *family = nullptr;
    IDWriteFont *font = nullptr;
    IDWriteFontFace *face = nullptr;
    hr = collection->GetFontFamily(index, &family);
    if (SUCCEEDED(hr))
        hr = family->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                         DWRITE_FONT_STYLE_NORMAL, &font);
    if (SUCCEEDED(hr)) hr = font->CreateFontFace(&face);
    printf("DirectWrite face: hr=%lx glyphs=%u\n", hr, face ? face->GetGlyphCount() : 0);
    bool passed = SUCCEEDED(hr) && face && face->GetGlyphCount();
    if (face) face->Release();
    if (font) font->Release();
    if (family) family->Release();
    collection->Release();
    factory->Release();
    return passed ? 0 : 1;
}

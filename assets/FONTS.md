# Bundled fonts

| Family | File | Source | Licence |
|---|---|---|---|
| Newsreader | newsreader/Newsreader-Variable.ttf (wght 200-800, opsz 6-72) | github.com/google/fonts ofl/newsreader | SIL OFL 1.1 (newsreader/OFL.txt) |
| Geist | geist/Geist-Variable.ttf (wght 100-900) | github.com/google/fonts ofl/geist | SIL OFL 1.1 (geist/OFL.txt) |
| Geist Mono | geist_mono/GeistMono-Variable.ttf (wght 100-900) | github.com/google/fonts ofl/geistmono | SIL OFL 1.1 (geist_mono/OFL.txt) |
| Noto Sans (+ Devanagari) | NotoSans-*.ttf | Google Noto | SIL OFL 1.1 (used only inside PDFs) |

Files live in assets/fonts/. Variable fonts: Flutter does not map `fontWeight` onto the `wght` axis by itself, so every
text style in `lib/ui/tokens.dart` sets `fontVariations` as well. Use those styles, not raw `TextStyle(fontFamily: ...)`.
The OFL texts are also registered with Flutter's `LicenseRegistry` (see `lib/ui/fonts.dart`).

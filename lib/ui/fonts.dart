import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Registers the SIL OFL texts of the bundled fonts so they appear in
/// Flutter's licence page. Call once at start-up.
void registerFontLicenses() {
  const files = {
    'Newsreader': 'assets/fonts/newsreader/OFL.txt',
    'Geist': 'assets/fonts/geist/OFL.txt',
    'Geist Mono': 'assets/fonts/geist_mono/OFL.txt',
  };
  LicenseRegistry.addLicense(() async* {
    for (final e in files.entries) {
      final text = await rootBundle.loadString(e.value);
      yield LicenseEntryWithLineBreaks([e.key], text);
    }
  });
}

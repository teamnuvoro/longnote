/// Audio languages offered in G2 ("Audio language"). Codes are what the
/// server accepts (`language` / `language_hints`, BACKEND-API 4.1; Soniox
/// supports 60+ languages with automatic identification). `auto` = detect.
class AudioLanguage {
  const AudioLanguage(this.code, this.name, [this.nativeName]);
  final String code;
  final String name;
  final String? nativeName;
}

const autoDetect = AudioLanguage('auto', 'Detect automatically');

/// Hindi and English mixed in one recording. Not a server code: it is sent as
/// language `hi` with the hints `["hi", "en"]` (see [languageRequest]).
const hinglish = AudioLanguage('hi_en', 'Hinglish (Hindi + English)');

/// What the server gets for a stored language code (BACKEND-API 4.1).
({String language, List<String> hints}) languageRequest(String code) =>
    code == hinglish.code
        ? (language: 'hi', hints: const ['hi', 'en'])
        : (language: code, hints: const <String>[]);

const audioLanguages = <AudioLanguage>[
  AudioLanguage('af', 'Afrikaans'),
  AudioLanguage('sq', 'Albanian', 'Shqip'),
  AudioLanguage('ar', 'Arabic', 'العربية'),
  AudioLanguage('az', 'Azerbaijani', 'Azərbaycan'),
  AudioLanguage('eu', 'Basque', 'Euskara'),
  AudioLanguage('be', 'Belarusian', 'Беларуская'),
  AudioLanguage('bn', 'Bengali', 'বাংলা'),
  AudioLanguage('bs', 'Bosnian', 'Bosanski'),
  AudioLanguage('bg', 'Bulgarian', 'Български'),
  AudioLanguage('ca', 'Catalan', 'Català'),
  AudioLanguage('zh', 'Chinese', '中文'),
  AudioLanguage('hr', 'Croatian', 'Hrvatski'),
  AudioLanguage('cs', 'Czech', 'Čeština'),
  AudioLanguage('da', 'Danish', 'Dansk'),
  AudioLanguage('nl', 'Dutch', 'Nederlands'),
  AudioLanguage('en', 'English'),
  AudioLanguage('et', 'Estonian', 'Eesti'),
  AudioLanguage('fi', 'Finnish', 'Suomi'),
  AudioLanguage('fr', 'French', 'Français'),
  AudioLanguage('gl', 'Galician', 'Galego'),
  AudioLanguage('de', 'German', 'Deutsch'),
  AudioLanguage('el', 'Greek', 'Ελληνικά'),
  AudioLanguage('gu', 'Gujarati', 'ગુજરાતી'),
  AudioLanguage('he', 'Hebrew', 'עברית'),
  AudioLanguage('hi', 'Hindi', 'हिन्दी'),
  AudioLanguage('hu', 'Hungarian', 'Magyar'),
  AudioLanguage('id', 'Indonesian', 'Bahasa Indonesia'),
  AudioLanguage('it', 'Italian', 'Italiano'),
  AudioLanguage('ja', 'Japanese', '日本語'),
  AudioLanguage('kn', 'Kannada', 'ಕನ್ನಡ'),
  AudioLanguage('kk', 'Kazakh', 'Қазақ'),
  AudioLanguage('ko', 'Korean', '한국어'),
  AudioLanguage('lv', 'Latvian', 'Latviešu'),
  AudioLanguage('lt', 'Lithuanian', 'Lietuvių'),
  AudioLanguage('mk', 'Macedonian', 'Македонски'),
  AudioLanguage('ms', 'Malay', 'Bahasa Melayu'),
  AudioLanguage('ml', 'Malayalam', 'മലയാളം'),
  AudioLanguage('mr', 'Marathi', 'मराठी'),
  AudioLanguage('no', 'Norwegian', 'Norsk'),
  AudioLanguage('fa', 'Persian', 'فارسی'),
  AudioLanguage('pl', 'Polish', 'Polski'),
  AudioLanguage('pt', 'Portuguese', 'Português'),
  AudioLanguage('pa', 'Punjabi', 'ਪੰਜਾਬੀ'),
  AudioLanguage('ro', 'Romanian', 'Română'),
  AudioLanguage('ru', 'Russian', 'Русский'),
  AudioLanguage('sr', 'Serbian', 'Српски'),
  AudioLanguage('sk', 'Slovak', 'Slovenčina'),
  AudioLanguage('sl', 'Slovenian', 'Slovenščina'),
  AudioLanguage('es', 'Spanish', 'Español'),
  AudioLanguage('sw', 'Swahili', 'Kiswahili'),
  AudioLanguage('sv', 'Swedish', 'Svenska'),
  AudioLanguage('tl', 'Tagalog'),
  AudioLanguage('ta', 'Tamil', 'தமிழ்'),
  AudioLanguage('te', 'Telugu', 'తెలుగు'),
  AudioLanguage('th', 'Thai', 'ไทย'),
  AudioLanguage('tr', 'Turkish', 'Türkçe'),
  AudioLanguage('uk', 'Ukrainian', 'Українська'),
  AudioLanguage('ur', 'Urdu', 'اردو'),
  AudioLanguage('vi', 'Vietnamese', 'Tiếng Việt'),
  AudioLanguage('cy', 'Welsh', 'Cymraeg'),
];

AudioLanguage audioLanguageFor(String? code) {
  if (code == null || code == 'auto') return autoDetect;
  if (code == hinglish.code) return hinglish;
  return audioLanguages.firstWhere((l) => l.code == code,
      orElse: () => AudioLanguage(code, code));
}

/// Named routes for every screen in the Figma file (DESIGN-FIGMA-V1.md).
/// Navigate by name: `context.pushNamed(R.note, pathParameters: {'id': id})`.
abstract final class R {
  // Start
  static const onboarding = 'onboarding'; // /onboarding (existing screens)
  static const paywall = 'paywall'; // A1 /paywall (?first=1 on first run)
  static const trialStarted = 'trialStarted'; // A2 /paywall/started

  // Notes tab
  static const notes = 'notes'; // B1 + B2 (empty) /notes
  static const search = 'search'; // B3 /notes/search
  static const noteActions = 'noteActions'; // B4 sheet /notes/:id/actions
  static const note = 'note'; // D1 D2 D3 D8 /notes/:id (?tab=transcript&at=ms)
  static const speakers = 'speakers'; // D4 sheet /notes/:id/speakers
  static const share = 'share'; // D5 sheet /notes/:id/share
  static const summaryStyle = 'summaryStyle'; // D6 sheet /notes/:id/style
  static const player = 'player'; // D7 sheet /notes/:id/player

  // Recording (full-screen modal, dark)
  static const record = 'record'; // C1 C2 C3 /record
  static const discard = 'discard'; // C4 sheet /record/discard

  // Ask tab
  static const ask = 'ask'; // E1 /ask
  static const askChoose = 'askChoose'; // E3 sheet /ask/choose
  static const askChat = 'askChat'; // E2 /ask/:id

  // Import tab
  static const import = 'import'; // F1 /import
  static const importDetails = 'importDetails'; // F2 sheet /import/details
  static const importProgress = 'importProgress'; // F3 /import/progress/:id

  // Settings tab
  static const settings = 'settings'; // G1 /settings
  static const audioLanguage = 'audioLanguage'; // G2 /settings/audio-language
  static const summaryLanguage = 'summaryLanguage'; // G2 variant /settings/summary-language
  static const defaultStyle = 'defaultStyle'; // D6 sheet (default) /settings/summary-style
  static const transcription = 'transcription'; // G3 /settings/transcription
  static const plan = 'plan'; // G4 /settings/plan
  static const privacy = 'privacy'; // /settings/privacy (existing screen)
  static const advanced = 'advanced'; // /settings/advanced (v0.1 settings screen)
  static const benchmark = 'benchmark'; // /settings/advanced/benchmark (hidden)
  static const gallery = 'gallery'; // /settings/advanced/benchmark/gallery (dev)
}

/// Figma frame for each route (for the screens session and reviews).
const routeFrames = <String, String>{
  R.paywall: 'A1 5:167',
  R.trialStarted: 'A2 5:275',
  R.notes: 'B1 3:7 / B2 3:141',
  R.search: 'B3 3:243',
  R.noteActions: 'B4 3:300',
  R.record: 'C1 6:191 / C2 6:322 / C3 6:448',
  R.discard: 'C4 6:579',
  R.note: 'D1 7:235 / D2 7:332 / D3 7:439 / D8 8:923',
  R.speakers: 'D4 7:546',
  R.share: 'D5 8:288',
  R.summaryStyle: 'D6 8:470',
  R.player: 'D7 8:694',
  R.ask: 'E1 9:364',
  R.askChat: 'E2 9:465',
  R.askChoose: 'E3 9:569',
  R.import: 'F1 9:684',
  R.importDetails: 'F2 9:781',
  R.importProgress: 'F3 9:889',
  R.settings: 'G1 10:643',
  R.audioLanguage: 'G2 10:803',
  R.summaryLanguage: 'G2 10:803 (summary variant)',
  R.defaultStyle: 'D6 8:470 (default style)',
  R.transcription: 'G3 10:879',
  R.plan: 'G4 10:961',
};

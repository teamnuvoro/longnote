import 'package:flutter/widgets.dart';

/// Longnote design tokens, copied from the Figma "00 · Foundations &
/// components" section (node 2:2, file lGFjCA8QrgEbWcjVk6CP19).
///
/// Look: "paper and ink". Warm paper background, white cards, ink text.
/// One signal colour (red) used ONLY for recording. Green = saved/done,
/// amber = waiting/retry. The recording screen is dark ("night").
abstract final class LnColors {
  // ---- Palette (Figma 2:176) ----------------------------------------------
  /// App background.
  static const paper = Color(0xFFF5F3EE);

  /// Surfaces: cards, sheets' rows, selected segment.
  static const card = Color(0xFFFFFFFF);

  /// Text, primary actions (buttons, record pill).
  static const ink = Color(0xFF15171C);

  /// Secondary text.
  static const ink2 = Color(0xFF5E626B);

  /// Hints, inactive tabs, timestamps.
  static const ink3 = Color(0xFF9A9DA4);

  /// Hairlines: card borders and dividers.
  static const line = Color(0xFFE7E3DB);

  /// Recording only.
  static const signal = Color(0xFFE4472B);

  /// Saved / done.
  static const saved = Color(0xFF2F7D5B);

  /// Waiting, retry, needs attention.
  static const attention = Color(0xFFA86A12);

  /// Recording screen background.
  static const night = Color(0xFF111216);

  // ---- Derived colours used in the frames ---------------------------------
  /// Tab bar background (slightly lighter than paper).
  static const tabBar = Color(0xFFFBFAF7);

  /// Quiet fill: search field, chips, icon buttons, segmented track, progress track.
  static const fill = Color(0xFFECE9E2);

  /// Background of amber icons in the needs-attention list.
  static const attentionTint = Color(0xFFFBF0DC);

  /// Background of green check boxes (summary decisions).
  static const savedTint = Color(0xFFE3F1EA);

  /// Destructive button background.
  static const destructiveTint = Color(0xFFFCE9E4);

  /// Destructive text inside a list row ("Delete note…").
  static const destructiveText = Color(0xFFC8381E);

  /// Highlighted transcript turn (current playback position / search hit).
  static const highlight = Color(0xFFFFF4D6);

  /// Modal scrim behind sheets (black 32 %).
  static const scrim = Color(0x52000000);

  /// Sheet grabber (ink3 at 50 %).
  static const grabber = Color(0x809A9DA4);

  // ---- Night (recording) ---------------------------------------------------
  static const nightRaised = Color(0xFF1C1E24);
  static const nightFill = Color(0xFF2A2D35);
  static const nightText = Color(0xFFFFFFFF);
  static const nightText2 = Color(0xFFC9CCD3);
  static const nightText3 = Color(0xFF8C909A);
  static const recordingPillBg = Color(0xFF3A1A14);
  static const recordingPillText = Color(0xFFFF8A73);
  static const savedPillBg = Color(0xFF16261E);
  static const savedPillText = Color(0xFF6FCF9F);
  static const pausedPillBg = Color(0xFF3A2C14);
  static const pausedPillText = Color(0xFFF2B65A);
}

/// Speaker colours, by `speakers.color_index` (wraps around). The first three
/// are the ones drawn in D2/D3; the rest are picked to stay readable on white
/// and to avoid the signal red.
abstract final class LnSpeakerColors {
  static const list = <Color>[
    Color(0xFF2F6BD8), // blue (Figma "Priya")
    Color(0xFF0F8A80), // teal (Figma "Arjun")
    Color(0xFF7357D6), // violet (Figma "Speaker 3")
    Color(0xFFB4237A), // magenta
    Color(0xFF4D7C0F), // olive
    Color(0xFFC2620C), // orange
    Color(0xFF0369A1), // sky
    Color(0xFF8B5E34), // brown
  ];

  static Color of(int index) => list[index.abs() % list.length];
}

/// Spacing scale (px). The frames use 20 px page margins, 16 px card padding.
abstract final class LnSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;

  /// Horizontal page margin.
  static const double page = 20;

  /// Gap between a section's card and the next section label.
  static const double section = 22;
}

abstract final class LnRadius {
  static const double chip = 6;
  static const double segment = 8;
  static const double iconButton = 10;
  static const double segmentedTrack = 10;
  static const double search = 12;
  static const double turn = 12;
  static const double button = 14;
  static const double actionCard = 14;
  static const double card = 16;
  static const double miniPlayer = 18;
  static const double sheet = 24;
  static const double pill = 999;
}

abstract final class LnShadows {
  /// Record pill: 0 10 12 rgba(20,23,28,.28).
  static const recordPill = [
    BoxShadow(color: Color(0x4714171C), offset: Offset(0, 10), blurRadius: 12),
  ];

  /// Mini player: 0 8 24 -4 rgba(20,23,28,.10).
  static const miniPlayer = [
    BoxShadow(
        color: Color(0x1A14171C),
        offset: Offset(0, 8),
        blurRadius: 24,
        spreadRadius: -4),
  ];

  /// Selected segment: 0 1 3 rgba(0,0,0,.08).
  static const segment = [
    BoxShadow(color: Color(0x14000000), offset: Offset(0, 1), blurRadius: 3),
  ];

  /// Toggle knob.
  static const knob = [
    BoxShadow(color: Color(0x26000000), offset: Offset(0, 1), blurRadius: 2),
  ];
}

abstract final class LnFonts {
  static const serif = 'Newsreader';
  static const sans = 'Geist';
  static const mono = 'GeistMono';
}

TextStyle _style(String family, double size, int weight,
    {double? lineHeightPx, Color color = LnColors.ink, double? letterSpacing}) {
  return TextStyle(
    fontFamily: family,
    fontSize: size,
    fontWeight: FontWeight.values[(weight ~/ 100) - 1],
    // Variable fonts: the weight axis must be set explicitly.
    fontVariations: [FontVariation('wght', weight.toDouble())],
    height: lineHeightPx == null ? null : lineHeightPx / size,
    color: color,
    letterSpacing: letterSpacing,
  );
}

/// Text styles from the Figma "Type" frame (2:218) plus the sizes used in the
/// screens. Colours default to ink; use `.copyWith(color: ...)`.
abstract final class LnText {
  // Newsreader (titles, summaries). Figma's "normal" leading for Newsreader
  // is 1.0; Flutter's default from the font metrics is much taller.
  /// Large title: Newsreader Medium 34 (tab roots: Notes, Settings ...).
  static final largeTitle = _style(LnFonts.serif, 34, 500, lineHeightPx: 34);

  /// Note title on the detail screen: Newsreader Medium 28 / 33.
  static final detailTitle = _style(LnFonts.serif, 28, 500, lineHeightPx: 33);

  /// Recording screen title: Newsreader Medium 24.
  static final recordingTitle =
      _style(LnFonts.serif, 24, 500,
          lineHeightPx: 24, color: LnColors.nightText);

  /// Note title (sheets, cards): Newsreader Medium 22.
  static final noteTitle = _style(LnFonts.serif, 22, 500, lineHeightPx: 22);

  /// "In short" summary paragraph: Newsreader Regular 18 / 27.
  static final summaryLead = _style(LnFonts.serif, 18, 400, lineHeightPx: 27);

  // Geist (UI)
  /// Headline: Geist SemiBold 17. Also the button label.
  static final headline = _style(LnFonts.sans, 17, 600);

  /// Body: Geist Regular 16 / 24.
  static final body = _style(LnFonts.sans, 16, 400, lineHeightPx: 24);

  /// Note row title: Geist SemiBold 16.
  static final rowTitle = _style(LnFonts.sans, 16, 600);

  /// Attention row title: Geist SemiBold 15.
  static final rowTitleSmall = _style(LnFonts.sans, 15, 600);

  /// Settings/list row label: Geist Medium 15 (sheet actions use 16).
  static final rowLabel = _style(LnFonts.sans, 15, 500);
  static final sheetRowLabel = _style(LnFonts.sans, 16, 500);

  /// Row value on the right: Geist Regular 15, ink2.
  static final rowValue = _style(LnFonts.sans, 15, 400, color: LnColors.ink2);

  /// Note preview line: Geist Regular 14 / 20, ink2.
  static final preview =
      _style(LnFonts.sans, 14, 400, lineHeightPx: 20, color: LnColors.ink2);

  /// Transcript turn text: Geist Regular 15 / 22.
  static final turn = _style(LnFonts.sans, 15, 400, lineHeightPx: 22);

  /// Summary bullet: Geist Regular 15 / 21.
  static final bullet = _style(LnFonts.sans, 15, 400, lineHeightPx: 21);

  /// Speaker name in a turn: Geist SemiBold 14 (colour = speaker colour).
  static final speakerName = _style(LnFonts.sans, 14, 600);

  /// Segmented control: selected SemiBold 14 ink, other Medium 14 ink2.
  static final segmentSelected = _style(LnFonts.sans, 14, 600);
  static final segment = _style(LnFonts.sans, 14, 500, color: LnColors.ink2);

  /// Caption: Geist Medium 13.
  static final caption = _style(LnFonts.sans, 13, 500, color: LnColors.ink2);

  /// Secondary line / meta: Geist Regular 13, ink2.
  static final meta = _style(LnFonts.sans, 13, 400, color: LnColors.ink2);

  /// Section label above a card: Geist SemiBold 13, ink2.
  static final sectionLabel = _style(LnFonts.sans, 13, 600, color: LnColors.ink2);

  /// Small caps label inside a summary ("DECISIONS"): SemiBold 12, +0.48.
  static final overline = _style(LnFonts.sans, 12, 600,
      color: LnColors.ink2, letterSpacing: 0.48);

  /// Small button / pill label: Geist SemiBold 13.
  static final smallButton = _style(LnFonts.sans, 13, 600);

  /// Chip text: Geist Medium 12, ink2.
  static final chip = _style(LnFonts.sans, 12, 500, color: LnColors.ink2);

  /// Tab label: Geist 11 (SemiBold when active, Medium otherwise).
  static final tabActive = _style(LnFonts.sans, 11, 600);
  static final tabInactive = _style(LnFonts.sans, 11, 500, color: LnColors.ink3);

  /// Placeholder text in fields: Geist Regular 16, ink3.
  static final placeholder = _style(LnFonts.sans, 16, 400, color: LnColors.ink3);

  // Geist Mono (times, durations)
  /// Geist Mono 15.
  static final mono = _style(LnFonts.mono, 15, 400);

  /// Duration on a note row: Geist Mono 12, ink3.
  static final monoSmall = _style(LnFonts.mono, 12, 400, color: LnColors.ink3);

  /// Player times: Geist Mono 11.
  static final monoTiny = _style(LnFonts.mono, 11, 400, color: LnColors.ink2);

  /// Count badge in a section label: Geist Mono Medium 13, attention.
  static final monoCount = _style(LnFonts.mono, 13, 500, color: LnColors.attention);

  /// Recording timer: Geist Mono 60, tracking -1.2, white.
  static final timer = _style(LnFonts.mono, 60, 400,
      color: LnColors.nightText, letterSpacing: -1.2);
}

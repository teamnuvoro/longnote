import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// Light "paper and ink" theme used everywhere except the recording screen.
ThemeData lnLightTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: LnColors.ink,
    onPrimary: Colors.white,
    secondary: LnColors.ink2,
    onSecondary: Colors.white,
    error: LnColors.signal,
    onError: Colors.white,
    surface: LnColors.paper,
    onSurface: LnColors.ink,
    surfaceContainerLowest: LnColors.card,
    surfaceContainerLow: LnColors.card,
    surfaceContainer: LnColors.fill,
    surfaceContainerHigh: LnColors.fill,
    surfaceContainerHighest: LnColors.fill,
    onSurfaceVariant: LnColors.ink2,
    outline: LnColors.line,
    outlineVariant: LnColors.line,
    tertiary: LnColors.saved,
    onTertiary: Colors.white,
  );
  return _base(scheme, LnColors.paper, Brightness.light);
}

/// Dark "focus mode" theme for the recording screen (C1-C4).
ThemeData lnRecordingTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Colors.white,
    onPrimary: LnColors.night,
    secondary: LnColors.nightText2,
    onSecondary: LnColors.night,
    error: LnColors.signal,
    onError: Colors.white,
    surface: LnColors.night,
    onSurface: LnColors.nightText,
    surfaceContainerLowest: LnColors.night,
    surfaceContainerLow: LnColors.nightRaised,
    surfaceContainer: LnColors.nightRaised,
    surfaceContainerHigh: LnColors.nightFill,
    surfaceContainerHighest: LnColors.nightFill,
    onSurfaceVariant: LnColors.nightText3,
    outline: LnColors.nightFill,
    outlineVariant: LnColors.nightFill,
    tertiary: LnColors.savedPillText,
    onTertiary: LnColors.night,
  );
  return _base(scheme, LnColors.night, Brightness.dark);
}

/// Material's text geometry without line heights or letter spacing.
///
/// Theme/MaterialApp merge the script's geometry (M3: bodyMedium height 1.43,
/// letter spacing 0.25 ...) UNDER the theme's text styles at runtime
/// (ThemeData.localize). A Text whose style leaves height or letter spacing
/// unset then picked those up: lines 2-5 px taller and text wider than in
/// Figma. With this geometry, only LnText decides.
TextTheme _plainGeometry(TextTheme g) {
  TextStyle? plain(TextStyle? s) => s == null
      ? null
      : TextStyle(
          inherit: s.inherit,
          fontSize: s.fontSize,
          fontWeight: s.fontWeight,
          textBaseline: s.textBaseline,
          leadingDistribution: TextLeadingDistribution.even,
        );
  return TextTheme(
    displayLarge: plain(g.displayLarge),
    displayMedium: plain(g.displayMedium),
    displaySmall: plain(g.displaySmall),
    headlineLarge: plain(g.headlineLarge),
    headlineMedium: plain(g.headlineMedium),
    headlineSmall: plain(g.headlineSmall),
    titleLarge: plain(g.titleLarge),
    titleMedium: plain(g.titleMedium),
    titleSmall: plain(g.titleSmall),
    bodyLarge: plain(g.bodyLarge),
    bodyMedium: plain(g.bodyMedium),
    bodySmall: plain(g.bodySmall),
    labelLarge: plain(g.labelLarge),
    labelMedium: plain(g.labelMedium),
    labelSmall: plain(g.labelSmall),
  );
}

final _typography = Typography.material2021(
  platform: TargetPlatform.iOS,
  englishLike: _plainGeometry(Typography.englishLike2021),
  dense: _plainGeometry(Typography.dense2021),
  tall: _plainGeometry(Typography.tall2021),
);

ThemeData _base(ColorScheme scheme, Color background, Brightness b) {
  final onBg = scheme.onSurface;
  // Every slot is set from LnText. ThemeData merges a given textTheme over
  // Material's typography (M3 heights like 1.43 and letter spacing like
  // 0.25), and Text without its own height/spacing inherits those through
  // the page's DefaultTextStyle: lines came out 2-5 px taller (and wider)
  // than Figma. The full theme is set again below with copyWith, which
  // replaces instead of merging.
  final text = TextTheme(
    displayLarge: LnText.largeTitle.copyWith(color: onBg),
    displayMedium: LnText.largeTitle.copyWith(color: onBg),
    displaySmall: LnText.largeTitle.copyWith(color: onBg),
    headlineLarge: LnText.detailTitle.copyWith(color: onBg),
    headlineMedium: LnText.detailTitle.copyWith(color: onBg),
    headlineSmall: LnText.detailTitle.copyWith(color: onBg),
    titleLarge: LnText.noteTitle.copyWith(color: onBg),
    titleMedium: LnText.headline.copyWith(color: onBg),
    titleSmall: LnText.rowTitleSmall.copyWith(color: onBg),
    bodyLarge: LnText.body.copyWith(color: onBg),
    bodyMedium: LnText.base.copyWith(color: onBg),
    bodySmall: LnText.meta.copyWith(color: scheme.onSurfaceVariant),
    labelLarge: LnText.headline.copyWith(color: onBg),
    labelMedium: LnText.caption.copyWith(color: scheme.onSurfaceVariant),
    labelSmall: LnText.chip.copyWith(color: scheme.onSurfaceVariant),
  );
  final theme = ThemeData(
    useMaterial3: true,
    typography: _typography,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    canvasColor: background,
    fontFamily: LnFonts.sans,
    textTheme: text,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    dividerColor: scheme.outline,
    dividerTheme: DividerThemeData(color: scheme.outline, thickness: 1, space: 1),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    }),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: onBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: LnText.headline.copyWith(color: onBg),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: b == Brightness.light ? LnColors.card : LnColors.nightRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LnRadius.card),
        side: BorderSide(color: scheme.outline),
      ),
      margin: const EdgeInsets.symmetric(horizontal: LnSpace.page, vertical: 6),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: background,
      modalBackgroundColor: background,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: LnColors.scrim,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(LnRadius.sheet))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: LnColors.ink,
      contentTextStyle: LnText.meta.copyWith(color: Colors.white),
      behavior: SnackBarBehavior.floating,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        textStyle: LnText.headline,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LnRadius.button)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
          foregroundColor: onBg, textStyle: LnText.smallButton),
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: LnText.rowLabel.copyWith(color: onBg),
      subtitleTextStyle: LnText.meta.copyWith(color: scheme.onSurfaceVariant),
    ),
  );
  return theme.copyWith(textTheme: text, primaryTextTheme: text);
}

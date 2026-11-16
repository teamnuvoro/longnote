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

ThemeData _base(ColorScheme scheme, Color background, Brightness b) {
  final onBg = scheme.onSurface;
  final text = TextTheme(
    displaySmall: LnText.largeTitle.copyWith(color: onBg),
    headlineSmall: LnText.detailTitle.copyWith(color: onBg),
    titleLarge: LnText.noteTitle.copyWith(color: onBg),
    titleMedium: LnText.headline.copyWith(color: onBg),
    titleSmall: LnText.rowTitleSmall.copyWith(color: onBg),
    bodyLarge: LnText.body.copyWith(color: onBg),
    bodyMedium: LnText.turn.copyWith(color: onBg),
    bodySmall: LnText.meta.copyWith(color: scheme.onSurfaceVariant),
    labelLarge: LnText.headline.copyWith(color: onBg),
    labelMedium: LnText.caption.copyWith(color: scheme.onSurfaceVariant),
    labelSmall: LnText.chip.copyWith(color: scheme.onSurfaceVariant),
  );
  return ThemeData(
    useMaterial3: true,
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
}

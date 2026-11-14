import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Calm, high-contrast Material 3 theme with iOS-like page transitions.
ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2E5E4E), // deep calm green
    brightness: b,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    }),
    appBarTheme: AppBarTheme(
      centerTitle: true,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    ),
  );
}

/// Recording red, used only for the record button and live indicator.
const recordRed = Color(0xFFD7263D);

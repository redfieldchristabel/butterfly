import 'package:flutter/material.dart';

class CoreTypographyTheme {
  final ThemeData themeData;
  late final TextTheme _textTheme;
  late final TextTheme _primaryTextTheme;

  CoreTypographyTheme(this.themeData) {
    _textTheme = themeData.textTheme;
    _primaryTextTheme = themeData.primaryTextTheme;
  }

  TextTheme get textTheme {
    return _textTheme.copyWith(
      displayLarge: displayLarge,
      displayMedium: displayMedium,
      displaySmall: displaySmall,
      headlineLarge: headlineLarge,
      headlineMedium: headlineMedium,
      headlineSmall: headlineSmall,
      titleLarge: titleLarge,
      titleMedium: titleMedium,
      titleSmall: titleSmall,
      bodyLarge: bodyLarge,
      bodyMedium: bodyMedium,
      bodySmall: bodySmall,
      labelLarge: labelLarge,
      labelMedium: labelMedium,
      labelSmall: labelSmall,
    );
  }

  TextTheme get primaryTextTheme {
    return _primaryTextTheme.copyWith(
      displayLarge: primaryDisplayLarge,
      displayMedium: primaryDisplayMedium,
      displaySmall: primaryDisplaySmall,
      headlineLarge: primaryHeadlineLarge,
      headlineMedium: primaryHeadlineMedium,
      headlineSmall: primaryHeadlineSmall,
      titleLarge: primaryTitleLarge,
      titleMedium: primaryTitleMedium,
      titleSmall: primaryTitleSmall,
      bodyLarge: primaryBodyLarge,
      bodyMedium: primaryBodyMedium,
      bodySmall: primaryBodySmall,
      labelLarge: primaryLabelLarge,
      labelMedium: primaryLabelMedium,
      labelSmall: primaryLabelSmall,
    );
  }

  TextSelectionThemeData get textSelectionTheme => themeData.textSelectionTheme;

  TextStyle get displayLarge => _textTheme.displayLarge!;

  TextStyle get primaryDisplayLarge => _primaryTextTheme.displayLarge!;

  TextStyle get displayMedium => _textTheme.displayMedium!;

  TextStyle get primaryDisplayMedium => _primaryTextTheme.displayMedium!;

  TextStyle get displaySmall => _textTheme.displaySmall!;

  TextStyle get primaryDisplaySmall => _primaryTextTheme.displaySmall!;

  TextStyle get headlineLarge => _textTheme.headlineLarge!;

  TextStyle get primaryHeadlineLarge => _primaryTextTheme.headlineLarge!;

  TextStyle get headlineMedium => _textTheme.headlineMedium!;

  TextStyle get primaryHeadlineMedium => _primaryTextTheme.headlineMedium!;

  TextStyle get headlineSmall => _textTheme.headlineSmall!;

  TextStyle get primaryHeadlineSmall => _primaryTextTheme.headlineSmall!;

  TextStyle get titleLarge => _textTheme.titleLarge!;

  TextStyle get primaryTitleLarge => _primaryTextTheme.titleLarge!;

  TextStyle get titleMedium => _textTheme.titleMedium!;

  TextStyle get primaryTitleMedium => _primaryTextTheme.titleMedium!;

  TextStyle get titleSmall => _textTheme.titleSmall!;

  TextStyle get primaryTitleSmall => _primaryTextTheme.titleSmall!;

  TextStyle get bodyLarge => _textTheme.bodyLarge!;

  TextStyle get primaryBodyLarge => _primaryTextTheme.bodyLarge!;

  TextStyle get bodyMedium => _textTheme.bodyMedium!;

  TextStyle get primaryBodyMedium => _primaryTextTheme.bodyMedium!;

  TextStyle get bodySmall => _textTheme.bodySmall!;

  TextStyle get primaryBodySmall => _primaryTextTheme.bodySmall!;

  TextStyle get labelLarge => _textTheme.labelLarge!;

  TextStyle get primaryLabelLarge => _primaryTextTheme.labelLarge!;

  TextStyle get labelMedium => _textTheme.labelMedium!;

  TextStyle get primaryLabelMedium => _primaryTextTheme.labelMedium!;

  TextStyle get labelSmall => _textTheme.labelSmall!;

  TextStyle get primaryLabelSmall => _primaryTextTheme.labelSmall!;
}

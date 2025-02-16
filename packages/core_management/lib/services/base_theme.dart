// TODO: add support for changing the theme in runtime
// TODO: add support for theme extension (Custom theme)
import 'package:core_management/core_typography_theme.dart';
import 'package:flutter/material.dart';

abstract class BaseThemeService {
  late final bool darkTheme;
  late final ThemeData _theme;
  late final bool primaryColorIsDark;

  BaseThemeService(
    BuildContext context, {
    Color colorSeed = Colors.blue,
  }) {
    final brightness = MediaQuery.of(context).platformBrightness;
    darkTheme = brightness == Brightness.dark;
    _theme = ThemeData(
        useMaterial3: true, colorSchemeSeed: colorSeed, brightness: brightness);
    primaryColorIsDark =
        ThemeData.estimateBrightnessForColor(colorSeed) == Brightness.dark;
  }

  Brightness get brightness => darkTheme ? Brightness.dark : Brightness.light;

  CoreTypographyTheme get coreTypographyTheme => CoreTypographyTheme(_theme);

  ThemeData get theme {
    return _theme.copyWith(
      appBarTheme: appBarTheme,
      cardTheme: cardTheme,
      iconTheme: iconTheme,
      listTileTheme: listTileTheme,
      dividerTheme: dividerTheme,
      chipTheme: chipThemeData,
      tabBarTheme: tabBarTheme,

      // Button
      buttonTheme: buttonTheme,
      elevatedButtonTheme: elevatedButtonTheme,
      outlinedButtonTheme: outlinedButtonTheme,
      filledButtonTheme: filledButtonTheme,
      textButtonTheme: textButtonTheme,
      iconButtonTheme: iconButtonTheme,
      segmentedButtonTheme: segmentedButtonTheme,
      toggleButtonsTheme: toggleButtonsTheme,
      floatingActionButtonTheme: floatingActionButtonTheme,

      bottomSheetTheme: bottomSheetThemeData,
      bottomNavigationBarTheme: bottomNavigationBarTheme,
      inputDecorationTheme: inputDecorationTheme,
      textTheme: coreTypographyTheme.textTheme,
      primaryTextTheme: coreTypographyTheme.primaryTextTheme,
      textSelectionTheme: coreTypographyTheme.textSelectionTheme,


    );
  }

  AppBarTheme get appBarTheme => _theme.appBarTheme;

  CardThemeData get cardTheme => _theme.cardTheme;

  IconThemeData get iconTheme => _theme.iconTheme;

  ListTileThemeData get listTileTheme => _theme.listTileTheme;

  DividerThemeData get dividerTheme => _theme.dividerTheme;

  ChipThemeData get chipThemeData => _theme.chipTheme;

  TabBarThemeData get tabBarTheme => _theme.tabBarTheme;

  // Button
  ButtonThemeData get buttonTheme => _theme.buttonTheme;

  ElevatedButtonThemeData get elevatedButtonTheme => _theme.elevatedButtonTheme;

  OutlinedButtonThemeData get outlinedButtonTheme => _theme.outlinedButtonTheme;

  FilledButtonThemeData get filledButtonTheme => _theme.filledButtonTheme;

  TextButtonThemeData get textButtonTheme => _theme.textButtonTheme;

  IconButtonThemeData get iconButtonTheme => _theme.iconButtonTheme;

  SegmentedButtonThemeData get segmentedButtonTheme =>
      _theme.segmentedButtonTheme;

  ToggleButtonsThemeData get toggleButtonsTheme => _theme.toggleButtonsTheme;

  FloatingActionButtonThemeData get floatingActionButtonTheme =>
      _theme.floatingActionButtonTheme;

  // End Button

  BottomSheetThemeData get bottomSheetThemeData => _theme.bottomSheetTheme;

  BottomNavigationBarThemeData get bottomNavigationBarTheme =>
      _theme.bottomNavigationBarTheme;

  TextTheme get textTheme => _theme.textTheme;

  InputDecorationTheme get inputDecorationTheme => _theme.inputDecorationTheme;
}

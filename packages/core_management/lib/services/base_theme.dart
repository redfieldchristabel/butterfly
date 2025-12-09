// TODO: add support for changing the theme in runtime
// TODO: add support for theme extension (Custom theme)
import 'package:core_management/core_typography_theme.dart';
import 'package:flutter/material.dart';

abstract class BaseThemeService {
  late final Color colorSeed;
  late final bool primaryColorIsDark;
  @protected
  late  bool darkTheme;
  @protected
  late  ThemeData iTheme;

  BaseThemeService({this.colorSeed = Colors.blue}) {
    primaryColorIsDark =
        ThemeData.estimateBrightnessForColor(colorSeed) == Brightness.dark;
  }

  Brightness get brightness => darkTheme ? Brightness.dark : Brightness.light;

  CoreTypographyTheme get coreTypographyTheme => CoreTypographyTheme(iTheme);

  ThemeData theme(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    darkTheme = brightness == Brightness.dark;
    final colorScheme =
        ColorScheme.fromSeed(seedColor: colorSeed, brightness: brightness);
    iTheme = ThemeData.from(colorScheme: colorScheme);

    return iTheme.copyWith(
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

  AppBarThemeData get appBarTheme => iTheme.appBarTheme;

  CardThemeData get cardTheme => iTheme.cardTheme;

  IconThemeData get iconTheme => iTheme.iconTheme;

  ListTileThemeData get listTileTheme => iTheme.listTileTheme;

  DividerThemeData get dividerTheme => iTheme.dividerTheme;

  ChipThemeData get chipThemeData => iTheme.chipTheme;

  TabBarThemeData get tabBarTheme => iTheme.tabBarTheme;

  // Button
  ButtonThemeData get buttonTheme => iTheme.buttonTheme;

  ElevatedButtonThemeData get elevatedButtonTheme => iTheme.elevatedButtonTheme;

  OutlinedButtonThemeData get outlinedButtonTheme => iTheme.outlinedButtonTheme;

  FilledButtonThemeData get filledButtonTheme => iTheme.filledButtonTheme;

  TextButtonThemeData get textButtonTheme => iTheme.textButtonTheme;

  IconButtonThemeData get iconButtonTheme => iTheme.iconButtonTheme;

  SegmentedButtonThemeData get segmentedButtonTheme =>
      iTheme.segmentedButtonTheme;

  ToggleButtonsThemeData get toggleButtonsTheme => iTheme.toggleButtonsTheme;

  FloatingActionButtonThemeData get floatingActionButtonTheme =>
      iTheme.floatingActionButtonTheme;

  // End Button

  BottomSheetThemeData get bottomSheetThemeData => iTheme.bottomSheetTheme;

  BottomNavigationBarThemeData get bottomNavigationBarTheme =>
      iTheme.bottomNavigationBarTheme;

  TextTheme get textTheme => iTheme.textTheme;

  InputDecorationThemeData get inputDecorationTheme => iTheme.inputDecorationTheme;
}

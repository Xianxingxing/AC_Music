import 'package:flutter/material.dart';

enum TvThemeChoice { system, light, dark }

class TvColors {
  /// 默认与微信深色模式一致（见 `applyThemeChoice` 中 dark / system）。
  static Color appBackground = const Color(0xFF19191A);
  static Color gradientStart = const Color(0xFF1C1C1E);
  static Color gradientEnd = const Color(0xFF111111);
  static Color panel = const Color(0xFF272829);
  static Color panelBorder = const Color(0xFF3A3A3C);
  static Color accent = const Color(0xFF07C160);
  static Color card = const Color(0xFF222324);
  static Color cardActive = const Color(0xFF2C2C2E);
  static Color cardBorder = const Color(0xFF3A3A3C);
  static Color cardActiveBorder = const Color(0xFF07C160);
  static Color focusBorder = const Color(0xFFE6E6E6);
  static Color textPrimary = const Color(0xFFF7F7F7);
  static Color textSecondary = const Color(0xFF8E8E93);
  static Color textTertiary = const Color(0xFF6C6C70);
  static Color textIndex = const Color(0xFFAEAEB2);

  static void applyThemeChoice(TvThemeChoice choice) {
    switch (choice) {
      case TvThemeChoice.system:
      case TvThemeChoice.dark:
        // 对齐微信深色：一级底 #19191A、二级底 #272829、气泡/列表块 #222324、品牌绿 #07C160。
        appBackground = const Color(0xFF19191A);
        gradientStart = const Color(0xFF1C1C1E);
        gradientEnd = const Color(0xFF111111);
        panel = const Color(0xFF272829);
        panelBorder = const Color(0xFF3A3A3C);
        accent = const Color(0xFF07C160);
        card = const Color(0xFF222324);
        cardActive = const Color(0xFF2C2C2E);
        cardBorder = const Color(0xFF3A3A3C);
        cardActiveBorder = const Color(0xFF07C160);
        focusBorder = const Color(0xFFE6E6E6);
        textPrimary = const Color(0xFFF7F7F7);
        textSecondary = const Color(0xFF8E8E93);
        textTertiary = const Color(0xFF6C6C70);
        textIndex = const Color(0xFFAEAEB2);
        break;
      case TvThemeChoice.light:
        appBackground = const Color(0xFFF3F5FB);
        gradientStart = const Color(0xFFF7F8FD);
        gradientEnd = const Color(0xFFE8ECF8);
        panel = const Color(0xFFFFFFFF);
        panelBorder = const Color(0xFFD3DAEE);
        accent = const Color(0xFF5372FF);
        card = const Color(0xFFF4F7FF);
        cardActive = const Color(0xFFDCE6FF);
        cardBorder = const Color(0xFFCCD7F0);
        cardActiveBorder = const Color(0xFF6B86E8);
        focusBorder = const Color(0xFF3954B8);
        textPrimary = const Color(0xFF1A2747);
        textSecondary = const Color(0xFF4E5F87);
        textTertiary = const Color(0xFF60729A);
        textIndex = const Color(0xFF445986);
        break;
    }
  }
}

class TvRadii {
  static const BorderRadius panel = BorderRadius.all(Radius.circular(22));
}

class TvMotion {
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration medium = Duration(milliseconds: 170);
  static const Curve curve = Curves.easeOutCubic;
}

import 'package:flutter/material.dart';

class AppThemeOption {
  final String name;
  final Color accentColor;
  final Color backgroundTint;

  const AppThemeOption({
    required this.name,
    required this.accentColor,
    required this.backgroundTint,
  });
}

class AppThemes {
  static const List<AppThemeOption> availableThemes = [
    AppThemeOption(
      name: 'Cyber Slate',
      accentColor: Colors.cyanAccent,
      backgroundTint: Color(0xFF0F172A),
    ),
    AppThemeOption(
      name: 'Neon Lime',
      accentColor: Colors.greenAccent,
      backgroundTint: Color(0xFF09130F),
    ),
    AppThemeOption(
      name: 'Royal Violet',
      accentColor: Colors.purpleAccent,
      backgroundTint: Color(0xFF13091A),
    ),
    AppThemeOption(
      name: 'Sunset Amber',
      accentColor: Colors.orangeAccent,
      backgroundTint: Color(0xFF1A1109),
    ),
  ];
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tv_player/tv_design_tokens.dart';
import 'tv_player/tv_music_player_page.dart';

void main() {
  TvColors.applyThemeChoice(TvThemeChoice.dark);
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  static const String _themeChoicePreferenceKey = 'theme_choice_v1';
  TvThemeChoice _themeChoice = TvThemeChoice.dark;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreThemeChoice());
  }

  Future<void> _restoreThemeChoice() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? saved = prefs.getString(_themeChoicePreferenceKey);
    final TvThemeChoice restored = TvThemeChoice.values.firstWhere(
      (TvThemeChoice choice) => choice.name == saved,
      orElse: () => TvThemeChoice.dark,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _themeChoice = restored;
      TvColors.applyThemeChoice(restored);
    });
  }

  void _handleThemeChanged(TvThemeChoice choice) {
    setState(() {
      _themeChoice = choice;
      TvColors.applyThemeChoice(choice);
    });
    unawaited(_saveThemeChoice(choice));
  }

  Future<void> _saveThemeChoice(TvThemeChoice choice) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeChoicePreferenceKey, choice.name);
  }

  @override
  Widget build(BuildContext context) {
    final bool isLight = _themeChoice == TvThemeChoice.light;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: isLight ? Brightness.light : Brightness.dark,
        scaffoldBackgroundColor: TvColors.appBackground,
        fontFamily: 'NotoSansSC',
        textTheme: (isLight ? ThemeData.light() : ThemeData.dark()).textTheme
            .apply(
              fontFamily: 'NotoSansSC',
              fontFamilyFallback: const ['Inter'],
            ),
      ),
      home: AppLaunchScreen(
        child: TvMusicPlayerPage(
          themeChoice: _themeChoice,
          onThemeChanged: _handleThemeChanged,
        ),
      ),
    );
  }
}

class AppLaunchScreen extends StatefulWidget {
  const AppLaunchScreen({super.key, required this.child});

  final Widget child;

  @override
  State<AppLaunchScreen> createState() => _AppLaunchScreenState();
}

class _AppLaunchScreenState extends State<AppLaunchScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _showHome = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    Future<void>.delayed(const Duration(milliseconds: 1100), () {
      if (!mounted) return;
      setState(() {
        _showHome = true;
      });
      _controller.stop();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: _showHome
          ? widget.child
          : Scaffold(
              key: const ValueKey<String>('launch-screen'),
              backgroundColor: TvColors.appBackground,
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RotationTransition(
                      turns: _controller,
                      child: const Icon(
                        Icons.graphic_eq_rounded,
                        size: 52,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.8),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

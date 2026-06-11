import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class ThemeProvider extends ChangeNotifier {
  bool _isDarkMode = false;
  bool get isDarkMode => _isDarkMode;

  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
  }
}

class AppTheme {
  // Light Mode Colors
  static const Color lightBg = Color(0xFFF8F9FA); // Off-white
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightText = Color(0xFF1E293B); // Slate-800
  static const Color lightTextSecondary = Color(0xFF64748B); // Slate-500
  static const Color lightAccent = Color(0xFF1E293B); // Black button

  // Dark Mode Colors
  static const Color darkBg = Color(0xFF0F172A); // Slate-900
  static const Color darkCard = Color(0xFF1E293B); // Slate-800
  static const Color darkText = Color(0xFFF8FAFC); // Slate-50
  static const Color darkTextSecondary = Color(0xFF94A3B8); // Slate-400
  static const Color darkAccent = Color(0xFF38BDF8); // Sky-400

  static ThemeData get lightTheme {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: lightBg,
      primaryColor: lightAccent,
      textTheme: GoogleFonts.interTextTheme().apply(
        bodyColor: lightText,
        displayColor: lightText,
      ),
      colorScheme: const ColorScheme.light(
        primary: lightAccent,
        surface: lightCard,
        onSurface: lightText,
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBg,
      primaryColor: darkAccent,
      textTheme: GoogleFonts.interTextTheme().apply(
        bodyColor: darkText,
        displayColor: darkText,
      ),
      colorScheme: const ColorScheme.dark(
        primary: darkAccent,
        surface: darkCard,
        onSurface: darkText,
      ),
    );
  }
}

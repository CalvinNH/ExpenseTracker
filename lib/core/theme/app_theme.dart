import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  AppTheme._();

  // Colors
  static const Color primaryBlue = Color(0xFF0044FF);
  static const Color darkBlue = Color(0xFF001199);
  static const Color coralAccent = Color(0xFFFF6B4A);
  static const Color background = Color(0xFFF4F6F9);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color textDark = Color(0xFF1A1F36);
  static const Color textMuted = Color(0xFF6B7280);
  static const Color borderLight = Color(0xFFE5E7EB);
  static const Color errorRed = Color(0xFFE53935);
  static const Color successGreen = Color(0xFF10B981);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryBlue, darkBlue],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient accentGradient = LinearGradient(
    colors: [coralAccent, Color(0xFFFF8C73)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Shadows
  static final List<BoxShadow> cardShadow = [
    BoxShadow(
      color: const Color(0xFF000000).withOpacity(0.04),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ];

  static Color getCategoryColor(String category) {
    switch (category.trim().toLowerCase()) {
      case 'food':
      case 'food & dining':
        return const Color(0xFF10B981); // Emerald Green
      case 'shopping':
        return const Color(0xFFF59E0B); // Amber
      case 'utilities':
      case 'bills & utilities':
        return const Color(0xFF8B5CF6); // Violet
      case 'travel':
      case 'travel & transport':
        return const Color(0xFF3B82F6); // Blue
      case 'rent':
        return const Color(0xFFEF4444); // Rose Red
      case 'salary':
        return const Color(0xFF059669); // Teal
      case 'others':
      default:
        return coralAccent; // Coral
    }
  }

  static IconData getCategoryIcon(String category) {
    switch (category.trim().toLowerCase()) {
      case 'food':
      case 'food & dining':
        return Icons.restaurant;
      case 'shopping':
        return Icons.shopping_bag;
      case 'utilities':
      case 'bills & utilities':
        return Icons.power;
      case 'travel':
      case 'travel & transport':
        return Icons.directions_car;
      case 'rent':
        return Icons.home;
      case 'salary':
        return Icons.monetization_on;
      case 'others':
      default:
        return Icons.category;
    }
  }

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.light(
        primary: primaryBlue,
        onPrimary: Colors.white,
        primaryContainer: Color(0xFFEFF6FF), // soft blue background
        onPrimaryContainer: primaryBlue,
        secondary: coralAccent,
        onSecondary: Colors.white,
        surface: surface,
        onSurface: textDark,
        error: errorRed,
        onError: Colors.white,
      ),
      textTheme: GoogleFonts.interTextTheme(
        const TextTheme(
          displayLarge: TextStyle(color: textDark, fontWeight: FontWeight.bold),
          titleLarge: TextStyle(color: textDark, fontWeight: FontWeight.bold),
          titleMedium: TextStyle(color: textDark, fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(color: textDark),
          bodyMedium: TextStyle(color: textDark),
          bodySmall: TextStyle(color: textMuted),
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        iconTheme: const IconThemeData(color: textDark),
        titleTextStyle: GoogleFonts.inter(
          color: textDark,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primaryBlue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.selected)) {
              return textDark;
            }
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.selected)) {
              return Colors.white;
            }
            return textMuted;
          }),
          side: WidgetStateProperty.all(
            const BorderSide(color: borderLight, width: 1),
          ),
        ),
      ),
    );
  }
}

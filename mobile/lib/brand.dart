import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const ink = Color(0xFF171717);
const accent = Color(0xFF292929);
const canvas = Color(0xFFF5F5F5);
const muted = Color(0xFF626262);
const edge = Color(0xFFDADADA);

ThemeData lineboardTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: const ColorScheme.light(
    primary: ink,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFE8E8E8),
    onPrimaryContainer: ink,
    secondary: accent,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFEEEEEE),
    onSecondaryContainer: ink,
    tertiary: muted,
    onTertiary: Colors.white,
    tertiaryContainer: Color(0xFFE8E8E8),
    onTertiaryContainer: ink,
    surface: Colors.white,
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xFFFAFAFA),
    surfaceContainer: canvas,
    surfaceContainerHigh: Color(0xFFEEEEEE),
    surfaceContainerHighest: Color(0xFFE8E8E8),
    outline: Color(0xFF777777),
    outlineVariant: edge,
    surfaceTint: Colors.transparent,
    inverseSurface: ink,
    onInverseSurface: Colors.white,
    inversePrimary: Color(0xFFE8E8E8),
  ),
  scaffoldBackgroundColor: canvas,
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.white,
    foregroundColor: ink,
    surfaceTintColor: Colors.transparent,
    centerTitle: false,
    systemOverlayStyle: SystemUiOverlayStyle.dark,
  ),
  inputDecorationTheme: const InputDecorationTheme(
    border: OutlineInputBorder(),
    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: edge)),
    focusedBorder: OutlineInputBorder(
      borderSide: BorderSide(color: ink, width: 2),
    ),
    filled: true,
    fillColor: Colors.white,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
  ),
  cardTheme: const CardThemeData(
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      side: BorderSide(color: edge),
    ),
  ),
);

class StoreLogo extends StatelessWidget {
  const StoreLogo({super.key, this.size = 128});
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .12),
    child: Image.asset(
      'assets/brand/lines-boardshop.jpg',
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: 'Lines Boardshop',
    ),
  );
}

class StoreAppBarTitle extends StatelessWidget {
  const StoreAppBarTitle({super.key});

  @override
  Widget build(BuildContext context) => const Row(
    children: [
      StoreLogo(size: 40),
      SizedBox(width: 12),
      Flexible(
        child: Text(
          'LINEBOARD',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 18,
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    ],
  );
}

import 'package:flutter/material.dart';

// deliberately small: slate for structure, amber reserved for the one
// signature element (the provider pill) and the primary action. nothing
// else gets a bright color, so those two things stay legible as "the
// important bits" instead of competing with decoration.
class Palette {
  static const bg = Color(0xFFF7F7F5);
  static const surface = Colors.white;
  static const ink = Color(0xFF1C1F26);
  static const inkMuted = Color(0xFF6B7280);
  static const slate = Color(0xFF334155);
  static const border = Color(0xFFE4E4E1);
  static const amber = Color(0xFFC77D2E);
  static const amberSoft = Color(0xFFFBEEDD);
  static const error = Color(0xFFB3413A);
  static const errorSoft = Color(0xFFFBEBEA);
}

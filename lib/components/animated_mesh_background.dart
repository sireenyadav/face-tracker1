import 'dart:ui';
import 'package:flutter/material.dart';
import 'dart:math' as math;

class AnimatedMeshBackground extends StatefulWidget {
  final Widget child;

  const AnimatedMeshBackground({super.key, required this.child});

  @override
  State<AnimatedMeshBackground> createState() => _AnimatedMeshBackgroundState();
}

class _AnimatedMeshBackgroundState extends State<AnimatedMeshBackground> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final color1 = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final color2 = isDark ? const Color(0xFF0F172A) : const Color(0xFFCBD5E1);
    final color3 = isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9);
    final color4 = isDark ? const Color(0xFF1E1B4B) : const Color(0xFFE0E7FF);

    return Stack(
      children: [
        // Base color
        Container(color: isDark ? const Color(0xFF020617) : const Color(0xFFF8FAFC)),
        
        // Animated Orbs
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Stack(
              children: [
                _buildOrb(
                  color: color1,
                  size: 600,
                  alignment: Alignment(
                    math.cos(_controller.value * 2 * math.pi) * 0.5,
                    math.sin(_controller.value * 2 * math.pi) * 0.5,
                  ),
                ),
                _buildOrb(
                  color: color2,
                  size: 700,
                  alignment: Alignment(
                    math.sin(_controller.value * 2 * math.pi + math.pi) * 0.8,
                    math.cos(_controller.value * 2 * math.pi + math.pi) * 0.8,
                  ),
                ),
                _buildOrb(
                  color: color3,
                  size: 500,
                  alignment: Alignment(
                    math.cos(_controller.value * 2 * math.pi + math.pi / 2) * 0.6,
                    math.sin(_controller.value * 2 * math.pi + math.pi / 2) * 0.6,
                  ),
                ),
                _buildOrb(
                  color: color4,
                  size: 800,
                  alignment: Alignment(
                    math.sin(_controller.value * 2 * math.pi - math.pi / 2) * 0.7,
                    math.cos(_controller.value * 2 * math.pi - math.pi / 2) * 0.7,
                  ),
                ),
              ],
            );
          },
        ),
        
        // Massive Blur Filter to blend orbs into a mesh gradient
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
          child: Container(color: Colors.transparent),
        ),
        
        // Application Content
        widget.child,
      ],
    );
  }

  Widget _buildOrb({required Color color, required double size, required Alignment alignment}) {
    return Align(
      alignment: alignment,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.8),
        ),
      ),
    );
  }
}

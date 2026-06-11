import 'dart:ui';
import 'package:flutter/material.dart';

class GlassContainer extends StatelessWidget {
  final Widget child;
  final double blur;
  final double opacity;
  final BorderRadiusGeometry borderRadius;
  final EdgeInsetsGeometry padding;
  final bool subtleBorder;

  const GlassContainer({
    super.key,
    required this.child,
    this.blur = 10.0,
    this.opacity = 0.1,
    this.borderRadius = const BorderRadius.all(Radius.circular(24.0)),
    this.padding = const EdgeInsets.all(24.0),
    this.subtleBorder = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    
    // For true glass, we use white regardless of theme, just differing opacities
    final glassColor = isDarkMode ? Colors.white.withValues(alpha: 0.05) : Colors.white.withValues(alpha: 0.2);
    final borderTop = isDarkMode ? Colors.white.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.5);
    final borderBottom = isDarkMode ? Colors.white.withValues(alpha: 0.02) : Colors.white.withValues(alpha: 0.1);

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: glassColor,
            borderRadius: borderRadius,
            border: subtleBorder ? Border.all(
              color: borderTop, 
              width: 1.5,
            ) : null,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 30,
                spreadRadius: -5,
              )
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

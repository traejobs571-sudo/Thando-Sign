import 'package:flutter/material.dart';

/// ThandoSign brand mark — a white raised hand on a teal→blue gradient
/// rounded square, rendered as vector so it stays crisp at any size.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 112});

  final double size;

  static const _gradient = LinearGradient(
    colors: [Color(0xFF2DBEAE), Color(0xFF2E9BE8)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: _gradient,
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.back_hand_outlined,
        color: Colors.white,
        size: size * 0.62,
      ),
    );
  }
}

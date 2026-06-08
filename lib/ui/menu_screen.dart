import 'package:flutter/material.dart' hide Element;
import '../main.dart';

class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F0E8),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'RUNE DUEL',
              style: TextStyle(
                color: Color(0xFF2C1810),
                fontSize: 48,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
            ),
            const SizedBox(height: 64),
            _MenuButton(
              label: 'Battle',
              onTap: null,
            ),
            _MenuButton(
              label: 'Inscribe',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GameScreen()),
              ),
            ),
            _MenuButton(
              label: 'Library',
              onTap: null,
            ),
            _MenuButton(
              label: 'About',
              onTap: null,
            ),
            _MenuButton(
              label: 'Settings',
              onTap: null,
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _MenuButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        width: 240,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: enabled
                ? const Color(0xFF2C1810)
                : const Color(0xFF9A9488),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: BorderSide(
                color: enabled
                    ? const Color(0xFF2C1810)
                    : const Color(0xFF9A9488),
                width: 1,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 18,
              letterSpacing: 3,
              fontWeight: FontWeight.w300,
              color: enabled
                  ? const Color(0xFF2C1810)
                  : const Color(0xFF9A9488),
            ),
          ),
        ),
      ),
    );
  }
}

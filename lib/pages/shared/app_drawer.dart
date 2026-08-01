import 'package:flutter/material.dart';
import '../../app_info.dart';
import '../../theme/app_theme.dart';
import 'update_flow.dart';

/// App-wide navigation drawer (nRF-Connect style): a Realtek wordmark pinned to
/// the top, a middle list of app-level entries (chip config, settings, …), and
/// the app version pinned to the bottom.
///
/// Attached to the two "home-level" screens — the scanner and the
/// connected-device dashboard — so its hamburger entry sits at the top-left of
/// both app bars.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  void _go(BuildContext context, String route) {
    Navigator.pop(context); // close the drawer first
    Navigator.pushNamed(context, route);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final topInset = MediaQuery.paddingOf(context).top;

    return Drawer(
      child: Column(
        children: [
          // ── Brand header: full-width banner painted in the logo image's own
          // blue so the image's baked background blends in seamlessly. Extends
          // under the status bar.
          Container(
            width: double.infinity,
            color: _brandHeader,
            padding: EdgeInsets.fromLTRB(24, topInset + 28, 24, 28),
            child: const Center(child: _RealtekLogo()),
          ),
          // ── Middle: app-level entries (jump to their own pages) ──
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _DrawerItem(
                  icon: Icons.memory,
                  label: '芯片配置',
                  onTap: () => _go(context, '/chip-config'),
                ),
                _DrawerItem(
                  icon: Icons.settings_outlined,
                  label: '设置',
                  onTap: () => _go(context, '/settings'),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: cs.outline.withValues(alpha: 0.3)),
          // ── Bottom: check GitHub for a newer release, then the app version
          // (kept clear of the nav-gesture inset) ──
          SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DrawerItem(
                  icon: Icons.system_update,
                  label: '检查更新',
                  onTap: () => runUpdateCheck(context),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Text('v${AppInfo.version}', style: tt.bodySmall),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListTile(
      // Slightly deep gray (matches the app's secondary icon tone) rather than
      // the brand blue.
      leading: Icon(icon, color: AppTheme.textSecondary),
      title: Text(label, style: tt.titleSmall),
      trailing: Icon(Icons.chevron_right, size: 20, color: cs.outline),
      onTap: onTap,
    );
  }
}

/// The solid blue baked into `image.png`'s background; the brand header is
/// painted the same value so the image blends in with no visible seam.
const Color _brandHeader = Color(0xFF19519C);

/// The Realtek wordmark image — a white wordmark on its own blue background
/// (matching [_brandHeader]), drawn as-is with no tint. Falls back to a white
/// text wordmark if the image asset is ever missing.
class _RealtekLogo extends StatelessWidget {
  const _RealtekLogo();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/image.png',
      height: 54,
      // 913px source downscaled to display size for a crisp wordmark; contain
      // keeps the aspect ratio within the height box. No tint — the image
      // already carries its white-on-blue look.
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      errorBuilder: (context, error, stack) => const Text(
        'Realtek',
        style: TextStyle(
          fontSize: 42,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: Colors.white,
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

/// The areas of the app, each with its own colour and icon.
///
/// A single green app makes every screen look the same, and on a phone that
/// means the person at the desk has to read the title to know where they are.
/// Giving each area a colour means they recognise it before they read it —
/// money is green, students are blue, the timetable is teal — and the colour
/// then follows that area onto its own screens rather than living only on the
/// home tile.
enum Section {
  students('Students', Icons.people_alt_outlined, Color(0xFF1565C0)),
  money('Money', Icons.payments_outlined, Color(0xFF2E7D32)),
  teachers('Teachers', Icons.school_outlined, Color(0xFF6A1B9A)),
  attendance('Attendance', Icons.fact_check_outlined, Color(0xFFE65100)),
  routine('Routine', Icons.grid_on_outlined, Color(0xFF00695C)),
  questions('Questions', Icons.quiz_outlined, Color(0xFF283593)),
  printing('Print', Icons.print_outlined, Color(0xFF8D6E63)),
  stock('Inventory', Icons.inventory_2_outlined, Color(0xFF00838F)),
  reports('Reports', Icons.insights_outlined, Color(0xFF4527A0)),
  setup('Setup', Icons.tune, Color(0xFF546E7A));

  const Section(this.label, this.icon, this.colour);

  final String label;
  final IconData icon;
  final Color colour;

  /// A soft version of the colour, for card backgrounds and headers.
  Color tint(BuildContext context) =>
      Color.alphaBlend(colour.withValues(alpha: 0.10), _surface(context));

  /// A slightly stronger tint, for the band at the top of a screen.
  Color band(BuildContext context) =>
      Color.alphaBlend(colour.withValues(alpha: 0.16), _surface(context));

  /// Text and icons that sit on [tint] or [band].
  Color onTint(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? Color.alphaBlend(colour.withValues(alpha: 0.35), Colors.white)
          : colour;

  static Color _surface(BuildContext context) =>
      Theme.of(context).colorScheme.surface;
}

/// An app bar tinted for its section, so a screen announces where it belongs
/// before the title is read.
class SectionAppBar extends StatelessWidget implements PreferredSizeWidget {
  const SectionAppBar({
    required this.section,
    required this.title,
    this.actions,
    this.bottom,
    super.key,
  });

  final Section section;
  final String title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) => AppBar(
        title: Text(title),
        backgroundColor: section.band(context),
        foregroundColor: section.onTint(context),
        actions: actions,
        bottom: bottom,
      );
}

/// A labelled divider between groups of settings or list items.
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {this.section, super.key});

  final String text;
  final Section? section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = section?.onTint(context) ?? theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
      child: Row(
        children: [
          if (section != null) ...[
            Icon(section!.icon, size: 16, color: colour),
            const SizedBox(width: 8),
          ],
          Text(
            text.toUpperCase(),
            style: theme.textTheme.labelMedium?.copyWith(
              color: colour,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// An empty state that teaches the next step instead of reporting emptiness.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.section,
    required this.title,
    required this.body,
    this.action,
    super.key,
  });

  final Section section;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: section.tint(context),
                shape: BoxShape.circle,
              ),
              child: Icon(section.icon,
                  size: 34, color: section.onTint(context)),
            ),
            const SizedBox(height: 18),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline)),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

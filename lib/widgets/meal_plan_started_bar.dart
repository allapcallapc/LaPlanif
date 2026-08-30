import 'package:flutter/material.dart';

/// Flyers are typically valid for about a week - past that, deals shown
/// in this flow are likely no longer honored in store. See issue #37:
/// without this, a plan can silently get built on an expired flyer.
const _staleAfter = Duration(days: 7);

/// Shown as an [AppBar.bottom] on Planif's Deals/Structure/Review screens,
/// so how old the plan's underlying deals are stays visible regardless of
/// which of those screens the user is currently on. Returns null when
/// there's nothing to show yet (no fetch/cache has completed).
PreferredSizeWidget? mealPlanStartedBar(BuildContext context, DateTime? fetchedAt) {
  if (fetchedAt == null) return null;
  final age = DateTime.now().difference(fetchedAt);
  final isStale = age >= _staleAfter;
  final theme = Theme.of(context);
  final color = isStale ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
  return PreferredSize(
    preferredSize: const Size.fromHeight(28),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          Icon(isStale ? Icons.warning_amber_rounded : Icons.schedule, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              isStale
                  ? 'Meal plan started ${_formatAge(age)} - may be outdated. Consider re-fetching.'
                  : 'Meal plan started ${_formatAge(age)}',
              style: theme.textTheme.bodySmall?.copyWith(color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

// Each branch's own suffix (or lack of one) avoids a redundant "just now
// ago".
String _formatAge(Duration age) {
  if (age.inMinutes < 1) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  if (age.inHours < 24) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}

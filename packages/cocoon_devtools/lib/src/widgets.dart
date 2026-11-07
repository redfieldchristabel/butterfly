/// Small widgets shared by the inspector's panels: the query-plan verdict,
/// the path breadcrumb and the JSON field renderer.
library;

import 'package:flutter/material.dart';

import 'models.dart';

/// The plain-words verdict about how a query ran, with one follow-up
/// sentence of advice.
///
/// Green for an index, blue for the primary key, amber for a full scan,
/// red for a query the index rule refused.
class PlanVerdictView extends StatelessWidget {
  const PlanVerdictView({super.key, required this.verdict});

  /// The verdict to render.
  final PlanVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (verdict.outcome) {
      PlanOutcome.usedIndex => (Icons.bolt, Colors.green.shade700),
      PlanOutcome.usedPrimaryKey => (Icons.key, colorScheme.primary),
      PlanOutcome.fullScan => (
        Icons.warning_amber_rounded,
        Colors.orange.shade800,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                verdict.headline,
                style: TextStyle(fontWeight: FontWeight.w600, color: color),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(verdict.advice, style: Theme.of(context).textTheme.bodySmall),
        if (verdict.suggestedIndex != null) ...[
          const SizedBox(height: 8),
          Text(
            'Declare this on the model:',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              verdict.suggestedIndex!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ],
      ],
    );
  }
}

/// One clickable crumb of a [PathBreadcrumb].
typedef BreadcrumbSegment = ({String label, String path});

/// The inspected path as clickable crumbs separated by slashes, e.g.
/// `accounts / a1 / txns / t9`.
///
/// Tapping a crumb reports its [BreadcrumbSegment.path] through
/// [onSelected]; the documents panel navigates there. Crumbs render
/// collections and document ids in alternating weight, so the path reads
/// like the Firestore console's.
class PathBreadcrumb extends StatelessWidget {
  const PathBreadcrumb({super.key, required this.segments, this.onSelected});

  /// The crumbs from the root to the current node; empty renders nothing.
  final List<BreadcrumbSegment> segments;

  /// Called with the tapped crumb's path.
  final void Function(BreadcrumbSegment segment)? onSelected;

  @override
  Widget build(BuildContext context) {
    if (segments.isEmpty) {
      return const SizedBox.shrink();
    }
    final textTheme = Theme.of(context).textTheme;
    final children = <Widget>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final isLast = i == segments.length - 1;
      if (i > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('/', style: textTheme.bodySmall),
          ),
        );
      }
      children.add(
        Tooltip(
          message: segment.path,
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: isLast ? null : () => onSelected?.call(segment),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
              child: Text(
                segment.label,
                style:
                    (isLast
                            ? textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              )
                            : textTheme.bodyMedium)
                        ?.copyWith(
                          color: isLast
                              ? null
                              : Theme.of(context).colorScheme.primary,
                        ),
              ),
            ),
          ),
        ),
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

/// A decoded document rendered as field rows: `key: value`, nested maps and
/// lists indented, in the document's own field order (the lock-number order
/// the generated adapter emits).
///
/// Scalars render as themselves with `null` dimmed; binary placeholders
/// (`<N bytes>`) render dimmed and italic; nested maps render their fields
/// under an owning row; lists render index rows.
class JsonMapView extends StatelessWidget {
  const JsonMapView({super.key, required this.fields, this.depth = 0});

  /// The fields to render, in display order.
  final Map<String, Object?> fields;

  /// How deep this map sits; drives the indentation.
  final int depth;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in fields.entries)
          JsonFieldRow(
            key: ValueKey('${depth}_${entry.key}'),
            name: entry.key,
            value: entry.value,
            depth: depth,
          ),
      ],
    );
  }
}

/// One `key: value` row of a [JsonMapView].
class JsonFieldRow extends StatelessWidget {
  const JsonFieldRow({
    super.key,
    required this.name,
    required this.value,
    required this.depth,
  });

  /// The field name.
  final String name;

  /// The field value.
  final Object? value;

  /// The nesting depth, driving the indent.
  final int depth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: depth * 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$name:',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: JsonValueView(value: value, depth: depth),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A single JSON value, recursing into maps and lists.
class JsonValueView extends StatelessWidget {
  const JsonValueView({super.key, required this.value, required this.depth});

  /// The value to render.
  final Object? value;

  /// The nesting depth of the owning row.
  final int depth;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final value = this.value;
    if (value == null) {
      return Text(
        'null',
        style: textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
      );
    }
    if (value is Map<String, Object?>) {
      return value.isEmpty
          ? Text('{}', style: textTheme.bodySmall)
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: JsonMapView(fields: value, depth: depth + 1),
            );
    }
    if (value is List<Object?>) {
      return value.isEmpty
          ? Text('[]', style: textTheme.bodySmall)
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < value.length; i++)
                    JsonFieldRow(
                      key: ValueKey('${depth}_list_$i'),
                      name: '[$i]',
                      value: value[i],
                      depth: depth + 1,
                    ),
                ],
              ),
            );
    }
    if (value is String && value.endsWith(' bytes>') && value.startsWith('<')) {
      return Text(
        value,
        style: textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
      );
    }
    if (value is String) {
      return Text('"$value"');
    }
    return SelectableText('$value');
  }
}

import 'services/work_tag_link.dart';
import 'package:flutter/material.dart';

import 'services/work_page_details.dart';

class WorkDetailsPanel extends StatefulWidget {
  const WorkDetailsPanel({
    super.key,
    required this.details,
    this.fallbackTitle = '',
    this.fallbackThumbnail,
    this.onTagTap,
  });

  final WorkPageDetails details;
  final String fallbackTitle;
  final Uri? fallbackThumbnail;
  final ValueChanged<WorkTagLink>? onTagTap;

  @override
  State<WorkDetailsPanel> createState() => _WorkDetailsPanelState();
}

class _WorkDetailsPanelState extends State<WorkDetailsPanel> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant WorkDetailsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.details.description != widget.details.description) {
      _expanded = false;
    }
  }

  Widget _tagChip(String label) {
    WorkTagLink? link;

    for (final candidate in widget.details.tagLinks) {
      if (candidate.label == label) {
        link = candidate;
        break;
      }
    }

    final selected = link;
    final callback = widget.onTagTap;

    if (selected != null && callback != null) {
      return ActionChip(
        label: Text(label),
        visualDensity: VisualDensity.compact,
        onPressed: () => callback(selected),
      );
    }

    return Chip(label: Text(label), visualDensity: VisualDensity.compact);
  }

  @override
  Widget build(BuildContext context) {
    final details = widget.details;
    final title = details.title.isEmpty ? widget.fallbackTitle : details.title;
    final thumbnail = details.thumbnail ?? widget.fallbackThumbnail;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (thumbnail != null) ...[
          Center(
            child: SizedBox(
              width: 220,
              height: 320,
              child: Image.network(
                thumbnail.toString(),
                fit: BoxFit.contain,
                cacheWidth: 660,
                errorBuilder: (_, error, stack) => const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white38,
                    size: 48,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (title.isNotEmpty) ...[
          SelectableText(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
        ],
        if (details.tags.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final tag in details.tags) _tagChip(tag)],
          ),
          const SizedBox(height: 12),
        ],
        if (details.description.isNotEmpty) ...[
          const Text('説明', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            details.description,
            maxLines: _expanded ? null : 6,
            overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: const TextStyle(height: 1.6, color: Colors.white70),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? '閉じる' : '続きを読む'),
            ),
          ),
        ],
      ],
    );
  }
}

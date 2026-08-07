import 'package:flutter/material.dart';

import '../../core/lyrics_utils.dart';
import '../../core/models.dart';
import 'provider_branding.dart';

/// 单个搜索结果卡片。
class ResultCard extends StatelessWidget {
  const ResultCard({
    super.key,
    required this.candidate,
    required this.selected,
    required this.isBest,
    required this.compact,
    required this.onTap,
    required this.onPreview,
    required this.onSave,
  });

  final LyricsCandidate candidate;
  final bool selected;
  final bool isBest;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback onPreview;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = providerColor(candidate.source);
    final textTheme = Theme.of(context).textTheme;
    final padding = compact ? 11.0 : 14.0;

    return Card(
      elevation: selected ? 2 : 0,
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.35)
          : scheme.surfaceContainerLow,
      shadowColor: scheme.shadow.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? scheme.primary : Colors.transparent,
          width: selected ? 1.5 : 0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onPreview,
        hoverColor: scheme.primary.withValues(alpha: 0.05),
        child: Padding(
          padding: EdgeInsets.all(padding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(color: color, label: providerShortLabel(candidate.source)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            candidate.title.isNotEmpty
                                ? candidate.title
                                : '未知标题',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (isBest) ...[
                          const SizedBox(width: 6),
                          _Badge(
                            label: '推荐',
                            color: scheme.tertiary,
                            foreground: scheme.onTertiary,
                          ),
                        ],
                        if (candidate.hasSynced) ...[
                          const SizedBox(width: 6),
                          _Badge(
                            label: '时间轴',
                            color: scheme.secondaryContainer,
                            foreground: scheme.onSecondaryContainer,
                          ),
                        ],
                        if (candidate.hasPlain) ...[
                          const SizedBox(width: 6),
                          _Badge(
                            label: '纯文本',
                            color: scheme.surfaceContainerHighest,
                            foreground: scheme.onSurfaceVariant,
                          ),
                        ],
                        if (candidate.hasTranslation) ...[
                          const SizedBox(width: 6),
                          _Badge(
                            label: '翻译',
                            color: scheme.primaryContainer,
                            foreground: scheme.onPrimaryContainer,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        candidate.artist,
                        candidate.album,
                        formatDuration(candidate.duration),
                      ].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _SourceTag(color: color, label: providerLabelOf(candidate.source)),
                        const SizedBox(width: 8),
                        Text(
                          '匹配 ${(candidate.score * 100 / 200).clamp(0, 100).toStringAsFixed(0)}%',
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '预览歌词',
                          onPressed: onPreview,
                          icon: const Icon(Icons.visibility_outlined, size: 18),
                          visualDensity: VisualDensity.compact,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 2),
                        FilledButton.tonalIcon(
                          onPressed: onSave,
                          icon: const Icon(Icons.save_outlined, size: 16),
                          label: const Text('保存'),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 22,
                height: 22,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? scheme.primary : Colors.transparent,
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                    width: 2,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check, size: 14, color: scheme.onPrimary)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.85), color.withValues(alpha: 0.55)],
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.color,
    required this.foreground,
  });

  final String label;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }
}

class _SourceTag extends StatelessWidget {
  const _SourceTag({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

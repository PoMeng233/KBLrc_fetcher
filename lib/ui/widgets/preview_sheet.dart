import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/save_service.dart';
import 'provider_branding.dart';

/// 歌词预览面板（底部弹层）。
class PreviewSheet extends StatefulWidget {
  const PreviewSheet({
    super.key,
    required this.candidate,
    required this.query,
    required this.initialOptions,
    required this.onSave,
  });

  final LyricsCandidate candidate;
  final TrackQuery query;
  final SaveOptions initialOptions;

  /// 保存回调，返回最终结果；取消（用户放弃）时返回 null。
  final Future<SaveOutcome?> Function(LyricsCandidate candidate, SaveOptions options) onSave;

  @override
  State<PreviewSheet> createState() => _PreviewSheetState();
}

class _PreviewSheetState extends State<PreviewSheet> {
  final SaveService _saveService = const SaveService();
  late LyricMode _lyricMode;
  late bool _includeMetadata;
  late bool _stripTimestamps;
  late bool _stripTranslation;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _lyricMode = widget.initialOptions.lyricMode;
    _includeMetadata = widget.initialOptions.includeMetadata;
    _stripTimestamps = widget.initialOptions.stripTimestamps;
    _stripTranslation = widget.initialOptions.stripTranslationLines;
  }

  SaveOptions get _options => SaveOptions(
    outputMode: widget.initialOptions.outputMode,
    overwrite: widget.initialOptions.overwrite,
    outDir: widget.initialOptions.outDir,
    lyricMode: _lyricMode,
    includeMetadata: _includeMetadata,
    stripTimestamps: _stripTimestamps,
    stripTranslationLines: _stripTranslation,
  );

  String get _text => _saveService.render(_options, widget.candidate);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final color = providerColor(widget.candidate.source);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        color.withValues(alpha: 0.85),
                        color.withValues(alpha: 0.55),
                      ],
                    ),
                  ),
                  child: Text(
                    providerShortLabel(widget.candidate.source),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.candidate.title.isNotEmpty
                            ? widget.candidate.title
                            : widget.query.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        [
                          widget.candidate.artist.isNotEmpty
                              ? widget.candidate.artist
                              : widget.query.artist,
                          providerLabelOf(widget.candidate.source),
                        ].where((s) => s.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Icon(Icons.description_outlined, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _saveService.filenameFor(
                      _options,
                      widget.candidate,
                      widget.query,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      fontFamily: 'Consolas',
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<LyricMode>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: LyricMode.auto,
                      label: Text('自动'),
                      icon: Icon(Icons.auto_awesome, size: 14),
                    ),
                    ButtonSegment(
                      value: LyricMode.synced,
                      label: Text('时间轴'),
                      icon: Icon(Icons.timer_outlined, size: 14),
                    ),
                    ButtonSegment(
                      value: LyricMode.plain,
                      label: Text('纯文本'),
                      icon: Icon(Icons.text_fields, size: 14),
                    ),
                  ],
                  selected: {_lyricMode},
                  onSelectionChanged: (s) =>
                      setState(() => _lyricMode = s.first),
                ),
                const SizedBox(width: 4),
                FilterChip(
                  label: const Text('元数据'),
                  visualDensity: VisualDensity.compact,
                  selected: _includeMetadata,
                  onSelected: (v) => setState(() => _includeMetadata = v),
                ),
                FilterChip(
                  label: const Text('去时间戳'),
                  visualDensity: VisualDensity.compact,
                  selected: _stripTimestamps,
                  onSelected: (v) => setState(() => _stripTimestamps = v),
                ),
                FilterChip(
                  label: const Text('去翻译'),
                  visualDensity: VisualDensity.compact,
                  selected: _stripTranslation,
                  onSelected: (v) => setState(() => _stripTranslation = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: _text.isEmpty
                  ? Center(
                      child: Text(
                        '（无歌词内容）',
                        style: textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : SelectableText.rich(
                      TextSpan(
                        children: _buildSpans(_text, scheme),
                      ),
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12.5,
                        height: 1.7,
                        color: scheme.onSurface,
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制歌词到剪贴板')),
                    );
                  },
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('复制'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _saving ? null : _handleSave,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 18),
                  label: const Text('保存'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSave() async {
    setState(() => _saving = true);
    try {
      final outcome = await widget.onSave(widget.candidate, _options);
      if (!mounted) return;
      if (outcome != null && outcome.success) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 把 LRC 文本渲染为带时间戳配色的 TextSpan。
  List<TextSpan> _buildSpans(String text, ColorScheme scheme) {
    final stampRe = RegExp(r'(\[\d{2}:\d{2}(?:\.\d{1,3})?\])');
    final spans = <TextSpan>[];
    for (final line in text.split('\n')) {
      if (line.isEmpty) {
        spans.add(const TextSpan(text: '\n'));
        continue;
      }
      final parts = stampRe.allMatches(line).toList();
      if (parts.isEmpty) {
        spans.add(TextSpan(
          text: '$line\n',
          style: TextStyle(color: scheme.onSurface),
        ));
        continue;
      }
      var cursor = 0;
      for (final m in parts) {
        if (m.start > cursor) {
          spans.add(TextSpan(
            text: line.substring(cursor, m.start),
            style: TextStyle(color: scheme.onSurface),
          ));
        }
        spans.add(TextSpan(
          text: m.group(0),
          style: TextStyle(color: scheme.tertiary, fontWeight: FontWeight.w600),
        ));
        cursor = m.end;
      }
      if (cursor < line.length) {
        spans.add(TextSpan(
          text: line.substring(cursor),
          style: TextStyle(color: scheme.onSurface),
        ));
      }
      spans.add(const TextSpan(text: '\n'));
    }
    return spans;
  }
}

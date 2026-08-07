import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/settings.dart';

/// 应用设置面板（底部弹层）。
class SettingsSheet extends StatelessWidget {
  const SettingsSheet({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.tune,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('设置', style: textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 16),
            _SectionLabel('主题'),
            const SizedBox(height: 8),
            SegmentedButton<ThemePreference>(
              segments: const [
                ButtonSegment(
                  value: ThemePreference.system,
                  label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto_outlined),
                ),
                ButtonSegment(
                  value: ThemePreference.light,
                  label: Text('浅色'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: ThemePreference.dark,
                  label: Text('深色'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
              ],
              selected: {settings.theme},
              onSelectionChanged: (selection) {
                settings.update(() {
                  settings.theme = selection.first;
                });
              },
            ),
            const SizedBox(height: 8),
            _SwitchRow(
              title: '紧凑模式',
              subtitle: '缩小卡片间距，一屏显示更多结果',
              icon: Icons.density_small,
              value: settings.compactMode,
              onChanged: (v) => settings.update(() => settings.compactMode = v),
            ),
            _SwitchRow(
              title: '写入元数据头',
              subtitle: '在 LRC 文件头写入 [ti]/[ar]/[al]/[by]',
              icon: Icons.info_outline,
              value: settings.includeMetadata,
              onChanged: (v) =>
                  settings.update(() => settings.includeMetadata = v),
            ),
            _SwitchRow(
              title: '保存时去掉时间戳',
              subtitle: '输出纯文本歌词',
              icon: Icons.timer_off_outlined,
              value: settings.stripTimestamps,
              onChanged: (v) =>
                  settings.update(() => settings.stripTimestamps = v),
            ),
            _SwitchRow(
              title: '去掉翻译行',
              subtitle: '保存时移除翻译歌词行',
              icon: Icons.translate,
              value: settings.stripTranslation,
              onChanged: (v) =>
                  settings.update(() => settings.stripTranslation = v),
            ),
            _SwitchRow(
              title: '默认覆盖已有文件',
              subtitle: '关闭时遇到同名文件会询问',
              icon: Icons.sync_alt,
              value: settings.overwrite,
              onChanged: (v) => settings.update(() => settings.overwrite = v),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }
}

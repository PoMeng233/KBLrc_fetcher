import 'package:flutter/material.dart';

import '../../core/models.dart';
import 'provider_branding.dart';

/// 歌词源开关（带健康状态指示灯）。
class ProviderChip extends StatelessWidget {
  const ProviderChip({
    super.key,
    required this.provider,
    required this.enabled,
    required this.health,
    required this.onToggle,
  });

  final String provider;
  final bool enabled;
  final ProviderHealth health;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final color = providerColor(provider);
    final healthText = switch (health) {
      ProviderHealth.unknown => '未检测',
      ProviderHealth.checking => '检测中…',
      ProviderHealth.ok => '可用',
      ProviderHealth.error => '不可用',
    };
    final dotColor = switch (health) {
      ProviderHealth.unknown => Theme.of(context).colorScheme.outlineVariant,
      ProviderHealth.checking => Colors.amber,
      ProviderHealth.ok => Colors.green,
      ProviderHealth.error => Theme.of(context).colorScheme.error,
    };
    return Tooltip(
      message: '${providerLabelOf(provider)}：$healthText',
      child: FilterChip(
        selected: enabled,
        showCheckmark: false,
        avatar: _HealthDot(color: dotColor),
        label: Text(
          providerLabelOf(provider),
          style: TextStyle(
            color: enabled ? color.withValues(alpha: 0.9) : null,
            fontWeight: enabled ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        selectedColor: color.withValues(alpha: 0.14),
        side: BorderSide(
          color: enabled ? color.withValues(alpha: 0.5) : Colors.transparent,
        ),
        onSelected: (_) => onToggle(),
      ),
    );
  }
}

class _HealthDot extends StatelessWidget {
  const _HealthDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

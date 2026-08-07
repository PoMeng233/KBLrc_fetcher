import 'package:flutter/material.dart';

import '../../core/models.dart';

/// 各歌词源的品牌色。
const Map<String, Color> providerBrandColors = {
  'lrclib': Color(0xFF3B82F6),
  'lyricsovh': Color(0xFF14B8A6),
  'kugou': Color(0xFFF97316),
  'kuwo': Color(0xFFA855F7),
  'netease': Color(0xFFEF4444),
  'qq': Color(0xFF22C55E),
};

Color providerColor(String provider) =>
    providerBrandColors[provider] ?? const Color(0xFF64748B);

/// 头像上的简短标识。
String providerShortLabel(String provider) => switch (provider) {
  'lrclib' => 'LR',
  'lyricsovh' => 'OV',
  'kugou' => '酷狗',
  'kuwo' => '酷我',
  'netease' => '网',
  'qq' => 'QQ',
  _ => provider.substring(0, 1).toUpperCase(),
};

String providerLabelOf(String provider) => providerCatalog[provider]?.label ?? provider;

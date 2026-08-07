/// 应用设置：加载/保存（shared_preferences），首次运行迁移 legacy 设置。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class AppSettings extends ChangeNotifier {
  static const _key = 'gui_settings_v4';

  /// 歌词源开关。
  final Map<String, bool> providers = {
    for (final p in providerCatalog.keys) p: true,
  };

  bool includeMetadata = true;
  bool stripTimestamps = false;
  bool stripTranslation = false;
  bool overwrite = false;
  NameFormat nameFormat = NameFormat.file;
  LyricMode lyricMode = LyricMode.auto;
  String outDir = '';
  ThemePreference theme = ThemePreference.system;
  bool compactMode = true;

  List<String> get enabledProviders =>
      [for (final e in providers.entries) if (e.value) e.key];

  /// 加载设置；无新设置时尝试导入 legacy/gui_settings.json。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        _apply(jsonDecode(raw) as Map<String, dynamic>);
        notifyListeners();
        return;
      } catch (_) {}
    }

    try {
      final legacyFile = File('legacy/gui_settings.json');
      if (await legacyFile.exists()) {
        final data = jsonDecode(await legacyFile.readAsString())
            as Map<String, dynamic>;
        _apply(data);
        await save();
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }

  Map<String, dynamic> toJson() => {
    'providers': providers,
    'include_metadata': includeMetadata,
    'strip_timestamps': stripTimestamps,
    'strip_translation': stripTranslation,
    'overwrite': overwrite,
    'name_format': nameFormat.name,
    'lyric_mode': lyricMode.name,
    'out_dir': outDir,
    'theme_mode': theme.name,
    'compact_mode': compactMode,
  };

  void _apply(Map<String, dynamic> data) {
    final pMap = data['providers'];
    if (pMap is Map) {
      for (final e in pMap.entries) {
        if (providers.containsKey(e.key) && e.value is bool) {
          providers[e.key as String] = e.value as bool;
        }
      }
    }
    includeMetadata = data['include_metadata'] as bool? ?? includeMetadata;
    stripTimestamps = data['strip_timestamps'] as bool? ?? stripTimestamps;
    stripTranslation = data['strip_translation'] as bool? ?? stripTranslation;
    overwrite = data['overwrite'] as bool? ?? overwrite;
    outDir = data['out_dir'] as String? ?? outDir;
    compactMode = data['compact_mode'] as bool? ?? compactMode;
    final nf = data['name_format'] as String?;
    if (nf != null) {
      nameFormat = NameFormat.values.asNameMap()[nf] ?? nameFormat;
    }
    final lm = data['lyric_mode'] as String?;
    if (lm != null) {
      lyricMode = LyricMode.values.asNameMap()[lm] ?? lyricMode;
    }
    final tm = data['theme_mode'] as String?;
    if (tm != null) {
      theme = ThemePreference.values.asNameMap()[tm] ?? theme;
    }
  }

  void update(void Function() mutate) {
    mutate();
    notifyListeners();
    save();
  }
}

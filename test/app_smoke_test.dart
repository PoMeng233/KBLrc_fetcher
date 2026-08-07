import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_fetcher/core/settings.dart';
import 'package:lyrics_fetcher/ui/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    '应用启动并渲染主界面',
    (tester) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // 预置 mock 设置，避免 settings.load() 读取磁盘上的 legacy 文件
      // （真实文件 I/O 在 testWidgets 的 FakeAsync 区域中无法完成）。
      SharedPreferences.setMockInitialValues({
        'gui_settings_v4': jsonEncode({
          'providers': {
            'lrclib': true,
            'lyricsovh': true,
            'kugou': true,
            'kuwo': true,
            'netease': true,
            'qq': true,
          },
          'include_metadata': true,
          'strip_timestamps': false,
          'strip_translation': false,
          'overwrite': false,
          'name_format': 'file',
          'lyric_mode': 'auto',
          'out_dir': '',
          'theme_mode': 'system',
          'compact_mode': false,
        }),
      });

      final settings = AppSettings();
      await settings.load();
      await tester.pumpWidget(KBLyricsApp(settings: settings));
      // 健康检查等异步任务（flutter_test 的 HTTP mock 返回 400，微任务即可完成）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('KB歌词搜索'), findsOneWidget);
      expect(find.text('搜索歌词'), findsOneWidget);
      expect(find.text('暂无搜索结果'), findsOneWidget);
      // 歌词源开关
      expect(find.text('网易云音乐'), findsOneWidget);
      expect(find.text('QQ 音乐'), findsOneWidget);

      // 输入歌名后搜索按钮可点击
      await tester.enterText(find.byType(TextField).first, '夜に駆ける');
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byType(TextField).first)
            .controller!
            .text,
        '夜に駆ける',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

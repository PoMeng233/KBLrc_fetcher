import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyrics_fetcher/core/lyrics_utils.dart';
import 'package:lyrics_fetcher/core/models.dart';
import 'package:lyrics_fetcher/core/save_service.dart';

LyricsCandidate _candidate({
  String source = 'netease',
  String title = '夜に駆ける',
  String artist = 'YOASOBI',
  String album = 'THE BOOK',
  String synced = '[00:01.00]あの日\n[00:05.50]あの時',
  String plain = 'あの日\nあの時',
  String translated = '[00:01.00]那一天\n[00:05.50]那一刻',
  double score = 0.0,
}) =>
    LyricsCandidate(
      source: source,
      title: title,
      artist: artist,
      album: album,
      syncedLyrics: synced,
      plainLyrics: plain,
      translatedLyrics: translated,
      score: score,
    );

void main() {
  group('sanitizeFilename', () {
    test('替换非法字符并清理空白', () {
      expect(sanitizeFilename('a<b>:"c'), 'a_b___c');
      expect(sanitizeFilename('  a   b  '), 'a b');
      expect(sanitizeFilename(''), 'lyrics');
      expect(sanitizeFilename('x' * 300).length, 180);
    });
  });

  group('normalizeText / similarity', () {
    test('归一化去除括号与高亮标签', () {
      expect(normalizeText('<em>夜</em>に駆ける (feat. A)'), '夜に駆ける');
      expect(normalizeText('Hello World!'), 'hello world');
    });

    test('相同文本相似度 1，不同文本接近 0', () {
      expect(similarity('夜に駆ける', '夜に駆ける'), 1.0);
      expect(similarity('abc', 'xyz'), lessThan(0.2));
      expect(similarity('', 'abc'), 0.0);
    });

    test('近似匹配高于无关匹配', () {
      expect(similarity('夜に駆ける', '夜に駆け'), greaterThan(0.7));
    });
  });

  group('parseFilenameVariants', () {
    test('解析 "歌手 - 歌名" 与 "歌名 - 歌手" 变体', () {
      final variants = parseFilenameVariants('YOASOBI - 夜に駆ける');
      expect(variants.length, greaterThanOrEqualTo(3));
      expect(variants, contains(('YOASOBI - 夜に駆ける', '')));
      expect(variants, contains(('夜に駆ける', 'YOASOBI')));
      expect(variants, contains(('YOASOBI', '夜に駆ける')));
    });

    test('无分隔符时仅有一个变体', () {
      expect(parseFilenameVariants('ただの曲'), [('ただの曲', '')]);
    });
  });

  group('buildManualQuery', () {
    test('歌手为空时从歌名生成变体', () {
      final q = buildManualQuery(title: 'A - B');
      expect(q.searchVariants, isNotEmpty);
      expect(q.searchVariants.first, ('A - B', ''));
    });

    test('手动查询无 sourceFile', () {
      final q = buildManualQuery(title: 'T', artist: 'A', duration: 120);
      expect(q.sourceFile, isNull);
      expect(q.duration, 120);
      expect(q.searchVariants, [( 'T', 'A')]);
    });
  });

  group('LRC 文本处理', () {
    test('removeLrcTimestamps 去掉时间戳与元数据行', () {
      const lrc = '[ti:title]\n[00:01.00]line1\n[00:02.5]line2\n';
      expect(removeLrcTimestamps(lrc), 'line1\nline2');
    });

    test('cleanPlainLyrics 去除空行', () {
      expect(cleanPlainLyrics('a\n\n  \nb\n'), 'a\nb');
    });

    test('isTimestampedLyric 识别时间轴文本', () {
      expect(isTimestampedLyric('[00:01.00]x'), isTrue);
      expect(isTimestampedLyric('plain text'), isFalse);
    });
  });

  group('renderLrc', () {
    test('auto 模式优先时间轴并写入元数据', () {
      final text = renderLrc(_candidate());
      expect(text, contains('[ti:夜に駆ける]'));
      expect(text, contains('[ar:YOASOBI]'));
      expect(text, contains('[by:KBlrc_fetcher]'));
      expect(text, contains('[00:01.00]あの日'));
    });

    test('不写入元数据', () {
      final text = renderLrc(_candidate(), includeMetadata: false);
      expect(text, isNot(contains('[ti:')));
      expect(text, isNot(contains('[by:')));
    });

    test('plain 模式输出纯文本', () {
      final text = renderLrc(_candidate(), lyricMode: LyricMode.plain);
      expect(text, isNot(contains('[00:')));
      expect(text, contains('あの日'));
    });

    test('synced 模式强制时间轴', () {
      final text = renderLrc(
        _candidate(synced: '[00:01.00]a'),
        lyricMode: LyricMode.synced,
      );
      expect(text, contains('[00:01.00]a'));
    });

    test('stripTimestamps 去除全部时间戳', () {
      final text = renderLrc(_candidate(), stripTimestamps: true);
      expect(text, isNot(contains('[00:')));
      expect(text, contains('あの日'));
    });

    test('stripTranslationLines 只移除翻译行', () {
      final cand = _candidate(
        synced: '[00:01.00]あの日\n[00:05.50]あの時',
        translated: '[00:01.00]那一天\n[00:05.50]那一刻',
      );
      final text = renderLrc(cand, stripTranslationLines: true);
      expect(text, contains('あの日'));
      expect(text, isNot(contains('那一天')));
    });

    test('无歌词时仅输出元数据头', () {
      final text = renderLrc(LyricsCandidate(source: 'x'));
      expect(text, '[by:KBlrc_fetcher]\n');
    });
  });

  group('chooseOutputFilename', () {
    final query = buildManualQuery(title: 'T', artist: 'A');

    test('titleArtist 格式', () {
      expect(
        chooseOutputFilename(_candidate(), query, NameFormat.titleArtist),
        '夜に駆ける - YOASOBI.lrc',
      );
    });

    test('file 格式无源文件时用 歌名-歌手', () {
      expect(
        chooseOutputFilename(_candidate(), query, NameFormat.file),
        '夜に駆ける - YOASOBI.lrc',
      );
    });

    test('有源文件时使用同名', () {
      final q = TrackQuery(title: 'T', sourceFile: r'C:\music\song.flac');
      expect(
        chooseOutputFilename(_candidate(), q, NameFormat.file),
        'song.lrc',
      );
    });

    test('非法字符被清洗', () {
      final q = buildManualQuery(title: 'T', artist: 'A');
      final cand = _candidate(title: 'a/b:c');
      expect(
        chooseOutputFilename(cand, q, NameFormat.titleArtist),
        'a_b_c - YOASOBI.lrc',
      );
    });
  });

  group('评分与去重', () {
    test('时间轴候选得分更高', () {
      final q = buildManualQuery(title: '夜に駆ける', artist: 'YOASOBI');
      final synced = _candidate();
      final plain = _candidate(synced: '', plain: 'あの日');
      expect(
        scoreCandidate(q, synced),
        greaterThan(scoreCandidate(q, plain)),
      );
    });

    test('deduplicateCandidates 按组保留最高分', () {
      final q = buildManualQuery(title: 'T');
      final a = _candidate(source: 'qq', synced: '[00:01.00]line one', score: 50);
      final b = _candidate(source: 'qq', synced: '[00:01.00]line one', score: 90);
      final c = _candidate(source: 'kugou', synced: '[00:01.00]other', score: 30);
      final deduped = deduplicateCandidates([a, b, c], query: q);
      expect(deduped, hasLength(2));
      expect(deduped.first.score, 90);
    });

    test('rankAndDeduplicateCandidates 重新打分排序', () {
      final q = buildManualQuery(title: '夜に駆ける', artist: 'YOASOBI');
      final cands = [
        _candidate(source: 'lyricsovh', synced: '', plain: 'text'),
        _candidate(source: 'netease'),
      ];
      final ranked = rankAndDeduplicateCandidates(cands, q);
      expect(ranked.first.source, 'netease');
    });
  });

  group('SaveService', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lrc_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    SaveOptions options() => SaveOptions(
      outDir: tempDir.path,
      lyricMode: LyricMode.auto,
      includeMetadata: true,
    );

    test('保存 UTF-8 BOM 编码并生成 .lrc', () async {
      final q = buildManualQuery(title: 'T', artist: 'A');
      final outcome = await const SaveService().save(
        options: options(),
        candidate: _candidate(),
        query: q,
        policy: ConflictPolicy.overwrite,
      );
      expect(outcome.success, isTrue);
      final file = File(outcome.path!);
      expect(await file.exists(), isTrue);
      final bytes = await file.readAsBytes();
      expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(bytes.sublist(3)), contains('[ti:夜に駆ける]'));
    });

    test('ask 策略遇到已存在文件返回 conflict', () async {
      final q = buildManualQuery(title: 'T', artist: 'A');
      final service = const SaveService();
      await service.save(
        options: options(),
        candidate: _candidate(),
        query: q,
        policy: ConflictPolicy.overwrite,
      );
      final second = await service.save(
        options: options(),
        candidate: _candidate(),
        query: q,
        policy: ConflictPolicy.ask,
      );
      expect(second.conflict, isTrue);
    });

    test('rename 策略追加序号', () async {
      final q = buildManualQuery(title: 'T', artist: 'A');
      final service = const SaveService();
      await service.save(
        options: options(),
        candidate: _candidate(),
        query: q,
        policy: ConflictPolicy.overwrite,
      );
      final renamed = await service.save(
        options: options(),
        candidate: _candidate(),
        query: q,
        policy: ConflictPolicy.rename,
      );
      expect(renamed.success, isTrue);
      expect(baseNameOf(renamed.path!), contains('('));
    });

    test('skip 策略返回 skipped', () async {
      final q = buildManualQuery(title: 'T', artist: 'A');
      final service = const SaveService();
      await service.save(
        options: options(),
        candidate: _candidate(),
        query: q,
        policy: ConflictPolicy.overwrite,
      );
      final skipped = await service.save(
        options: options(),
        candidate: _candidate(),
        query: q,
        policy: ConflictPolicy.skip,
      );
      expect(skipped.skipped, isTrue);
      expect(skipped.success, isTrue);
    });

    test('overwrite 策略直接覆盖', () async {
      final q = buildManualQuery(title: 'T', artist: 'A');
      final service = const SaveService();
      final first = await service.save(
        options: options(),
        candidate: _candidate(),
        query: q,
        policy: ConflictPolicy.overwrite,
      );
      await File(first.path!).writeAsString('old');
      final second = await service.save(
        options: options(),
        candidate: _candidate(),
        query: q,
        policy: ConflictPolicy.overwrite,
      );
      expect(second.success, isTrue);
      expect(second.path, first.path);
      expect(await File(second.path!).readAsString(), isNot('old'));
    });

    test('无 outDir 且有源文件时保存到歌曲目录', () async {
      final song = File(joinPath(tempDir.path, 'song.mp3'));
      await song.writeAsBytes([]);
      final q = TrackQuery(
        title: 'T',
        sourceFile: song.path,
        searchVariants: const [('T', '')],
      );
      final outcome = await const SaveService().save(
        options: SaveOptions(),
        candidate: _candidate(),
        query: q,
        policy: ConflictPolicy.overwrite,
      );
      expect(outcome.success, isTrue);
      expect(baseNameOf(outcome.path!), 'song.lrc');
      expect(dirNameOf(outcome.path!), tempDir.path);
    });
  });

  group('findAudioFiles', () {
    test('递归查找音频文件', () async {
      final dir = await Directory.systemTemp.createTemp('lrc_scan_');
      try {
        await File(joinPath(dir.path, 'a.mp3')).writeAsBytes([]);
        await File(joinPath(dir.path, 'b.txt')).writeAsBytes([]);
        await Directory(joinPath(dir.path, 'sub')).create();
        await File(joinPath(dir.path, 'sub', 'c.flac')).writeAsBytes([]);
        final files = await findAudioFiles(dir.path);
        expect(files, hasLength(2));
        expect(files.first, endsWith('a.mp3'));
        expect(files.last, endsWith('c.flac'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}

// path 工具的简单封装（避免测试引入额外依赖）
String baseNameOf(String path) => path.split(RegExp(r'[/\\]')).last;

String dirNameOf(String path) {
  final parts = path.split(RegExp(r'[/\\]'))..removeLast();
  return parts.join('\\');
}

String joinPath(String a, String b, [String? c]) =>
    '$a${Platform.pathSeparator}$b${c == null ? '' : '${Platform.pathSeparator}$c'}';

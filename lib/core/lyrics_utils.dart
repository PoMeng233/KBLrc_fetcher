/// 歌词处理工具函数（从 Python 版移植并优化）。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:audiotags/audiotags.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

String providerLabel(String provider) =>
    providerCatalog[provider]?.label ?? provider;

/// 清洗非法文件名字符。
String sanitizeFilename(String name) {
  var result = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  result = result.replaceAll(RegExp(r'\s+'), ' ');
  if (result.isEmpty) return 'lyrics';
  return result.length > 180 ? result.substring(0, 180) : result;
}

/// 归一化文本用于相似度比较。
String normalizeText(String text) {
  var result = text.trim().toLowerCase();
  result = result.replaceAll(RegExp(r'</?em[^>]*>', caseSensitive: false), '');
  result = result.replaceAll(RegExp(r'\([^)]*\)'), ' ');
  result = result.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
  result = result.replaceAll(
    RegExp(r'[^\p{L}\p{N}_]+', unicode: true),
    ' ',
  );
  return result.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 基于 Levenshtein 距离的相似度（0.0 ~ 1.0）。
double similarity(String a, String b) {
  a = normalizeText(a);
  b = normalizeText(b);
  if (a.isEmpty || b.isEmpty) return 0.0;
  if (a == b) return 1.0;
  if (a.length > b.length) {
    final t = a;
    a = b;
    b = t;
  }
  final m = a.length;
  final n = b.length;
  final dp = List<int>.filled(n + 1, 0);
  for (var j = 0; j <= n; j++) {
    dp[j] = j;
  }
  for (var i = 1; i <= m; i++) {
    var prev = dp[0];
    dp[0] = i;
    for (var j = 1; j <= n; j++) {
      final tmp = dp[j];
      dp[j] = math.min(
        math.min(dp[j] + 1, dp[j - 1] + 1),
        prev + (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1),
      );
      prev = tmp;
    }
  }
  return 1.0 - dp[n] / math.max(m, n);
}

/// 去掉 <em> 高亮标签。
String stripEmphasisTags(String text) => text.trim().replaceAll(
      RegExp(r'</?em[^>]*>', caseSensitive: false),
      '',
    ).trim();

/// 从标签字典取第一个有效值。
String firstTag(Map<String, dynamic> tags, List<String> keys) {
  for (final key in keys) {
    final value = tags[key];
    if (value is List && value.isNotEmpty) {
      final s = stripEmphasisTags('${value.first}');
      if (s.isNotEmpty) return s;
    } else if (value is String && value.trim().isNotEmpty) {
      return stripEmphasisTags(value);
    }
  }
  return '';
}

List<(String, String)> _dedupVariants(List<(String, String)> variants) {
  final seen = <String>{};
  final result = <(String, String)>[];
  for (final (title, artist) in variants) {
    final key = '${title.trim().toLowerCase()}|${artist.trim().toLowerCase()}';
    if (seen.add(key)) {
      result.add((title.trim(), artist.trim()));
    }
  }
  return result;
}

/// 从文件名解析 (标题, 歌手) 变体。
List<(String, String)> parseFilenameVariants(String stem) {
  stem = stem.trim();
  final variants = <(String, String)>[(stem, '')];
  for (final sep in [' - ', ' — ', ' – ', '-', '—', '–']) {
    final idx = stem.indexOf(sep);
    if (idx >= 0) {
      final left = stem.substring(0, idx).trim();
      final right = stem.substring(idx + sep.length).trim();
      if (left.isNotEmpty && right.isNotEmpty) {
        variants.add((right, left));
        variants.add((left, right));
      }
      break;
    }
  }
  return _dedupVariants(variants);
}

/// 读取音频文件元数据，构造搜索请求。
Future<TrackQuery> readAudioMetadata(String path) async {
  var title = '';
  var artist = '';
  var album = '';
  int? duration;

  try {
    final tag = await AudioTags.read(path);
    if (tag != null) {
      title = (tag.title ?? '').trim();
      artist = (tag.trackArtist ?? '').trim();
      if (artist.isEmpty) artist = (tag.albumArtist ?? '').trim();
      album = (tag.album ?? '').trim();
      if (tag.duration != null && tag.duration! > 0) {
        duration = (tag.duration! / 1000).round();
      }
    }
  } catch (_) {
    // 无法读取元数据时退化为文件名解析
  }

  final stem = p.basenameWithoutExtension(path);
  if (title.isEmpty) title = stem;

  var variants = parseFilenameVariants(stem);
  if (artist.isNotEmpty && title.isNotEmpty) {
    variants.insert(0, (title, artist));
  }
  variants = _dedupVariants(variants);

  return TrackQuery(
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    sourceFile: path,
    searchVariants: variants,
  );
}

/// 手动输入构造搜索请求。
TrackQuery buildManualQuery({
  required String title,
  String artist = '',
  String album = '',
  int? duration,
}) {
  title = title.trim();
  artist = artist.trim();
  var variants = <(String, String)>[(title, artist)];
  if (artist.isEmpty) {
    variants.addAll(parseFilenameVariants(title));
  }
  variants = _dedupVariants(variants);
  return TrackQuery(
    title: title,
    artist: artist,
    album: album.trim(),
    duration: duration,
    searchVariants: variants,
  );
}

/// 候选评分（与 Python 版保持一致）。
double scoreCandidate(TrackQuery query, LyricsCandidate cand) {
  var score = (sourcePriority[cand.source] ?? 0).toDouble();
  score += cand.hasSynced ? 100 : 12;
  score += cand.hasTranslation ? 6 : 0;

  if (query.title.isNotEmpty) {
    score += similarity(query.title, cand.title.isEmpty ? query.title : cand.title) * 40;
  }
  if (query.artist.isNotEmpty) {
    score += similarity(query.artist, cand.artist.isEmpty ? query.artist : cand.artist) * 25;
  }
  if (query.album.isNotEmpty && cand.album.isNotEmpty) {
    score += similarity(query.album, cand.album) * 10;
  }

  if (query.duration != null && cand.duration != null) {
    final diff = (query.duration! - cand.duration!).abs();
    if (diff <= 2) {
      score += 15;
    } else if (diff <= 5) {
      score += 8;
    } else if (diff <= 12) {
      score += 3;
    }
  }
  return score;
}

bool isTimestampedLyric(String text) => RegExp(
  r'^\[\d{2}:\d{2}(?:\.\d{1,3})?\]',
  multiLine: true,
).hasMatch(text);

/// 去掉 LRC 时间戳（同时移除元数据行）。
String removeLrcTimestamps(String text) {
  final lines = <String>[];
  for (final rawLine in text.split('\n')) {
    var line = rawLine.replaceFirst('\uFEFF', '').trim();
    if (RegExp(r'^\[(?:ar|ti|al|by|offset):.*?\]\s*$', caseSensitive: false)
        .hasMatch(line)) {
      continue;
    }
    line = line.replaceAll(
      RegExp(r'(?:\[\d{2}:\d{2}(?:\.\d{1,3})?\])+'),
      '',
    ).trim();
    if (line.isNotEmpty) lines.add(line);
  }
  return lines.join('\n');
}

String cleanPlainLyrics(String text) {
  final lines = <String>[];
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trimRight();
    if (line.trim().isNotEmpty) lines.add(line);
  }
  return lines.join('\n');
}

/// 按保存模式选取最佳文本。
String candidateBestText(LyricsCandidate candidate, LyricMode lyricMode) {
  switch (lyricMode) {
    case LyricMode.synced:
      return candidate.syncedLyrics.trim();
    case LyricMode.plain:
      if (candidate.plainLyrics.trim().isNotEmpty) {
        return cleanPlainLyrics(candidate.plainLyrics);
      }
      return removeLrcTimestamps(candidate.syncedLyrics);
    case LyricMode.auto:
      if (candidate.hasSynced) return candidate.syncedLyrics.trim();
      if (candidate.plainLyrics.trim().isNotEmpty) {
        return cleanPlainLyrics(candidate.plainLyrics);
      }
      return removeLrcTimestamps(candidate.syncedLyrics);
  }
}

/// 渲染最终 LRC 文本。
String renderLrc(
  LyricsCandidate candidate, {
  LyricMode lyricMode = LyricMode.auto,
  bool includeMetadata = true,
  bool stripTimestamps = false,
  bool stripTranslationLines = false,
}) {
  var body = candidateBestText(candidate, lyricMode);

  if (stripTimestamps && body.isNotEmpty) {
    body = removeLrcTimestamps(body);
  }

  body = isTimestampedLyric(body) ? body.trim() : cleanPlainLyrics(body);

  if (stripTranslationLines &&
      body.isNotEmpty &&
      candidate.translatedLyrics.trim().isNotEmpty) {
    // 仅移除确定来自 translated_lyrics 的行，避免误删原文。
    final stampRe = RegExp(r'^\[\d{2}:\d{2}(?:\.\d{1,3})?\]\s*');
    final translatedLines = <String>{};
    for (final line in candidate.translatedLyrics.split('\n')) {
      final cleaned = line.trim();
      if (cleaned.isEmpty) continue;
      translatedLines.add(normalizeText(cleaned.replaceFirst(stampRe, '')));
    }
    translatedLines.remove('');

    if (translatedLines.isNotEmpty) {
      final filtered = <String>[];
      for (final line in body.split('\n')) {
        final norm = normalizeText(line.replaceFirst(stampRe, ''));
        if (norm.isNotEmpty && translatedLines.contains(norm)) continue;
        filtered.add(line);
      }
      body = filtered.join('\n').trim();
    }
  }

  final header = <String>[];
  if (includeMetadata) {
    if (candidate.title.isNotEmpty) header.add('[ti:${candidate.title}]');
    if (candidate.artist.isNotEmpty) header.add('[ar:${candidate.artist}]');
    if (candidate.album.isNotEmpty) header.add('[al:${candidate.album}]');
    header.add('[by:KBlrc_fetcher]');
  }

  if (header.isNotEmpty) {
    final lines = <String>[...header];
    if (body.trim().isNotEmpty) {
      lines.add('');
      lines.addAll(body.split('\n'));
    }
    return '${lines.join('\n')}\n';
  }
  final stripped = body.trim();
  return stripped.isNotEmpty ? '$stripped\n' : '';
}

/// 计算输出文件名（与 Python 版保持一致）。
String chooseOutputFilename(
  LyricsCandidate candidate,
  TrackQuery query,
  NameFormat outputMode,
) {
  if (query.sourceFile != null && outputMode == NameFormat.file) {
    return '${p.basenameWithoutExtension(query.sourceFile!)}.lrc';
  }

  final title = (candidate.title.isNotEmpty
          ? candidate.title
          : query.title.isNotEmpty
          ? query.title
          : query.sourceFile != null
          ? p.basenameWithoutExtension(query.sourceFile!)
          : 'lyrics')
      .trim();
  final artist = candidate.artist.isNotEmpty ? candidate.artist : query.artist;

  if (outputMode == NameFormat.titleArtist) {
    if (artist.trim().isNotEmpty) {
      return '${sanitizeFilename(title)} - ${sanitizeFilename(artist)}.lrc';
    }
    return '${sanitizeFilename(title)}.lrc';
  }

  if (query.sourceFile != null) {
    return '${p.basenameWithoutExtension(query.sourceFile!)}.lrc';
  }
  if (artist.trim().isNotEmpty) {
    return '${sanitizeFilename(title)} - ${sanitizeFilename(artist)}.lrc';
  }
  return '${sanitizeFilename(title)}.lrc';
}

/// 去重候选，保留每个分组中得分最高者。
List<LyricsCandidate> deduplicateCandidates(
  List<LyricsCandidate> candidates, {
  TrackQuery? query,
}) {
  final bestByKey = <String, LyricsCandidate>{};
  final stampRe = RegExp(r'^\[\d{2}:\d{2}(?:\.\d{1,3})?\]\s*');

  for (final cand in candidates) {
    String lyricsHint = '';
    final body = cand.syncedLyrics.isNotEmpty
        ? cand.syncedLyrics
        : cand.plainLyrics.isNotEmpty
        ? cand.plainLyrics
        : cand.translatedLyrics;
    for (final line in body.split('\n')) {
      final cleaned = line.trim();
      if (cleaned.isNotEmpty) {
        lyricsHint = normalizeText(cleaned.replaceFirst(stampRe, ''));
        if (lyricsHint.length > 80) lyricsHint = lyricsHint.substring(0, 80);
        break;
      }
    }

    final fallbackTitle = cand.title.isNotEmpty
        ? cand.title
        : (query?.title ?? '');
    final fallbackArtist = cand.artist.isNotEmpty
        ? cand.artist
        : (query?.artist ?? '');

    final key =
        '${cand.source}|${normalizeText(fallbackTitle)}|${normalizeText(fallbackArtist)}|$lyricsHint';

    final existing = bestByKey[key];
    if (existing == null || cand.score > existing.score) {
      bestByKey[key] = cand;
    }
  }

  final result = bestByKey.values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  return result;
}

/// 打分 + 去重排序。
List<LyricsCandidate> rankAndDeduplicateCandidates(
  List<LyricsCandidate> candidates,
  TrackQuery query,
) {
  for (final cand in candidates) {
    cand.score = scoreCandidate(query, cand);
  }
  return deduplicateCandidates(candidates, query: query);
}

/// 递归查找音频文件。
Future<List<String>> findAudioFiles(
  String dirPath, {
  bool recursive = true,
}) async {
  final results = <String>[];
  try {
    await for (final entity in Directory(dirPath).list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity is File &&
          audioExtensions.contains(p.extension(entity.path).toLowerCase())) {
        results.add(entity.path);
      }
    }
  } catch (_) {}
  results.sort();
  return results;
}

/// 格式化秒数为 mm:ss 或 h:mm:ss。
String formatDuration(int? seconds) {
  if (seconds == null || seconds <= 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

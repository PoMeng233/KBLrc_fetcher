/// 网易云音乐歌词源。
library;

import 'dart:convert';

import '../lyrics_utils.dart';
import '../models.dart';
import 'base.dart';

class NeteaseProvider implements LyricsProvider {
  const NeteaseProvider();

  @override
  String get id => 'netease';

  @override
  String get label => '网易云音乐';

  static const _headers = {
    'Referer': 'https://music.163.com/',
  };

  @override
  Future<bool> checkHealth() async {
    try {
      await httpGet(
        'https://music.163.com/api/search/get/web',
        query: {'s': 'test', 'type': 1, 'offset': 0, 'limit': 1},
        headers: _headers,
        timeout: const Duration(seconds: 5),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<LyricsCandidate>> search(TrackQuery query) async {
    final results = <LyricsCandidate>[];

    for (final (title, artist) in query.searchVariants) {
      final keyword = '$title $artist'.trim();
      if (keyword.isEmpty) continue;

      try {
        final resp = await httpGet(
          'https://music.163.com/api/search/get/web',
          query: {'s': keyword, 'type': 1, 'offset': 0, 'limit': 8},
          headers: _headers,
        );
        final data = jsonDecode(decodeBody(resp));
        final songs =
            ((((data as Map<String, dynamic>)['result'] as Map<String, dynamic>?)
                        ?['songs']) as List? ??
                    const [])
                .take(5)
                .whereType<Map<String, dynamic>>()
                .toList();

        for (final song in songs) {
          final songId = song['id'];
          if (songId == null) continue;

          String lrc = '';
          String tlyric = '';
          try {
            final lyricResp = await httpGet(
              'https://music.163.com/api/song/lyric',
              query: {'id': songId, 'lv': -1, 'kv': -1, 'tv': -1},
              headers: _headers,
            );
            final lyricData = jsonDecode(decodeBody(lyricResp));
            final lrcObj = (lyricData as Map<String, dynamic>)['lrc'];
            final tlrcObj = lyricData['tlyric'];
            lrc = (lrcObj is Map<String, dynamic> && lrcObj['lyric'] is String)
                ? lrcObj['lyric'] as String
                : '';
            tlyric =
                (tlrcObj is Map<String, dynamic> && tlrcObj['lyric'] is String)
                ? tlrcObj['lyric'] as String
                : '';
          } catch (_) {
            continue;
          }
          if (lrc.isEmpty && tlyric.isEmpty) continue;

          final artists = (song['artists'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map((a) => '${a['name'] ?? ''}')
              .where((s) => s.isNotEmpty)
              .join(', ');
          final albumObj = song['album'];
          final album = albumObj is Map<String, dynamic>
              ? '${albumObj['name'] ?? ''}'
              : '';
          final dur = song['duration'];
          final duration = dur is num && dur > 0 ? (dur / 1000).round() : null;

          results.add(
            LyricsCandidate(
              source: id,
              title: '${song['name'] ?? title}',
              artist: artists.isNotEmpty ? artists : artist,
              album: album,
              duration: duration,
              syncedLyrics: lrc,
              translatedLyrics: tlyric,
              plainLyrics: lrc.isNotEmpty
                  ? removeLrcTimestamps(lrc)
                  : cleanPlainLyrics(tlyric),
            ),
          );
        }
      } catch (_) {
        continue;
      }
    }

    return [for (final r in results) if (r.hasAny) r];
  }
}

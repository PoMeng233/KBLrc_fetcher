/// 酷狗音乐歌词源。
library;

import 'dart:convert';

import '../lyrics_utils.dart';
import '../models.dart';
import 'base.dart';

class KugouProvider implements LyricsProvider {
  const KugouProvider();

  @override
  String get id => 'kugou';

  @override
  String get label => '酷狗音乐';

  static const _headers = {
    'Referer': 'https://www.kugou.com/',
  };

  @override
  Future<bool> checkHealth() async {
    try {
      await httpGet(
        'https://mobilecdn.kugou.com/api/v3/search/song',
        query: {'format': 'json', 'keyword': 'test', 'page': 1, 'pagesize': 3, 'showtype': 1},
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
      final keyword = '$artist - $title'.replaceAll(RegExp(r'^\s+|\s+$'), '').trimLeft().trimRight();
      if (keyword == '-' || keyword.isEmpty) continue;

      final songs = <Map<String, dynamic>>[];

      // endpoint 1: mobilecdn
      try {
        final resp = await httpGet(
          'https://mobilecdn.kugou.com/api/v3/search/song',
          query: {
            'format': 'json',
            'keyword': keyword,
            'page': 1,
            'pagesize': 10,
            'showtype': 1,
          },
          headers: _headers,
        );
        final data = jsonDecode(decodeBody(resp));
        final info =
            (((data as Map<String, dynamic>)['data'] as Map<String, dynamic>?)
                    ?['info']) as List? ??
                const [];
        songs.addAll(info.take(8).whereType<Map<String, dynamic>>());
      } catch (_) {}

      // endpoint 2: legacy search fallback
      if (songs.isEmpty) {
        try {
          final resp = await httpGet(
            'https://songsearch.kugou.com/song_search_v2',
            query: {
              'keyword': keyword,
              'page': 1,
              'pagesize': 10,
              'platform': 'WebFilter',
              'tag': 'em',
            },
            headers: _headers,
          );
          final data = jsonDecode(decodeBody(resp));
          final lists =
              (((data as Map<String, dynamic>)['data'] as Map<String, dynamic>?)
                      ?['lists']) as List? ??
                  const [];
          songs.addAll(lists.take(8).whereType<Map<String, dynamic>>());
        } catch (_) {}
      }

      for (final song in songs) {
        final songHash = (song['hash'] ??
                song['FileHash'] ??
                song['320hash'] ??
                song['sqhash'])
            .toString();
        if (songHash.isEmpty) continue;

        int? durationSec;
        var durationMs = '';
        final durationVal = song['duration'] ?? song['Duration'];
        if (durationVal != null) {
          try {
            durationSec = int.parse('$durationVal');
            durationMs = '${durationSec * 1000}';
          } catch (_) {
            durationSec = null;
            durationMs = '';
          }
        }

        var candidates = <Map<String, dynamic>>[];
        try {
          final candResp = await httpGet(
            'https://krcs.kugou.com/search',
            query: {
              'ver': 1,
              'man': 'yes',
              'client': 'mobi',
              'keyword': keyword,
              'duration': durationMs,
              'hash': songHash,
              'album_audio_id': song['album_audio_id'] ?? '',
            },
            headers: _headers,
          );
          final candData = jsonDecode(decodeBody(candResp));
          candidates =
              ((candData as Map<String, dynamic>)['candidates'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .toList();
        } catch (_) {
          candidates = [];
        }

        if (candidates.isEmpty) continue;

        // 依次尝试候选行，取第一个可用的
        for (final item in candidates.take(3)) {
          String content;
          try {
            final lyricResp = await httpGet(
              'https://lyrics.kugou.com/download',
              query: {
                'ver': 1,
                'client': 'pc',
                'id': item['id'],
                'accesskey': item['accesskey'],
                'fmt': 'lrc',
                'charset': 'utf8',
              },
              headers: _headers,
            );
            final lyricData = jsonDecode(decodeBody(lyricResp));
            content = ((lyricData as Map<String, dynamic>)['content'] as String?) ?? '';
          } catch (_) {
            content = '';
          }

          if (content.isEmpty) continue;

          String decoded;
          try {
            decoded = utf8.decode(base64.decode(content), allowMalformed: true);
          } catch (_) {
            decoded = content;
          }
          decoded = decoded.trim();
          if (decoded.isEmpty) continue;

          results.add(
            LyricsCandidate(
              source: id,
              title: stripEmphasisTags(
                '${song['songname'] ?? song['SongName'] ?? title}',
              ),
              artist: stripEmphasisTags(
                '${song['singername'] ?? song['SingerName'] ?? artist}',
              ),
              album: stripEmphasisTags(
                '${song['album_name'] ?? song['AlbumName'] ?? ''}',
              ),
              duration: durationSec,
              syncedLyrics: decoded,
              plainLyrics: removeLrcTimestamps(decoded),
            ),
          );
          break;
        }
      }
    }

    return [for (final r in results) if (r.hasAny) r];
  }
}

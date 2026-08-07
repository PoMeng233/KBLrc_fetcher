/// QQ 音乐歌词源。
library;

import 'dart:convert';

import '../lyrics_utils.dart';
import '../models.dart';
import 'base.dart';

class QqProvider implements LyricsProvider {
  const QqProvider();

  @override
  String get id => 'qq';

  @override
  String get label => 'QQ 音乐';

  static const _headers = {
    'Referer': 'https://y.qq.com/',
  };

  @override
  Future<bool> checkHealth() async {
    try {
      await httpGet(
        'https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg',
        query: {'key': 'test', 'format': 'json', 'platform': 'yqq.json', 'g_tk': 5381},
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

      final songs = <Map<String, dynamic>>[];

      // endpoint 1: classic search
      try {
        final resp = await httpGet(
          'https://c.y.qq.com/soso/fcgi-bin/client_search_cp',
          query: {
            'ct': 24,
            'qqmusic_ver': 1298,
            'new_json': 1,
            'remoteplace': 'txt.yqq.song',
            'searchid': 0,
            't': 0,
            'aggr': 1,
            'cr': 1,
            'catZhida': 1,
            'lossless': 0,
            'flag_qc': 0,
            'p': 1,
            'n': 10,
            'w': keyword,
            'g_tk': 5381,
            'format': 'json',
            'inCharset': 'utf8',
            'outCharset': 'utf-8',
            'notice': 0,
            'platform': 'yqq.json',
            'needNewCode': 0,
          },
          headers: _headers,
        );
        final data = safeJsonFromJsonp(decodeBody(resp));
        final list =
            ((((data as Map<String, dynamic>)['data'] as Map<String, dynamic>?)
                        ?['song'] as Map<String, dynamic>?)
                    ?['list']) as List? ??
                const [];
        songs.addAll(list.take(8).whereType<Map<String, dynamic>>());
      } catch (_) {}

      // endpoint 2: smartbox fallback
      if (songs.isEmpty) {
        try {
          final resp = await httpGet(
            'https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg',
            query: {
              'key': keyword,
              'format': 'json',
              'inCharset': 'utf-8',
              'outCharset': 'utf-8',
              'platform': 'yqq.json',
              'g_tk': 5381,
            },
            headers: _headers,
          );
          final data = safeJsonFromJsonp(decodeBody(resp));
          final itemlist =
              ((((data as Map<String, dynamic>)['data'] as Map<String, dynamic>?)
                          ?['song'] as Map<String, dynamic>?)
                      ?['itemlist']) as List? ??
                  const [];
          songs.addAll(itemlist.take(8).whereType<Map<String, dynamic>>());
        } catch (_) {}
      }

      for (final song in songs) {
        final songmid = '${song['mid'] ?? song['songmid'] ?? ''}';
        if (songmid.isEmpty) continue;

        var lrc = '';
        var trans = '';

        // endpoint A: json lyric with plain text
        try {
          final lyricResp = await httpGet(
            'https://i.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
            query: {
              'songmid': songmid,
              'format': 'json',
              'nobase64': 1,
              'g_tk': 5381,
              'inCharset': 'utf-8',
              'outCharset': 'utf-8',
              'notice': 0,
              'platform': 'yqq.json',
              'needNewCode': 0,
            },
            headers: _headers,
          );
          final lyricData = safeJsonFromJsonp(decodeBody(lyricResp));
          lrc = '${lyricData['lyric'] ?? ''}';
          trans = '${lyricData['trans'] ?? ''}';
        } catch (_) {
          lrc = '';
          trans = '';
        }

        // endpoint B: fallback base64 lyric
        if (lrc.isEmpty && trans.isEmpty) {
          try {
            final lyricResp = await httpGet(
              'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric.fcg',
              query: {
                'songmid': songmid,
                'format': 'json',
                'nobase64': 0,
                'platform': 'yqq',
                'g_tk': 5381,
              },
              headers: _headers,
            );
            final lyricData = safeJsonFromJsonp(decodeBody(lyricResp));
            final lrcB64 = '${lyricData['lyric'] ?? ''}';
            final transB64 = '${lyricData['trans'] ?? ''}';
            if (lrcB64.isNotEmpty) {
              try {
                lrc = utf8.decode(base64.decode(lrcB64), allowMalformed: true);
              } catch (_) {
                lrc = '';
              }
            }
            if (transB64.isNotEmpty) {
              try {
                trans = utf8.decode(base64.decode(transB64), allowMalformed: true);
              } catch (_) {
                trans = '';
              }
            }
          } catch (_) {}
        }

        if (lrc.isEmpty && trans.isEmpty) continue;

        final singers = (song['singer'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((s) => '${s['name'] ?? ''}')
            .where((s) => s.isNotEmpty)
            .join(', ');
        final singerRaw = song['singer'];
        final finalSingers = singers.isNotEmpty
            ? singers
            : (singerRaw is String ? singerRaw : '');

        String album;
        final albumObj = song['album'];
        if (albumObj is Map<String, dynamic>) {
          album = '${albumObj['name'] ?? ''}';
        } else {
          album = '${song['albumName'] ?? ''}';
        }

        int? duration;
        final interval = '${song['interval'] ?? ''}';
        if (RegExp(r'^\d+$').hasMatch(interval)) {
          duration = int.parse(interval);
        }

        results.add(
          LyricsCandidate(
            source: id,
            title: '${song['title'] ?? song['name'] ?? title}',
            artist: finalSingers.isNotEmpty ? finalSingers : artist,
            album: album,
            duration: duration,
            syncedLyrics: lrc,
            translatedLyrics: trans,
            plainLyrics: lrc.isNotEmpty
                ? removeLrcTimestamps(lrc)
                : cleanPlainLyrics(trans),
          ),
        );
      }
    }

    return [for (final r in results) if (r.hasAny) r];
  }
}

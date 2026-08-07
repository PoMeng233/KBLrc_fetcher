/// 酷我音乐歌词源。
library;

import 'dart:convert';

import 'package:xml/xml.dart' as xml;

import '../lyrics_utils.dart';
import '../models.dart';
import 'base.dart';

class KuwoProvider implements LyricsProvider {
  const KuwoProvider();

  @override
  String get id => 'kuwo';

  @override
  String get label => '酷我音乐';

  static const _headers = {
    'Referer': 'https://www.kuwo.cn/',
  };

  @override
  Future<bool> checkHealth() async {
    try {
      await httpGet(
        'https://search.kuwo.cn/r.s',
        query: {'all': 'test', 'ft': 'music', 'itemset': 'web_2013', 'client': 'kt', 'pn': 0, 'rn': 3, 'rformat': 'json', 'encoding': 'utf8'},
        headers: _headers,
        timeout: const Duration(seconds: 5),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 解析搜索接口的 JSONP 响应中的 abslist。
  List<Map<String, dynamic>> _parseSearchResponse(String text) {
    final stripped = text.trim();
    if (stripped.isEmpty) return [];

    if (stripped.startsWith('{') && stripped.contains('abslist')) {
      try {
        final data = jsonDecode(stripped) as Map<String, dynamic>;
        final list = data['abslist'];
        if (list is List) return list.whereType<Map<String, dynamic>>().toList();
      } catch (_) {}
    }

    final match = RegExp(r"'abslist'\s*:\s*(\[[\s\S]*\])").firstMatch(stripped) ??
        RegExp(r'"abslist"\s*:\s*(\[[\s\S]*\])').firstMatch(stripped);
    if (match == null) return [];

    final abslistText = match.group(1)!;

    try {
      var fixed = abslistText.replaceAll("'", '"');
      fixed = fixed.replaceAll(RegExp(r',\s*([}\]])'), r'$1');
      final data = jsonDecode(fixed);
      if (data is List) return data.whereType<Map<String, dynamic>>().toList();
    } catch (_) {}

    final results = <Map<String, dynamic>>[];
    for (final objText in RegExp(r'\{[\s\S]*?\}').allMatches(abslistText)) {
      final item = <String, String>{};
      for (final m in RegExp(r"'([^']+)'\s*:\s*'([^']*)'")
          .allMatches(objText.group(0)!)) {
        item[m.group(1)!] = m.group(2)!;
      }
      if (item.isNotEmpty) results.add(item);
    }
    return results;
  }

  Map<String, String> _parseSongXml(String xmlText) {
    final data = <String, String>{};
    try {
      final doc = xml.XmlDocument.parse(xmlText);
      for (final el in doc.rootElement.childElements) {
        data[el.name.local] = el.innerText.trim();
      }
    } catch (_) {}
    return data;
  }

  @override
  Future<List<LyricsCandidate>> search(TrackQuery query) async {
    final results = <LyricsCandidate>[];

    for (final (title, artist) in query.searchVariants) {
      final keyword = [title, artist].where((s) => s.isNotEmpty).join(' ');
      if (keyword.isEmpty) continue;

      final songs = <Map<String, dynamic>>[];

      // endpoint 1: legacy search
      try {
        final resp = await httpGet(
          'https://search.kuwo.cn/r.s',
          query: {
            'all': keyword,
            'ft': 'music',
            'itemset': 'web_2013',
            'client': 'kt',
            'pn': 0,
            'rn': 8,
            'rformat': 'json',
            'encoding': 'utf8',
          },
          headers: _headers,
        );
        songs.addAll(_parseSearchResponse(decodeBody(resp)).take(8));
      } catch (_) {}

      // endpoint 2: www search fallback
      if (songs.isEmpty) {
        try {
          final resp = await httpGet(
            'https://www.kuwo.cn/api/www/search/searchMusicBykeyWord',
            query: {'key': keyword, 'pn': 1, 'rn': 10, 'httpsStatus': 1},
            headers: {..._headers, 'csrf': '', 'Cookie': 'kw_token='},
          );
          final data = jsonDecode(decodeBody(resp));
          final list =
              (((data as Map<String, dynamic>)['data'] as Map<String, dynamic>?)
                      ?['list']) as List? ??
                  const [];
          songs.addAll(list.take(8).whereType<Map<String, dynamic>>());
        } catch (_) {}
      }

      for (final song in songs) {
        var rid = '${song['MUSICRID'] ?? song['rid'] ?? song['musicrid'] ?? ''}';
        rid = rid.replaceAll('MUSIC_', '').trim();
        if (rid.isEmpty) continue;

        var synced = '';
        var translated = '';
        var songData = <String, String>{};

        // primary metadata endpoint
        try {
          final songResp = await httpGet(
            'https://player.kuwo.cn/webmusic/st/getNewMuiseByRid',
            query: {'rid': rid},
            headers: _headers,
          );
          songData = _parseSongXml(decodeBody(songResp));
        } catch (_) {}

        final lrcKey = songData['lyric'] ?? '';
        final transKey = songData['lyric_zz'] ?? '';

        if (lrcKey.isNotEmpty) {
          try {
            final lrcResp = await httpGet(
              'https://newlyric.kuwo.cn/newlyric.lrc?$lrcKey',
              headers: _headers,
            );
            synced = decodeBody(lrcResp).trim();
          } catch (_) {
            synced = '';
          }
        }

        if (transKey.isNotEmpty) {
          try {
            final transResp = await httpGet(
              'https://newlyric.kuwo.cn/newlyric.lrc?$transKey',
              headers: _headers,
            );
            translated = decodeBody(transResp).trim();
          } catch (_) {
            translated = '';
          }
        }

        // fallback lyric endpoint
        if (synced.isEmpty && translated.isEmpty) {
          try {
            final lrcApi = await httpGet(
              'https://m.kuwo.cn/newh5/singles/songinfoandlrc',
              query: {'musicId': rid},
              headers: _headers,
            );
            final lrcData = jsonDecode(decodeBody(lrcApi));
            final lrclist =
                (((lrcData as Map<String, dynamic>)['data'] as Map<String, dynamic>?)
                        ?['lrclist']) as List? ??
                    const [];
            if (lrclist.isNotEmpty) {
              final lines = <String>[];
              for (final row in lrclist) {
                if (row is! Map<String, dynamic>) continue;
                final line = '${row['lineLyric'] ?? ''}'.trim();
                if (line.isEmpty) continue;
                final tval = '${row['time'] ?? '0'}'.trim();
                double sec;
                try {
                  sec = double.parse(tval);
                } catch (_) {
                  sec = 0.0;
                }
                final mm = sec ~/ 60;
                final ss = sec - mm * 60;
                lines.add('[${mm.toString().padLeft(2, '0')}:${ss.toStringAsFixed(2).padLeft(5, '0')}]$line');
              }
              synced = lines.join('\n').trim();
            }
          } catch (_) {}
        }

        if (synced.isEmpty && translated.isEmpty) continue;

        int? duration;
        final durationRaw = song['DURATION'] ??
            songData['songTimeMinutes'] ??
            song['duration'] ??
            song['songTimeMinutes'];
        if (durationRaw != null) {
          final s = '$durationRaw';
          if (RegExp(r'^\d+$').hasMatch(s)) {
            duration = int.parse(s);
          } else {
            final m = RegExp(r'(\d+):(\d+)').firstMatch(s);
            if (m != null) {
              duration = int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
            }
          }
        }

        results.add(
          LyricsCandidate(
            source: id,
            title: '${song['SONGNAME'] ?? song['name'] ?? songData['name'] ?? title}',
            artist: '${song['ARTIST'] ?? song['artist'] ?? songData['artist'] ?? artist}',
            album: '${song['ALBUM'] ?? song['album'] ?? songData['special'] ?? ''}',
            duration: duration,
            syncedLyrics: synced,
            plainLyrics: synced.isNotEmpty
                ? removeLrcTimestamps(synced)
                : cleanPlainLyrics(translated),
            translatedLyrics: translated,
          ),
        );
      }
    }

    return [for (final r in results) if (r.hasAny) r];
  }
}

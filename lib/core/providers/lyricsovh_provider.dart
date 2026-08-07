/// Lyrics.ovh 歌词源。
library;

import 'dart:convert';

import '../lyrics_utils.dart';
import '../models.dart';
import 'base.dart';

class LyricsOvhProvider implements LyricsProvider {
  const LyricsOvhProvider();

  @override
  String get id => 'lyricsovh';

  @override
  String get label => 'Lyrics.ovh';

  @override
  Future<bool> checkHealth() async {
    try {
      await httpGet('https://api.lyrics.ovh/v1/test/test');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<LyricsCandidate>> search(TrackQuery query) async {
    final results = <LyricsCandidate>[];

    for (final (title, artist) in query.searchVariants) {
      if (title.isEmpty) continue;

      // 直接查询
      try {
        if (artist.isNotEmpty) {
          final resp = await httpGet(
            'https://api.lyrics.ovh/v1/${Uri.encodeComponent(artist)}/${Uri.encodeComponent(title)}',
          );
          final data = jsonDecode(decodeBody(resp)) as Map<String, dynamic>;
          final lyrics = (data['lyrics'] as String?) ?? '';
          if (lyrics.trim().isNotEmpty) {
            results.add(
              LyricsCandidate(
                source: id,
                title: title,
                artist: artist,
                album: query.album,
                duration: query.duration,
                plainLyrics: cleanPlainLyrics(lyrics),
              ),
            );
            continue;
          }
        }
      } catch (_) {}

      // suggest 兜底
      try {
        final keyword =
            [artist, title].where((s) => s.isNotEmpty).join(' ').trim();
        final suggestResp = await httpGet(
          'https://api.lyrics.ovh/suggest/${Uri.encodeComponent(keyword.isEmpty ? title : keyword)}',
        );
        final suggestData = jsonDecode(decodeBody(suggestResp));
        final items = (suggestData is Map<String, dynamic> &&
                suggestData['data'] is List)
            ? (suggestData['data'] as List).take(5)
            : const <dynamic>[];

        for (final item in items) {
          if (item is! Map<String, dynamic>) continue;
          final candTitle = (item['title'] as String?) ?? title;
          final artistObj = item['artist'];
          final candArtist = artistObj is Map<String, dynamic>
              ? ((artistObj['name'] as String?) ?? '')
              : artist;
          if (candTitle.isEmpty || candArtist.isEmpty) continue;

          try {
            final lyricResp = await httpGet(
              'https://api.lyrics.ovh/v1/${Uri.encodeComponent(candArtist)}/${Uri.encodeComponent(candTitle)}',
            );
            final lyricData =
                jsonDecode(decodeBody(lyricResp)) as Map<String, dynamic>;
            final lyrics = (lyricData['lyrics'] as String?) ?? '';
            if (lyrics.trim().isNotEmpty) {
              results.add(
                LyricsCandidate(
                  source: id,
                  title: candTitle,
                  artist: candArtist,
                  album: query.album,
                  plainLyrics: cleanPlainLyrics(lyrics),
                ),
              );
            }
          } catch (_) {
            continue;
          }
        }
      } catch (_) {
        continue;
      }
    }

    return [for (final r in results) if (r.hasAny) r];
  }
}

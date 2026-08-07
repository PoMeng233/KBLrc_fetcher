/// LRCLIB 歌词源。
library;

import 'dart:convert';

import '../models.dart';
import 'base.dart';

class LrclibProvider implements LyricsProvider {
  const LrclibProvider();

  @override
  String get id => 'lrclib';

  @override
  String get label => 'LRCLIB';

  @override
  Future<bool> checkHealth() async {
    try {
      await httpGet(
        'https://lrclib.net/api/search',
        query: {'track_name': 'test'},
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<LyricsCandidate>> search(TrackQuery query) async {
    final results = <LyricsCandidate>[];

    // 精确参数齐全时优先使用 /api/get
    if (query.title.isNotEmpty &&
        query.artist.isNotEmpty &&
        query.album.isNotEmpty &&
        query.duration != null) {
      try {
        final resp = await httpGet(
          'https://lrclib.net/api/get',
          query: {
            'track_name': query.title,
            'artist_name': query.artist,
            'album_name': query.album,
            'duration': query.duration,
          },
        );
        final data = jsonDecode(decodeBody(resp)) as Map<String, dynamic>;
        results.add(_fromJson(data));
      } catch (_) {}
    }

    for (final (title, artist) in query.searchVariants) {
      try {
        final resp = await httpGet(
          'https://lrclib.net/api/search',
          query: {
            'track_name': title,
            'artist_name': artist,
            'album_name': query.album,
          },
        );
        final data = jsonDecode(decodeBody(resp));
        if (data is List) {
          for (final item in data.take(6)) {
            if (item is Map<String, dynamic>) {
              results.add(_fromJson(item));
            }
          }
        }
      } catch (_) {
        continue;
      }
    }

    return [for (final r in results) if (r.hasAny) r];
  }

  LyricsCandidate _fromJson(Map<String, dynamic> data) => LyricsCandidate(
    source: id,
    title: (data['trackName'] as String?) ?? '',
    artist: (data['artistName'] as String?) ?? '',
    album: (data['albumName'] as String?) ?? '',
    duration: (data['duration'] as num?)?.toInt(),
    syncedLyrics: (data['syncedLyrics'] as String?) ?? '',
    plainLyrics: (data['plainLyrics'] as String?) ?? '',
  );
}

/// 歌词搜索核心数据模型。
library;

/// 歌词源目录信息。
class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.label,
    required this.region,
    required this.supportsSynced,
    required this.supportsPlain,
  });

  final String id;
  final String label;
  /// `global` 或 `cn`。
  final String region;
  final bool supportsSynced;
  final bool supportsPlain;
}

/// 歌词源目录。
const Map<String, ProviderInfo> providerCatalog = {
  'lrclib': ProviderInfo(
    id: 'lrclib',
    label: 'LRCLIB',
    region: 'global',
    supportsSynced: true,
    supportsPlain: true,
  ),
  'lyricsovh': ProviderInfo(
    id: 'lyricsovh',
    label: 'Lyrics.ovh',
    region: 'global',
    supportsSynced: false,
    supportsPlain: true,
  ),
  'kugou': ProviderInfo(
    id: 'kugou',
    label: '酷狗音乐',
    region: 'cn',
    supportsSynced: true,
    supportsPlain: true,
  ),
  'kuwo': ProviderInfo(
    id: 'kuwo',
    label: '酷我音乐',
    region: 'cn',
    supportsSynced: true,
    supportsPlain: true,
  ),
  'netease': ProviderInfo(
    id: 'netease',
    label: '网易云音乐',
    region: 'cn',
    supportsSynced: true,
    supportsPlain: true,
  ),
  'qq': ProviderInfo(
    id: 'qq',
    label: 'QQ 音乐',
    region: 'cn',
    supportsSynced: true,
    supportsPlain: true,
  ),
};

const List<String> defaultProviders = [
  'lrclib',
  'lyricsovh',
  'kugou',
  'kuwo',
  'netease',
  'qq',
];

/// 各歌词源的优先权重（用于结果排序）。
const Map<String, int> sourcePriority = {
  'lrclib': 42,
  'kugou': 40,
  'qq': 36,
  'netease': 34,
  'kuwo': 32,
  'lyricsovh': 24,
};

const Set<String> audioExtensions = {
  '.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus',
  '.wav', '.wma', '.ape', '.mp4',
};

/// 歌词保存模式。
enum LyricMode { auto, synced, plain }

/// 输出文件名格式。
enum NameFormat { file, titleArtist }

/// 主题模式。
enum ThemePreference { system, light, dark }

/// 文件冲突处理策略。
enum ConflictPolicy { ask, overwrite, rename, skip }

/// 搜索请求。
class TrackQuery {
  TrackQuery({
    required this.title,
    this.artist = '',
    this.album = '',
    this.duration,
    this.sourceFile,
    List<(String, String)>? searchVariants,
  }) : searchVariants = searchVariants ?? const [];

  final String title;
  final String artist;
  final String album;
  final int? duration;
  /// 音频文件绝对路径（手动查询时为 null）。
  final String? sourceFile;
  /// (标题, 歌手) 搜索变体列表。
  final List<(String, String)> searchVariants;

  TrackQuery copyWith({String? title, String? artist}) => TrackQuery(
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album,
    duration: duration,
    sourceFile: sourceFile,
    searchVariants: searchVariants,
  );
}

/// 歌词候选结果。
class LyricsCandidate {
  LyricsCandidate({
    required this.source,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.duration,
    this.syncedLyrics = '',
    this.plainLyrics = '',
    this.translatedLyrics = '',
    this.score = 0.0,
    Map<String, dynamic>? extra,
  }) : extra = extra ?? const {};

  final String source;
  String title;
  String artist;
  String album;
  int? duration;
  String syncedLyrics;
  String plainLyrics;
  String translatedLyrics;
  double score;
  Map<String, dynamic> extra;

  static final RegExp _timestampRe = RegExp(
    r'^\[\d{2}:\d{2}(?:\.\d{1,3})?\]',
    multiLine: true,
  );

  bool get hasSynced =>
      syncedLyrics.isNotEmpty && _timestampRe.hasMatch(syncedLyrics);

  bool get hasPlain => plainLyrics.trim().isNotEmpty;

  bool get hasTranslation => translatedLyrics.trim().isNotEmpty;

  bool get hasAny =>
      syncedLyrics.trim().isNotEmpty ||
      plainLyrics.trim().isNotEmpty ||
      translatedLyrics.trim().isNotEmpty;

  /// 用于去重与选中态恢复的稳定标识。
  String get identityKey {
    final s = syncedLyrics.trim();
    final pl = plainLyrics.trim();
    return '$source|${title.trim().toLowerCase()}|${artist.trim().toLowerCase()}'
        '|${s.isEmpty ? '' : s.substring(0, s.length.clamp(0, 160))}'
        '|${pl.isEmpty ? '' : pl.substring(0, pl.length.clamp(0, 160))}';
  }

  LyricsCandidate copyWith({
    String? title,
    String? artist,
    String? album,
    int? duration,
    String? syncedLyrics,
    String? plainLyrics,
    String? translatedLyrics,
    double? score,
  }) =>
      LyricsCandidate(
        source: source,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        duration: duration ?? this.duration,
        syncedLyrics: syncedLyrics ?? this.syncedLyrics,
        plainLyrics: plainLyrics ?? this.plainLyrics,
        translatedLyrics: translatedLyrics ?? this.translatedLyrics,
        score: score ?? this.score,
        extra: extra,
      );
}

/// 单个歌词源的搜索状态。
class ProviderSearchStatus {
  ProviderSearchStatus({
    required this.provider,
    this.ok = false,
    this.resultCount = 0,
    this.error = '',
    this.timedOut = false,
  });

  final String provider;
  bool ok;
  int resultCount;
  String error;
  bool timedOut;
}

/// 一次完整搜索的结果集合。
class SearchResultBundle {
  SearchResultBundle({required this.query, required this.providers});

  final TrackQuery query;
  final List<String> providers;
  final List<LyricsCandidate> allCandidates = [];
  final Map<String, List<LyricsCandidate>> groupedCandidates = {};
  final Map<String, ProviderSearchStatus> providerStatus = {};
  LyricsCandidate? bestCandidate;
}

/// 保存选项。
class SaveOptions {
  SaveOptions({
    this.outputMode = NameFormat.file,
    this.overwrite = false,
    this.outDir,
    this.lyricMode = LyricMode.auto,
    this.includeMetadata = true,
    this.stripTimestamps = false,
    this.stripTranslationLines = false,
  });

  NameFormat outputMode;
  bool overwrite;
  String? outDir;
  LyricMode lyricMode;
  bool includeMetadata;
  bool stripTimestamps;
  bool stripTranslationLines;
}

/// 保存结果。
class SaveOutcome {
  SaveOutcome({
    required this.success,
    this.message = '',
    this.path,
    this.skipped = false,
    this.conflict = false,
  });

  final bool success;
  final String message;
  final String? path;
  final bool skipped;
  /// 存在冲突且策略为 `ask` 时为 true，需要 UI 询问用户。
  final bool conflict;
}

/// 批量处理单个文件的输出。
class BatchItemResult {
  BatchItemResult({
    required this.file,
    required this.query,
    required this.success,
    required this.message,
    this.path,
    this.skipped = false,
  });

  final String file;
  final TrackQuery query;
  final bool success;
  final String message;
  final String? path;
  final bool skipped;
}

/// 歌词源健康状态。
enum ProviderHealth { unknown, checking, ok, error }

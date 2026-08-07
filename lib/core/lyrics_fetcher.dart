/// 搜索协调器：并发搜索多歌词源、流式回报进度、超时兜底。
library;

import 'dart:async';

import 'models.dart';
import 'lyrics_utils.dart';
import 'providers/base.dart';
import 'providers/kugou_provider.dart';
import 'providers/kuwo_provider.dart';
import 'providers/lrclib_provider.dart';
import 'providers/lyricsovh_provider.dart';
import 'providers/netease_provider.dart';
import 'providers/qq_provider.dart';

bool _registered = false;

void _ensureProvidersRegistered() {
  if (_registered) return;
  _registered = true;
  registerProvider(const LrclibProvider());
  registerProvider(const LyricsOvhProvider());
  registerProvider(const KugouProvider());
  registerProvider(const KuwoProvider());
  registerProvider(const NeteaseProvider());
  registerProvider(const QqProvider());
}

Future<(List<LyricsCandidate>, ProviderSearchStatus)> _searchOne(
  LyricsProvider provider,
  TrackQuery query,
) async {
  final status = ProviderSearchStatus(provider: provider.id);
  try {
    final items = await provider.search(query);
    status.ok = true;
    status.resultCount = items.length;
    for (final item in items) {
      item.score = scoreCandidate(query, item);
    }
    return (items, status);
  } catch (e) {
    status.error = '$e';
    return (const <LyricsCandidate>[], status);
  }
}

/// 并发搜索并聚合结果。
///
/// [onProviderDone] 在每个歌词源完成时回调（含失败），用于流式更新 UI。
/// 整体搜索在 [maxDuration] 内结束，超时歌词源标记为 timedOut。
Future<SearchResultBundle> searchCandidatesBySource({
  required TrackQuery query,
  required List<String> providers,
  bool preferSynced = true,
  Duration maxDuration = const Duration(seconds: 15),
  void Function(
    String provider,
    ProviderSearchStatus status,
    List<LyricsCandidate> items,
  )?
  onProviderDone,
}) async {
  _ensureProvidersRegistered();
  final bundle = SearchResultBundle(query: query, providers: providers);
  final valid = [
    for (final p in providers)
      if (providerInstances.containsKey(p)) p,
  ];
  bundle.providers
    ..clear()
    ..addAll(valid);
  if (valid.isEmpty) return bundle;

  final futures = <String, Future<(List<LyricsCandidate>, ProviderSearchStatus)>>{};
  for (final p in valid) {
    futures[p] = _searchOne(providerInstances[p]!, query);
  }

  final done = <String, (List<LyricsCandidate>, ProviderSearchStatus)>{};
  final deadline = DateTime.now().add(maxDuration);

  while (done.length < futures.length) {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) break;

    final wake = Completer<String>();
    for (final entry in futures.entries) {
      if (done.containsKey(entry.key)) continue;
      entry.value.then((result) {
        done[entry.key] = result;
        if (!wake.isCompleted) wake.complete(entry.key);
      });
    }
    await wake.future.timeout(left, onTimeout: () => '');
  }

  // 超时未完成的歌词源
  for (final p in futures.keys) {
    if (!done.containsKey(p)) {
      final status = ProviderSearchStatus(
        provider: p,
        timedOut: true,
        error: 'provider timeout (> ${maxDuration.inSeconds}s overall)',
      );
      bundle.providerStatus[p] = status;
      if (onProviderDone != null) onProviderDone(p, status, const []);
    }
  }

  for (final entry in done.entries) {
    final (items, status) = entry.value;
    bundle.providerStatus[entry.key] = status;
    bundle.allCandidates.addAll(items);
    if (onProviderDone != null) {
      onProviderDone(entry.key, status, items);
    }
  }

  final ranked = rankAndDeduplicateCandidates(bundle.allCandidates, query);
  bundle.allCandidates
    ..clear()
    ..addAll(ranked);

  for (final p in valid) {
    bundle.groupedCandidates[p] = [
      for (final item in ranked)
        if (item.source == p) item,
    ];
  }

  if (ranked.isNotEmpty) {
    if (preferSynced) {
      final synced = [for (final item in ranked) if (item.hasSynced) item];
      bundle.bestCandidate = synced.isNotEmpty ? synced.first : ranked.first;
    } else {
      bundle.bestCandidate = ranked.first;
    }
  }

  return bundle;
}

/// 选择最佳候选（供批量模式使用）。
Future<LyricsCandidate?> chooseBestCandidate({
  required TrackQuery query,
  required List<String> providers,
  bool preferSynced = true,
}) async {
  final bundle = await searchCandidatesBySource(
    query: query,
    providers: providers,
    preferSynced: preferSynced,
  );
  return bundle.bestCandidate;
}

import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/app_info.dart';
import '../core/lyrics_fetcher.dart';
import '../core/lyrics_utils.dart';
import '../core/models.dart';
import '../core/providers/base.dart';
import '../core/save_service.dart';
import '../core/settings.dart';
import 'widgets/preview_sheet.dart';
import 'widgets/provider_branding.dart';
import 'widgets/provider_chip.dart';
import 'widgets/result_card.dart';
import 'widgets/state_views.dart';

enum _DirAction { songDir, fallback, pick, cancel }

enum _BatchItemStatus { running, ok, skipped, failed }

class _BatchItem {
  _BatchItem(this.file, this.status, [this.message = '']);
  final String file;
  final _BatchItemStatus status;
  final String message;
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const _searchTimeout = Duration(seconds: 15);
  final SaveService _saveService = const SaveService();

  final _titleCtrl = TextEditingController();
  final _artistCtrl = TextEditingController();
  final _albumCtrl = TextEditingController();
  final _durationCtrl = TextEditingController();
  final _outDirCtrl = TextEditingController();

  int _navIndex = 0;

  bool _searching = false;
  bool _dragActive = false;
  int _generation = 0;
  TrackQuery? _lastQuery;
  final List<LyricsCandidate> _results = [];
  final Map<String, ProviderSearchStatus> _statuses = {};
  final Map<String, ProviderHealth> _health = {};
  String? _bestKey;
  LyricsCandidate? _selected;
  int _receivedCount = 0;
  Duration _elapsed = Duration.zero;
  Timer? _elapsedTimer;

  bool _batchRunning = false;
  bool _batchCancelled = false;
  int _batchTotal = 0;
  int _batchDone = 0;
  String _batchCurrent = '';
  int _batchSuccess = 0;
  int _batchSkipped = 0;
  int _batchFailed = 0;
  final List<_BatchItem> _batchItems = [];

  bool get _busy => _searching || _batchRunning;
  bool get _hasSelection => _selected != null && _lastQuery != null;

  @override
  void initState() {
    super.initState();
    _outDirCtrl.text = widget.settings.outDir;
    widget.settings.addListener(_onSettingsChanged);
    for (final provider in widget.settings.enabledProviders) {
      _checkProviderHealth(provider);
    }
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    _elapsedTimer?.cancel();
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _albumCtrl.dispose();
    _durationCtrl.dispose();
    _outDirCtrl.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (_outDirCtrl.text != widget.settings.outDir) {
      _outDirCtrl.text = widget.settings.outDir;
    }
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // 搜索
  // ---------------------------------------------------------------------------

  Future<void> _startSearch() async {
    if (_busy) return;
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _showSnack('请输入歌曲名', isError: true);
      return;
    }
    final duration = int.tryParse(_durationCtrl.text.trim());
    final query = buildManualQuery(
      title: title,
      artist: _artistCtrl.text,
      album: _albumCtrl.text,
      duration: duration,
    );
    await _runSearch(query);
  }

  Future<void> _runSearch(TrackQuery query) async {
    final providers = widget.settings.enabledProviders;
    if (providers.isEmpty) {
      _showSnack('请至少启用一个歌词源', isError: true);
      return;
    }
    final gen = ++_generation;
    setState(() {
      _searching = true;
      _lastQuery = query;
      _results.clear();
      _statuses.clear();
      _selected = null;
      _bestKey = null;
      _receivedCount = 0;
      _elapsed = Duration.zero;
    });
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _searching) {
        setState(() => _elapsed += const Duration(seconds: 1));
      }
    });

    final bundle = await searchCandidatesBySource(
      query: query,
      providers: providers,
      preferSynced:
          widget.settings.lyricMode != LyricMode.plain &&
          !widget.settings.stripTimestamps,
      maxDuration: _searchTimeout,
      onProviderDone: (provider, status, items) {
        if (gen != _generation || !mounted) return;
        setState(() {
          _statuses[provider] = status;
          if (items.isNotEmpty) {
            _results.addAll(items);
            _receivedCount += items.length;
          }
        });
      },
    );

    if (gen != _generation || !mounted) return;
    _elapsedTimer?.cancel();
    setState(() {
      _searching = false;
      _results
        ..clear()
        ..addAll(bundle.allCandidates);
      _statuses.addAll(bundle.providerStatus);
      _receivedCount = bundle.allCandidates.length;
      _bestKey = bundle.bestCandidate?.identityKey;
      if (bundle.allCandidates.isEmpty) {
        _showSnack(
          '未找到歌词：${query.title}'
          '${query.artist.isNotEmpty ? ' - ${query.artist}' : ''}',
          isError: true,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 文件 / 目录 / 拖拽
  // ---------------------------------------------------------------------------

  Future<void> _pickAudioFile() async {
    if (_busy) return;
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'mp3',
        'flac',
        'm4a',
        'aac',
        'ogg',
        'opus',
        'wav',
        'wma',
        'ape',
        'mp4',
      ],
    );
    if (result == null || result.files.isEmpty) return;
    await _loadFileAndSearch(result.files.first.path!);
  }

  Future<void> _pickAudioFolder() async {
    if (_busy) return;
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null || dir.isEmpty) return;
    final files = await findAudioFiles(dir);
    if (!mounted) return;
    if (files.isEmpty) {
      _showSnack('该文件夹下没有音频文件', isError: true);
      return;
    }
    if (files.length == 1) {
      await _loadFileAndSearch(files.first);
    } else {
      await _runBatch(files);
    }
  }

  Future<void> _loadFileAndSearch(String path) async {
    _showSnack('读取音频信息：${p.basename(path)}…');
    final query = await readAudioMetadata(path);
    if (!mounted) return;
    _titleCtrl.text = query.title;
    _artistCtrl.text = query.artist;
    _albumCtrl.text = query.album;
    _durationCtrl.text = query.duration?.toString() ?? '';
    setState(() {});
    _showSnack('已识别：${p.basename(path)}');
    await _runSearch(query);
  }

  Future<void> _onDrop(List<DropItem> files) async {
    if (_busy) return;
    final paths = <String>[];
    for (final f in files) {
      try {
        final isDir = await FileSystemEntity.isDirectory(f.path);
        if (isDir) {
          paths.addAll(await findAudioFiles(f.path));
        } else if (audioExtensions.contains(
          p.extension(f.path).toLowerCase(),
        )) {
          paths.add(f.path);
        }
      } catch (_) {}
    }
    if (paths.isEmpty) {
      _showSnack('未发现可处理的音频文件', isError: true);
      return;
    }
    if (paths.length == 1) {
      await _loadFileAndSearch(paths.first);
    } else {
      await _runBatch(paths);
    }
  }

  // ---------------------------------------------------------------------------
  // 保存
  // ---------------------------------------------------------------------------

  SaveOptions _saveOptions() => SaveOptions(
    outputMode: widget.settings.nameFormat,
    overwrite: widget.settings.overwrite,
    outDir: widget.settings.outDir.trim().isNotEmpty
        ? widget.settings.outDir
        : null,
    lyricMode: widget.settings.lyricMode,
    includeMetadata: widget.settings.includeMetadata,
    stripTimestamps: widget.settings.stripTimestamps,
    stripTranslationLines: widget.settings.stripTranslation,
  );

  Future<SaveOutcome?> _saveCandidate(
    LyricsCandidate candidate, [
    SaveOptions? overrideOptions,
  ]) async {
    final query = _lastQuery;
    if (query == null) return null;

    final options = overrideOptions ?? _saveOptions();
    if ((options.outDir ?? '').trim().isEmpty) {
      final dir = await _resolveSaveDir(query);
      if (!mounted || dir == null) return null;
      options.outDir = dir;
    }

    var outcome = await _saveService.save(
      options: options,
      candidate: candidate,
      query: query,
      policy: options.overwrite ? ConflictPolicy.overwrite : ConflictPolicy.ask,
    );

    if (outcome.conflict) {
      final policy = await _askConflictPolicy(outcome.path!);
      if (policy == null || !mounted) return null;
      outcome = await _saveService.save(
        options: options,
        candidate: candidate,
        query: query,
        policy: policy,
      );
    }

    if (!mounted) return outcome;
    if (outcome.success) {
      _showSnack(
        outcome.message,
        action: outcome.path != null && !outcome.skipped
            ? ('打开文件夹', () => _openFolder(p.dirname(outcome.path!)))
            : null,
      );
    } else {
      _showSnack(outcome.message, isError: true);
    }
    return outcome;
  }

  Future<String?> _resolveSaveDir(TrackQuery query) async {
    final sourceDir = query.sourceFile != null
        ? p.dirname(query.sourceFile!)
        : null;
    final fallback = p.join(Directory.current.path, 'lrc_output');
    final action = await showDialog<_DirAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择保存位置'),
        content: Text(
          sourceDir != null
              ? '未设置输出目录。\n\n保存到歌曲所在目录（${p.basename(sourceDir)}）还是其它位置？'
              : '未设置输出目录。\n\n保存到软件目录下的 lrc_output，还是选择其它位置？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _DirAction.cancel),
            child: const Text('取消'),
          ),
          if (sourceDir != null)
            TextButton(
              onPressed: () => Navigator.pop(context, _DirAction.songDir),
              child: const Text('歌曲目录'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, _DirAction.fallback),
            child: const Text('lrc_output'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _DirAction.pick),
            child: const Text('选择目录…'),
          ),
        ],
      ),
    );
    switch (action) {
      case _DirAction.songDir:
        return sourceDir;
      case _DirAction.fallback:
        return fallback;
      case _DirAction.pick:
        return FilePicker.getDirectoryPath();
      default:
        return null;
    }
  }

  Future<ConflictPolicy?> _askConflictPolicy(String path) {
    return showDialog<ConflictPolicy>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('文件已存在'),
        content: Text(
          '$path\n\n同名 LRC 文件已存在，请选择处理方式：',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ConflictPolicy.skip),
            child: const Text('跳过'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ConflictPolicy.rename),
            child: const Text('重命名'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ConflictPolicy.overwrite),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
  }

  void _openPreview(LyricsCandidate candidate) {
    final query = _lastQuery;
    if (query == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: PreviewSheet(
          candidate: candidate,
          query: query,
          initialOptions: _saveOptions(),
          onSave: _saveCandidate,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 批量处理
  // ---------------------------------------------------------------------------

  Future<void> _runBatch(List<String> files) async {
    if (_batchRunning || files.isEmpty) return;
    setState(() {
      _navIndex = 1;
      _batchRunning = true;
      _batchCancelled = false;
      _batchTotal = files.length;
      _batchDone = 0;
      _batchCurrent = '';
      _batchSuccess = 0;
      _batchSkipped = 0;
      _batchFailed = 0;
      _batchItems.clear();
    });

    final providers = widget.settings.enabledProviders;
    final options = _saveOptions();
    final preferSynced =
        widget.settings.lyricMode != LyricMode.plain &&
        !widget.settings.stripTimestamps;

    for (var i = 0; i < files.length; i++) {
      if (_batchCancelled) break;
      final file = files[i];
      setState(() {
        _batchDone = i;
        _batchCurrent = p.basename(file);
        _batchItems.add(_BatchItem(p.basename(file), _BatchItemStatus.running));
      });

      try {
        final query = await readAudioMetadata(file);
        final best = await chooseBestCandidate(
          query: query,
          providers: providers,
          preferSynced: preferSynced,
        );
        if (best == null) {
          _batchFailed++;
          _batchItems[_batchItems.length - 1] = _BatchItem(
            p.basename(file),
            _BatchItemStatus.failed,
            '未找到歌词',
          );
        } else {
          final outcome = await _saveService.save(
            options: options,
            candidate: best,
            query: query,
            policy: widget.settings.overwrite
                ? ConflictPolicy.overwrite
                : ConflictPolicy.skip,
          );
          if (outcome.skipped) {
            _batchSkipped++;
            _batchItems[_batchItems.length - 1] = _BatchItem(
              p.basename(file),
              _BatchItemStatus.skipped,
              outcome.message,
            );
          } else if (outcome.success) {
            _batchSuccess++;
            _batchItems[_batchItems.length - 1] = _BatchItem(
              p.basename(file),
              _BatchItemStatus.ok,
              outcome.message,
            );
          } else {
            _batchFailed++;
            _batchItems[_batchItems.length - 1] = _BatchItem(
              p.basename(file),
              _BatchItemStatus.failed,
              outcome.message,
            );
          }
        }
      } catch (e) {
        _batchFailed++;
        _batchItems[_batchItems.length - 1] = _BatchItem(
          p.basename(file),
          _BatchItemStatus.failed,
          '$e',
        );
      }
      if (mounted) setState(() {});
    }

    if (!mounted) return;
    final cancelled = _batchCancelled;
    setState(() {
      _batchRunning = false;
      _batchCurrent = '';
      _batchDone = cancelled ? _batchDone : _batchTotal;
    });

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(cancelled ? '已取消批量处理' : '批量处理完成'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('共 $_batchTotal 个文件'),
              const SizedBox(height: 8),
              Text(
                '✅ 成功 $_batchSuccess · ⏭ 跳过 $_batchSkipped · ❌ 失败 $_batchFailed',
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 其它
  // ---------------------------------------------------------------------------

  Future<void> _checkProviderHealth(String provider) async {
    setState(() => _health[provider] = ProviderHealth.checking);
    final instance = providerInstances[provider];
    final ok = instance != null ? await instance.checkHealth() : false;
    if (!mounted) return;
    setState(
      () => _health[provider] = ok ? ProviderHealth.ok : ProviderHealth.error,
    );
  }

  Future<void> _openFolder(String dir) async {
    try {
      await Process.start('explorer', [dir]);
    } catch (_) {
      _showSnack('无法打开文件夹：$dir', isError: true);
    }
  }

  void _showSnack(
    String message, {
    bool isError = false,
    (String, VoidCallback)? action,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        action: action != null
            ? SnackBarAction(label: action.$1, onPressed: action.$2)
            : null,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 界面框架
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          DropTarget(
            onDragEntered: (_) => setState(() => _dragActive = true),
            onDragExited: (_) => setState(() => _dragActive = false),
            onDragDone: (details) async {
              setState(() => _dragActive = false);
              await _onDrop(details.files);
            },
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildRail(),
                const VerticalDivider(width: 1),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0.02, 0),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: switch (_navIndex) {
                      0 => _buildSearchView(key: const ValueKey('view-search')),
                      1 => _buildBatchView(key: const ValueKey('view-batch')),
                      _ => _buildSettingsView(
                        key: const ValueKey('view-settings'),
                      ),
                    },
                  ),
                ),
              ],
            ),
          ),
          if (_dragActive) _buildDragOverlay(),
        ],
      ),
    );
  }

  Widget _buildRail() {
    final scheme = Theme.of(context).colorScheme;
    return NavigationRail(
      selectedIndex: _navIndex,
      onDestinationSelected: (i) => setState(() => _navIndex = i),
      labelType: NavigationRailLabelType.none,
      backgroundColor: scheme.surface,
      leading: Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 10),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.primary.withValues(alpha: 0.9),
                scheme.tertiary.withValues(alpha: 0.7),
              ],
            ),
          ),
          child: Icon(Icons.music_note, color: scheme.onPrimary, size: 22),
        ),
      ),
      destinations: [
        NavigationRailDestination(
          icon: const Icon(Icons.search),
          selectedIcon: Icon(Icons.search, color: scheme.primary),
          label: const Text('搜索'),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.playlist_play),
          selectedIcon: Icon(Icons.playlist_play, color: scheme.primary),
          label: const Text('批量'),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.tune),
          selectedIcon: Icon(Icons.tune, color: scheme.primary),
          label: const Text('设置'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 搜索视图
  // ---------------------------------------------------------------------------

  Widget _buildSearchView({Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: key,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '搜索歌词',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (_searching)
                Text(
                  '搜索中 · ${_elapsed.inSeconds}s',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Flexible(
            child: SingleChildScrollView(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _titleCtrl,
                        decoration: const InputDecoration(
                          labelText: '歌曲名（必填）',
                          hintText: '输入歌曲名，或 "歌手 - 歌名"',
                          prefixIcon: Icon(Icons.search, size: 20),
                        ),
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _startSearch(),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _artistCtrl,
                              decoration: const InputDecoration(
                                labelText: '歌手',
                                prefixIcon: Icon(
                                  Icons.person_outline,
                                  size: 20,
                                ),
                              ),
                              textInputAction: TextInputAction.next,
                              onSubmitted: (_) => _startSearch(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _albumCtrl,
                              decoration: const InputDecoration(
                                labelText: '专辑',
                                prefixIcon: Icon(
                                  Icons.album_outlined,
                                  size: 20,
                                ),
                              ),
                              onSubmitted: (_) => _startSearch(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: _durationCtrl,
                              decoration: const InputDecoration(
                                labelText: '时长(秒)',
                                prefixIcon: Icon(
                                  Icons.timer_outlined,
                                  size: 20,
                                ),
                              ),
                              keyboardType: TextInputType.number,
                              onSubmitted: (_) => _startSearch(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '歌词源',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 38,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final provider in providerCatalog.keys) ...[
                              ProviderChip(
                                provider: provider,
                                enabled:
                                    widget.settings.providers[provider] ??
                                    false,
                                health:
                                    _health[provider] ?? ProviderHealth.unknown,
                                onToggle: () {
                                  widget.settings.update(() {
                                    widget.settings.providers[provider] =
                                        !(widget.settings.providers[provider] ??
                                            false);
                                  });
                                  if (widget.settings.providers[provider] ??
                                      false) {
                                    _checkProviderHealth(provider);
                                  }
                                },
                              ),
                              const SizedBox(width: 8),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy ? null : _startSearch,
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              icon: _searching
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.search),
                              label: Text(_searching ? '搜索中…' : '搜索歌词'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          IconButton.filledTonal(
                            tooltip: '浏览歌曲文件并搜索',
                            onPressed: _busy ? null : _pickAudioFile,
                            icon: const Icon(Icons.audio_file_outlined),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            tooltip: '批量处理文件夹',
                            onPressed: _busy ? null : _pickAudioFolder,
                            icon: const Icon(Icons.folder_open),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          '或直接把音频文件 / 文件夹拖入窗口',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildResultsHeader(),
          if (_statuses.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in _statuses.entries)
                  _ProviderStatusChip(entry.key, entry.value),
              ],
            ),
          ],
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _buildResultsArea()),
                if (_hasSelection)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _buildSelectedBar(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsHeader() {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          '搜索结果',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        if (_receivedCount > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$_receivedCount',
              style: TextStyle(
                color: scheme.onPrimaryContainer,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _hasSelection ? () => _openPreview(_selected!) : null,
          icon: const Icon(Icons.visibility_outlined, size: 17),
          label: const Text('预览'),
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _hasSelection ? () => _saveCandidate(_selected!) : null,
          icon: const Icon(Icons.save_outlined, size: 17),
          label: const Text('保存选中'),
          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ],
    );
  }

  Widget _buildResultsArea() {
    if (_searching && _results.isEmpty) {
      return const _ShimmerList(key: ValueKey('shimmer'));
    }
    if (_results.isEmpty) {
      return const EmptyState(
        key: ValueKey('empty'),
        icon: Icons.library_music_outlined,
        title: '暂无搜索结果',
        subtitle: '输入歌曲名或拖入音频文件，点击「搜索歌词」开始',
      );
    }
    final compact = widget.settings.compactMode;
    return ListView.builder(
      key: const ValueKey('results'),
      padding: EdgeInsets.fromLTRB(
        0,
        compact ? 8 : 12,
        0,
        _hasSelection ? 84 : 8,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final candidate = _results[index];
        final selected =
            _selected != null &&
            _selected!.identityKey == candidate.identityKey;
        return Padding(
          padding: EdgeInsets.only(bottom: compact ? 8 : 10),
          child: TweenAnimationBuilder<double>(
            key: ValueKey('anim-${candidate.identityKey}'),
            tween: Tween(begin: 0, end: 1),
            duration: Duration(milliseconds: 240 + (index.clamp(0, 10) * 30)),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, 18 * (1 - t)),
                child: child,
              ),
            ),
            child: ResultCard(
              candidate: candidate,
              selected: selected,
              isBest: _bestKey == candidate.identityKey,
              compact: compact,
              onTap: () => setState(() => _selected = candidate),
              onPreview: () => _openPreview(candidate),
              onSave: () => _saveCandidate(candidate),
            ),
          ),
        );
      },
    );
  }

  /// 选中结果的底部操作条（类"正在播放"栏）。
  Widget _buildSelectedBar() {
    final candidate = _selected!;
    final scheme = Theme.of(context).colorScheme;
    final color = providerColor(candidate.source);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.4),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: Container(
        key: ValueKey('bar-${candidate.identityKey}'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 24,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    color.withValues(alpha: 0.85),
                    color.withValues(alpha: 0.55),
                  ],
                ),
              ),
              child: Text(
                providerShortLabel(candidate.source),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    candidate.title.isNotEmpty ? candidate.title : '未知标题',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    [
                      candidate.artist,
                      providerLabelOf(candidate.source),
                    ].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => _openPreview(candidate),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('预览'),
            ),
            const SizedBox(width: 4),
            FilledButton.tonalIcon(
              onPressed: () => _saveCandidate(candidate),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.save_outlined, size: 17),
              label: const Text('保存'),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '取消选中',
              onPressed: () => setState(() => _selected = null),
              icon: const Icon(Icons.close, size: 18),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 批量视图
  // ---------------------------------------------------------------------------

  Widget _buildBatchView({Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: key,
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '批量处理',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.drive_folder_upload_outlined,
                        size: 32,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '拖入多个音频文件或文件夹',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '自动搜索并保存每个文件的最佳歌词',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _pickAudioFolder,
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('选择文件夹'),
                    ),
                  ],
                ),
              ),
            ),
            if (_batchTotal > 0) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            _batchRunning ? '处理中' : '处理完成',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          Text(
                            '$_batchDone / $_batchTotal',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: scheme.primary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: _batchTotal == 0
                            ? null
                            : _batchDone / _batchTotal,
                        borderRadius: BorderRadius.circular(4),
                        minHeight: 6,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _batchCurrent.isEmpty
                            ? '成功 $_batchSuccess · 跳过 $_batchSkipped · 失败 $_batchFailed'
                            : _batchCurrent,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (_batchRunning) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: () => _batchCancelled = true,
                            icon: const Icon(Icons.cancel_outlined, size: 17),
                            label: const Text('取消'),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ),
                      ],
                      if (_batchItems.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 220),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: _batchItems.length,
                            itemBuilder: (context, index) {
                              final item = _batchItems[index];
                              return _BatchItemRow(item: item);
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 设置视图
  // ---------------------------------------------------------------------------

  Widget _buildSettingsView({Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '设置',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              _SettingsGroup(
                title: '外观',
                children: [
                  Row(
                    children: [
                      Text(
                        '主题模式',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const Spacer(),
                      SegmentedButton<ThemePreference>(
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: ThemePreference.system,
                            label: Text('跟随系统'),
                            icon: Icon(
                              Icons.brightness_auto_outlined,
                              size: 16,
                            ),
                          ),
                          ButtonSegment(
                            value: ThemePreference.light,
                            label: Text('浅色'),
                            icon: Icon(Icons.light_mode_outlined, size: 16),
                          ),
                          ButtonSegment(
                            value: ThemePreference.dark,
                            label: Text('深色'),
                            icon: Icon(Icons.dark_mode_outlined, size: 16),
                          ),
                        ],
                        selected: {widget.settings.theme},
                        onSelectionChanged: (s) => widget.settings.update(
                          () => widget.settings.theme = s.first,
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('紧凑模式'),
                    subtitle: const Text('缩小卡片间距，一屏显示更多结果'),
                    secondary: const Icon(Icons.density_small),
                    value: widget.settings.compactMode,
                    onChanged: (v) => widget.settings.update(
                      () => widget.settings.compactMode = v,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _SettingsGroup(
                title: '保存',
                children: [
                  _OptionRow(
                    label: '文件名格式',
                    child: SegmentedButton<NameFormat>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: const [
                        ButtonSegment(
                          value: NameFormat.file,
                          label: Text('同名文件'),
                          icon: Icon(Icons.description_outlined, size: 16),
                        ),
                        ButtonSegment(
                          value: NameFormat.titleArtist,
                          label: Text('歌名 - 歌手'),
                          icon: Icon(Icons.title, size: 16),
                        ),
                      ],
                      selected: {widget.settings.nameFormat},
                      onSelectionChanged: (s) => widget.settings.update(
                        () => widget.settings.nameFormat = s.first,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  _OptionRow(
                    label: '歌词模式',
                    child: SegmentedButton<LyricMode>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: const [
                        ButtonSegment(
                          value: LyricMode.auto,
                          label: Text('自动'),
                          icon: Icon(Icons.auto_awesome, size: 16),
                        ),
                        ButtonSegment(
                          value: LyricMode.synced,
                          label: Text('时间轴'),
                          icon: Icon(Icons.timer_outlined, size: 16),
                        ),
                        ButtonSegment(
                          value: LyricMode.plain,
                          label: Text('纯文本'),
                          icon: Icon(Icons.text_fields, size: 16),
                        ),
                      ],
                      selected: {widget.settings.lyricMode},
                      onSelectionChanged: (s) => widget.settings.update(
                        () => widget.settings.lyricMode = s.first,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _outDirCtrl,
                          decoration: const InputDecoration(
                            labelText: '输出目录（留空 = 保存到歌曲目录）',
                            isDense: true,
                            prefixIcon: Icon(Icons.folder_outlined, size: 20),
                          ),
                          onChanged: (v) => widget.settings.update(
                            () => widget.settings.outDir = v.trim(),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '选择输出目录',
                        icon: const Icon(Icons.more_horiz),
                        onPressed: () async {
                          final dir = await FilePicker.getDirectoryPath();
                          if (dir != null && mounted) {
                            widget.settings.update(
                              () => widget.settings.outDir = dir,
                            );
                          }
                        },
                      ),
                      IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.clear),
                        onPressed: () => widget.settings.update(
                          () => widget.settings.outDir = '',
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('覆盖已有文件'),
                    subtitle: const Text('关闭时遇到同名文件会询问'),
                    secondary: const Icon(Icons.sync_alt),
                    value: widget.settings.overwrite,
                    onChanged: (v) => widget.settings.update(
                      () => widget.settings.overwrite = v,
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('写入元数据头'),
                    subtitle: const Text('在 LRC 文件头写入 [ti]/[ar]/[al]/[by]'),
                    secondary: const Icon(Icons.info_outline),
                    value: widget.settings.includeMetadata,
                    onChanged: (v) => widget.settings.update(
                      () => widget.settings.includeMetadata = v,
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('保存时去掉时间戳'),
                    subtitle: const Text('输出纯文本歌词'),
                    secondary: const Icon(Icons.timer_off_outlined),
                    value: widget.settings.stripTimestamps,
                    onChanged: (v) => widget.settings.update(
                      () => widget.settings.stripTimestamps = v,
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('去掉翻译行'),
                    subtitle: const Text('保存时移除翻译歌词行'),
                    secondary: const Icon(Icons.translate),
                    value: widget.settings.stripTranslation,
                    onChanged: (v) => widget.settings.update(
                      () => widget.settings.stripTranslation = v,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _SettingsGroup(
                title: '关于',
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.music_note),
                    title: const Text(appName),
                    subtitle: const Text('多源歌词下载 · Flutter Material 3'),
                    trailing: Text(
                      'v$appVersion',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDragOverlay() {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: ColoredBox(
        color: scheme.scrim.withValues(alpha: 0.25),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 30),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.primary, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 40,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.file_download_outlined,
                  size: 44,
                  color: scheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  '松开以处理',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '单个文件自动搜索 · 多个文件或文件夹批量处理',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 小组件
// -----------------------------------------------------------------------------

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        const Spacer(),
        child,
      ],
    );
  }
}

/// 批量列表项。
class _BatchItemRow extends StatelessWidget {
  const _BatchItemRow({required this.item});

  final _BatchItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData, Color) icon = switch (item.status) {
      _BatchItemStatus.running => (Icons.hourglass_top, scheme.primary),
      _BatchItemStatus.ok => (Icons.check_circle, Colors.green),
      _BatchItemStatus.skipped => (Icons.skip_next, Colors.orange),
      _BatchItemStatus.failed => (Icons.error_outline, scheme.error),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon.$1, size: 15, color: icon.$2),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.file,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (item.message.isNotEmpty &&
              item.status != _BatchItemStatus.running)
            Flexible(
              child: Text(
                item.message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 歌词源状态小徽章。
class _ProviderStatusChip extends StatelessWidget {
  const _ProviderStatusChip(this.provider, this.status);

  final String provider;
  final ProviderSearchStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData, Color) icon = status.timedOut
        ? (Icons.hourglass_bottom, Colors.orange)
        : status.ok && status.resultCount > 0
        ? (Icons.check_circle, Colors.green)
        : status.ok
        ? (Icons.check_circle_outline, Colors.green.shade300)
        : (Icons.error_outline, scheme.error);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon.$1, size: 13, color: icon.$2),
          const SizedBox(width: 4),
          Text(
            '${providerLabelOf(provider)}'
            '${status.resultCount > 0 ? ' ${status.resultCount}' : ''}',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 搜索中的骨架屏。
class _ShimmerList extends StatefulWidget {
  const _ShimmerList({super.key});

  @override
  State<_ShimmerList> createState() => _ShimmerListState();
}

class _ShimmerListState extends State<_ShimmerList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_controller),
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 12),
        itemCount: 4,
        itemBuilder: (context, index) => Container(
          height: 96,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 180,
                      height: 13,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: 120,
                      height: 11,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

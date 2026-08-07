import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

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
import 'widgets/settings_sheet.dart';
import 'widgets/state_views.dart';

enum _DirAction { songDir, fallback, pick, cancel }

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

  bool _searching = false;
  bool _dragActive = false;
  int _generation = 0;
  TrackQuery? _lastQuery;
  final List<LyricsCandidate> _results = [];
  final Map<String, ProviderSearchStatus> _statuses = {};
  final Map<String, ProviderHealth> _health = {};
  String? _bestKey;
  LyricsCandidate? _selected;
  String _statusMessage = '准备就绪';
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
  final List<String> _batchFailures = [];

  bool get _busy => _searching || _batchRunning;

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
      _statusMessage = '正在搜索：${query.title}'
          '${query.artist.isNotEmpty ? ' / ${query.artist}' : ''}';
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
            _statusMessage = '已收到 $_receivedCount 条结果';
          }
        });
      },
    );

    if (gen != _generation || !mounted) return;
    setState(() {
      _searching = false;
      _results
        ..clear()
        ..addAll(bundle.allCandidates);
      _statuses.addAll(bundle.providerStatus);
      _receivedCount = bundle.allCandidates.length;
      _bestKey = bundle.bestCandidate?.identityKey;
      _statusMessage = bundle.allCandidates.isEmpty
          ? '未找到歌词：${query.title}'
          : '搜索完成，共 ${bundle.allCandidates.length} 条结果';
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
        'mp3', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'wma', 'ape', 'mp4',
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
    setState(() => _statusMessage = '读取音频信息：${p.basename(path)}…');
    final query = await readAudioMetadata(path);
    if (!mounted) return;
    _titleCtrl.text = query.title;
    _artistCtrl.text = query.artist;
    _albumCtrl.text = query.album;
    _durationCtrl.text = query.duration?.toString() ?? '';
    setState(() => _statusMessage = '已识别：${p.basename(path)}');
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
        } else if (audioExtensions
            .contains(p.extension(f.path).toLowerCase())) {
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
      policy: options.overwrite
          ? ConflictPolicy.overwrite
          : ConflictPolicy.ask,
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
      setState(() => _statusMessage = outcome.message);
      _showSnack(
        outcome.message,
        action: outcome.path != null && !outcome.skipped
            ? (
                '打开文件夹',
                () => _openFolder(p.dirname(outcome.path!)),
              )
            : null,
      );
    } else {
      _showSnack(outcome.message, isError: true);
    }
    return outcome;
  }

  Future<String?> _resolveSaveDir(TrackQuery query) async {
    final sourceDir =
        query.sourceFile != null ? p.dirname(query.sourceFile!) : null;
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
      _batchRunning = true;
      _batchCancelled = false;
      _batchTotal = files.length;
      _batchDone = 0;
      _batchCurrent = '';
      _batchSuccess = 0;
      _batchSkipped = 0;
      _batchFailed = 0;
      _batchFailures.clear();
      _statusMessage = '批量处理 ${files.length} 个文件…';
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
        _statusMessage = '批量 [${i + 1}/${files.length}] ${p.basename(file)}';
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
          _batchFailures.add('${p.basename(file)}：未找到歌词');
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
          } else if (outcome.success) {
            _batchSuccess++;
          } else {
            _batchFailed++;
            _batchFailures.add('${p.basename(file)}：${outcome.message}');
          }
        }
      } catch (e) {
        _batchFailed++;
        _batchFailures.add('${p.basename(file)}：$e');
      }
    }

    if (!mounted) return;
    final cancelled = _batchCancelled;
    setState(() {
      _batchRunning = false;
      _batchCurrent = '';
      _batchDone = cancelled ? _batchDone : _batchTotal;
      _statusMessage = cancelled ? '批量处理已取消' : '批量处理完成';
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
              Text('✅ 成功 $_batchSuccess · ⏭ 跳过 $_batchSkipped · ❌ 失败 $_batchFailed'),
              if (_batchFailures.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '失败明细：',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 180),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(
                      child: Text(
                        _batchFailures.join('\n'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
              ],
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
      () => _health[provider] =
          ok ? ProviderHealth.ok : ProviderHealth.error,
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
        backgroundColor:
            isError ? Theme.of(context).colorScheme.error : null,
        action: action != null
            ? SnackBarAction(label: action.$1, onPressed: action.$2)
            : null,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
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
            child: Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildLeftPanel(),
                      const VerticalDivider(width: 1),
                      Expanded(child: _buildRightPanel()),
                    ],
                  ),
                ),
                _buildStatusBar(),
              ],
            ),
          ),
          if (_dragActive) _buildDragOverlay(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Container(
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
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'KB歌词搜索',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '多源歌词下载 · v4.0.0',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            tooltip: '切换主题（当前：${_themeLabel(widget.settings.theme)}）',
            icon: Icon(_themeIcon(widget.settings.theme)),
            onPressed: () {
              final next = switch (widget.settings.theme) {
                ThemePreference.system => ThemePreference.light,
                ThemePreference.light => ThemePreference.dark,
                ThemePreference.dark => ThemePreference.system,
              };
              widget.settings.update(() => widget.settings.theme = next);
            },
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.tune),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              backgroundColor: Theme.of(context).colorScheme.surface,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (context) => SettingsSheet(settings: widget.settings),
            ),
          ),
        ],
      ),
    );
  }

  String _themeLabel(ThemePreference t) => switch (t) {
    ThemePreference.system => '跟随系统',
    ThemePreference.light => '浅色',
    ThemePreference.dark => '深色',
  };

  IconData _themeIcon(ThemePreference t) => switch (t) {
    ThemePreference.system => Icons.brightness_auto_outlined,
    ThemePreference.light => Icons.light_mode_outlined,
    ThemePreference.dark => Icons.dark_mode_outlined,
  };

  Widget _buildLeftPanel() {
    final compact = widget.settings.compactMode;
    final width = compact ? 360.0 : 400.0;
    return SizedBox(
      width: width,
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionCard(
              title: '歌曲信息',
              icon: Icons.library_music_outlined,
              compact: compact,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _titleCtrl,
                    decoration: const InputDecoration(
                      labelText: '歌曲名 *',
                      prefixIcon: Icon(Icons.title, size: 20),
                    ),
                    onSubmitted: (_) => _startSearch(),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _artistCtrl,
                    decoration: const InputDecoration(
                      labelText: '歌手',
                      prefixIcon: Icon(Icons.person_outline, size: 20),
                    ),
                    onSubmitted: (_) => _startSearch(),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _albumCtrl,
                          decoration: const InputDecoration(
                            labelText: '专辑',
                            prefixIcon: Icon(Icons.album_outlined, size: 20),
                          ),
                          onSubmitted: (_) => _startSearch(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _durationCtrl,
                          decoration: const InputDecoration(
                            labelText: '时长(秒)',
                            prefixIcon: Icon(Icons.timer_outlined, size: 20),
                          ),
                          keyboardType: TextInputType.number,
                          onSubmitted: (_) => _startSearch(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _pickAudioFile,
                          icon: const Icon(Icons.audio_file_outlined, size: 18),
                          label: const Text('浏览歌曲并搜索'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _pickAudioFolder,
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('批量处理文件夹'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '提示：可直接把音频文件或文件夹拖入窗口',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: '歌词源',
              icon: Icons.cloud_outlined,
              compact: compact,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final provider in providerCatalog.keys)
                    ProviderChip(
                      provider: provider,
                      enabled: widget.settings.providers[provider] ?? false,
                      health: _health[provider] ?? ProviderHealth.unknown,
                      onToggle: () {
                        widget.settings.update(() {
                          widget.settings.providers[provider] =
                              !(widget.settings.providers[provider] ?? false);
                        });
                        if (widget.settings.providers[provider] ?? false) {
                          _checkProviderHealth(provider);
                        }
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _startSearch,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
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
            const SizedBox(height: 12),
            _SectionCard(
              title: '保存选项',
              icon: Icons.save_outlined,
              compact: compact,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SegmentedRow(
                    label: '文件名格式',
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
                    onChanged: (s) => widget.settings.update(
                      () => widget.settings.nameFormat = s.first,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SegmentedRow(
                    label: '歌词模式',
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
                    onChanged: (s) => widget.settings.update(
                      () => widget.settings.lyricMode = s.first,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _outDirCtrl,
                          decoration: const InputDecoration(
                            labelText: '输出目录（留空=歌曲目录）',
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
                    dense: true,
                    title: const Text('覆盖已有文件'),
                    value: widget.settings.overwrite,
                    onChanged: (v) =>
                        widget.settings.update(() => widget.settings.overwrite = v),
                  ),
                ],
              ),
            ),
            if (_batchRunning) ...[
              const SizedBox(height: 12),
              _SectionCard(
                title: '批量处理',
                icon: Icons.playlist_play,
                compact: compact,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LinearProgressIndicator(
                      value: _batchTotal == 0 ? null : _batchDone / _batchTotal,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '[$_batchDone/$_batchTotal] $_batchCurrent',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '成功 $_batchSuccess · 跳过 $_batchSkipped · 失败 $_batchFailed',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => _batchCancelled = true,
                      icon: const Icon(Icons.cancel_outlined, size: 18),
                      label: const Text('取消批量处理'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRightPanel() {
    final scheme = Theme.of(context).colorScheme;
    final compact = widget.settings.compactMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 12 : 20,
            compact ? 10 : 14,
            compact ? 12 : 20,
            0,
          ),
          child: Row(
            children: [
              Text(
                '搜索结果',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              if (_receivedCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
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
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('预览'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _hasSelection
                    ? () => _saveCandidate(_selected!)
                    : null,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存选中'),
              ),
            ],
          ),
        ),
        if (_statuses.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 20,
              10,
              compact ? 12 : 20,
              4,
            ),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in _statuses.entries)
                  _ProviderStatusChip(entry.key, entry.value),
              ],
            ),
          ),
        if (_searching) ...[
          const SizedBox(height: 4),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 20),
            child: LinearProgressIndicator(
              minHeight: 2,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            child: _buildResultsArea(),
          ),
        ),
      ],
    );
  }

  bool get _hasSelection => _selected != null && _lastQuery != null;

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
      padding: EdgeInsets.all(compact ? 8 : 14),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final candidate = _results[index];
        final selected =
            _selected != null && _selected!.identityKey == candidate.identityKey;
        return Padding(
          padding: EdgeInsets.only(bottom: compact ? 8 : 10),
          child: TweenAnimationBuilder<double>(
            key: ValueKey('anim-${candidate.identityKey}'),
            tween: Tween(begin: 0, end: 1),
            duration: Duration(
              milliseconds: 240 + (index.clamp(0, 10) * 30),
            ),
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

  Widget _buildStatusBar() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(
            _statusMessage.startsWith('✅') || _statusMessage.startsWith('已保存')
                ? Icons.check_circle_outline
                : _statusMessage.startsWith('❌') ||
                        _statusMessage.startsWith('未找到')
                ? Icons.error_outline
                : _busy
                ? Icons.hourglass_top
                : Icons.info_outline,
            size: 15,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _statusMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (_searching)
            Text(
              '耗时 ${_elapsed.inSeconds}s',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDragOverlay() {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: Container(
        color: scheme.primaryContainer.withValues(alpha: 0.25),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 28),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.primary, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 30,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.file_download_outlined,
                  size: 48,
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
                  '单个音频文件将自动搜索，多个文件或文件夹将批量处理',
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.compact,
    required this.child,
  });

  final String title;
  final IconData icon;
  final bool compact;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 17, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _SegmentedRow<T> extends StatelessWidget {
  const _SegmentedRow({
    required this.label,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<T>(
            segments: segments,
            selected: selected,
            onSelectionChanged: onChanged,
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ],
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
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
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
        padding: const EdgeInsets.all(14),
        itemCount: 4,
        itemBuilder: (context, index) => Container(
          height: 96,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(14),
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

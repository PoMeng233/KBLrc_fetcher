/// 保存服务：原子写入、冲突处理、UTF-8 BOM 编码。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'lyrics_utils.dart';
import 'models.dart';

class SaveService {
  const SaveService();

  static const List<int> _utf8Bom = [0xEF, 0xBB, 0xBF];

  /// 计算渲染后的 LRC 文本。
  String render(SaveOptions options, LyricsCandidate candidate) =>
      renderLrc(
        candidate,
        lyricMode: options.lyricMode,
        includeMetadata: options.includeMetadata,
        stripTimestamps: options.stripTimestamps,
        stripTranslationLines: options.stripTranslationLines,
      );

  /// 确定输出文件名（未实际创建）。
  String filenameFor(
    SaveOptions options,
    LyricsCandidate candidate,
    TrackQuery query,
  ) => chooseOutputFilename(candidate, query, options.outputMode);

  /// 确定目标目录：优先 outDir，其次歌曲所在目录，最后当前目录。
  String targetDirFor(SaveOptions options, TrackQuery query) {
    if (options.outDir != null && options.outDir!.trim().isNotEmpty) {
      return options.outDir!;
    }
    if (query.sourceFile != null) {
      return p.dirname(query.sourceFile!);
    }
    return Directory.current.path;
  }

  /// 保存歌词。冲突时按 [policy] 处理：
  /// - `overwrite`：直接覆盖
  /// - `rename`：自动追加序号
  /// - `skip`：跳过并返回 skipped
  /// - `ask`：返回 conflict 结果，由 UI 决定后重试
  Future<SaveOutcome> save({
    required SaveOptions options,
    required LyricsCandidate candidate,
    required TrackQuery query,
    ConflictPolicy policy = ConflictPolicy.ask,
  }) async {
    final targetDir = targetDirFor(options, query);
    try {
      await Directory(targetDir).create(recursive: true);
    } catch (e) {
      return SaveOutcome(
        success: false,
        message: '无法创建目录 $targetDir：$e',
      );
    }

    var filename = filenameFor(options, candidate, query);
    var finalPath = p.join(targetDir, filename);

    if (await File(finalPath).exists() && !options.overwrite) {
      switch (policy) {
        case ConflictPolicy.overwrite:
          break;
        case ConflictPolicy.rename:
          var attempt = 1;
          do {
            filename =
                '${p.basenameWithoutExtension(filename)} ($attempt)${p.extension(filename)}';
            finalPath = p.join(targetDir, filename);
            attempt++;
          } while (await File(finalPath).exists());
        case ConflictPolicy.skip:
          return SaveOutcome(
            success: true,
            skipped: true,
            message: '已跳过（文件已存在：$filename）',
            path: finalPath,
          );
        case ConflictPolicy.ask:
          return SaveOutcome(
            success: false,
            skipped: true,
            conflict: true,
            message: '文件已存在：$filename',
            path: finalPath,
          );
      }
    }

    try {
      final content = render(options, candidate);
      await _atomicWrite(finalPath, content);
      return SaveOutcome(
        success: true,
        message: '已保存：$filename',
        path: finalPath,
      );
    } catch (e) {
      return SaveOutcome(success: false, message: '保存失败：$e');
    }
  }

  /// 原子写入：先写临时文件再重命名，避免写一半产生损坏文件。
  Future<void> _atomicWrite(String path, String content) async {
    final bytes = <int>[..._utf8Bom, ...utf8.encode(content)];
    final tmpPath = '$path.tmp-${DateTime.now().millisecondsSinceEpoch}';
    final tmp = File(tmpPath);
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      final target = File(path);
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(path);
    } finally {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }
  }
}

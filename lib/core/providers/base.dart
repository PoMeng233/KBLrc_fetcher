/// 歌词源基础设施：HTTP 请求、JSONP 解析、提供者注册表。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models.dart';

const String userAgent = 'LyricsFetcher/4.0.0 (+local app)';

/// 歌词源接口。
abstract class LyricsProvider {
  String get id;
  String get label;

  /// 搜索歌词；失败时返回空列表，异常由调用方统一处理。
  Future<List<LyricsCandidate>> search(TrackQuery query);

  /// 轻量健康检查（可选）。
  Future<bool> checkHealth() async => true;
}

final http.Client _client = http.Client();

/// GET 请求：自动附加 UA、超时、gzip 解压。
Future<http.Response> httpGet(
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? query,
  Duration timeout = const Duration(seconds: 8),
}) async {
  var uri = Uri.parse(url);
  if (query != null && query.isNotEmpty) {
    uri = uri.replace(
      queryParameters: query.map((k, v) => MapEntry(k, '$v')),
    );
  }
  final resp = await _client
      .get(
        uri,
        headers: {'User-Agent': userAgent, ...?headers},
      )
      .timeout(timeout);
  if (resp.statusCode >= 400) {
    throw http.ClientException('HTTP ${resp.statusCode} for $uri', uri);
  }
  return resp;
}

/// 兼容 gzip 响应的 UTF-8 解码。
String decodeBody(http.Response resp) {
  var bytes = resp.bodyBytes;
  final encoding = (resp.headers['content-encoding'] ?? '').toLowerCase();
  if (encoding.contains('gzip')) {
    try {
      bytes = Uint8List.fromList(gzip.decode(bytes));
    } catch (_) {}
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// 解析 JSON / JSONP 响应。
dynamic safeJsonFromJsonp(String text) {
  final stripped = text.trim();
  if (stripped.startsWith('{') || stripped.startsWith('[')) {
    return jsonDecode(stripped);
  }
  final match = RegExp(r'^[^(]+\((.*)\)\s*;?\s*$', dotAll: true)
      .firstMatch(stripped);
  if (match != null) {
    return jsonDecode(match.group(1)!);
  }
  throw const FormatException('Unable to parse JSON/JSONP response');
}

/// 歌词源实例注册表。
final Map<String, LyricsProvider> providerInstances = <String, LyricsProvider>{};

LyricsProvider registerProvider(LyricsProvider provider) =>
    providerInstances[provider.id] = provider;

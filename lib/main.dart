import 'package:flutter/material.dart';

import 'core/settings.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = AppSettings();
  await settings.load();
  runApp(KBLyricsApp(settings: settings));
}

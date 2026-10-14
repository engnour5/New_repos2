// ignore_for_file: avoid_print  -- a console script: printing is how it reports.
// Writes Guide.html next to the app, so it ships with it and can be read without starting the app.
//   flutter test tool\write_guide_html.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_nfc_tester/core/guide.dart';
import 'package:iphone_nfc_tester/core/guide_html.dart';

void main() {
  test('write Guide.html into App_file', () async {
    final html = buildGuideHtml(generatedAt: DateTime.now());
    // flutter test runs in src_file, and the app is built into the App_file folder next to it
    final file = File('${Directory.current.parent.path}\\App_file\\Guide.html');
    await file.writeAsString(html);
    print('wrote ${file.path}  (${html.length} characters, ${guideSections.length} sections)');
    expect(html, contains('<!doctype html>'));
    expect(html, contains(guideSections.last.title));
  });
}

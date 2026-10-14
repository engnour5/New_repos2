import 'dart:typed_data';

import 'apdu.dart';

enum LogKind { section, info, warn, sent, received, blocked }

class LogEntry {
  LogEntry(this.kind, this.text, {this.sw, DateTime? time}) : time = time ?? DateTime.now();

  final DateTime time;
  final LogKind kind;
  final String text;
  final int? sw;
}

/// Where the session, the check and the test report what they do.
abstract class Logger {
  void section(String text);
  void info(String text);
  void warn(String text);
  void exchange(String label, Uint8List sent, ResponseApdu response, double ms);
  void blocked(String label, Uint8List typed, String reason);
}

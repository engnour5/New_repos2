import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

/// iPhone NFC Tester: checks a contactless card the way an iPhone app (Apple Core NFC) talks to it,
/// through a PC/SC reader or the built-in card simulator.
void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(startArgs: args);
  runApp(NfcTesterApp(state: state));
  WidgetsBinding.instance.addPostFrameCallback((_) => state.start());
}

class NfcTesterApp extends StatelessWidget {
  const NfcTesterApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: state.themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'iPhone NFC Tester',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: state.messengerKey,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        home: HomeShell(state: state),
      ),
    );
  }
}

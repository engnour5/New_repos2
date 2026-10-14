import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../card/card_channel.dart';
import '../card/pcsc.dart';
import '../card/simulated_card.dart';
import '../core/apdu.dart';
import '../core/applet.dart';
import '../core/applet_log.dart';
import '../core/atr_info.dart';
import '../core/batch_report.dart';
import '../core/card_file.dart';
import '../core/card_profile.dart';
import '../core/card_reader.dart';
import '../core/card_test.dart';
import '../core/card_writer.dart';
import '../core/data_report.dart';
import '../core/error_map.dart';
import '../core/errors.dart';
import '../core/guide_html.dart';
import '../core/hex.dart';
import '../core/ios_rules.dart';
import '../core/log.dart';
import '../core/pages.dart';
import '../core/phone_check.dart';
import '../core/platform.dart';
import '../core/production.dart';
import '../core/production_report.dart';
import '../core/report.dart';
import '../core/session.dart';
import '../core/status_words.dart';

export '../core/pages.dart'; // so anything holding AppState can say Pages.check
import '../gp/batch_burn.dart';
import '../gp/cap_file.dart';
import '../gp/card_manager.dart';
import '../gp/gp_keys.dart';

/// A button under the command box. It only fills the box; nothing is sent until Send. [writes] marks the ones that
/// would change what is stored on the card, so the screen can keep them apart from the read-only ones.
class QuickCommand {
  const QuickCommand(this.label, this.hex, {this.writes = false});

  final String label;
  final String hex;
  final bool writes;
}

enum PhonePhase { idle, tapping, connected, success, warning, failure }

enum ConsoleKind { tap, exchange, notSent, note, summary }

class ConsoleItem {
  ConsoleItem(this.kind,
      {this.lineNo, this.typed, this.sent, this.response, this.ms = 0, this.reason, this.verdict, this.verdictOk, this.text, this.ok = true});

  final ConsoleKind kind;
  final int? lineNo;
  final Uint8List? typed;
  final Uint8List? sent;
  final ResponseApdu? response;
  final double ms;
  final String? reason;
  final String? verdict;
  final bool? verdictOk;
  final String? text;
  final bool ok;
}

/// The results the pages show for one phone. iPhone and Android each keep their own, so switching phones shows that
/// phone's last results (or nothing yet), never the other phone's.
class PhoneResults {
  PhoneResults(this.platform);

  final PhonePlatform platform;

  // the phone picture
  PhonePhase phase = PhonePhase.idle;
  String phoneTitle = 'Not connected';
  String phoneDetail = 'Choose the reader and click Connect';

  // page 1: phone check
  final List<StepRow> checkRows = [];
  String verdict = '';
  bool? verdictYes;
  int verdictWarnings = 0;
  DateTime? checkTime;
  String? checkError; // why the last check stopped

  // page 2: APDU console
  final List<ConsoleItem> consoleItems = [];
  int commandNo = 0;

  // page 3: read card
  CardReadResult? readResult;
  int readProgress = 0;
  String? readReportPath;

  // page 3: write card
  CardWriteResult? writeResult;

  // page 4: card unit test
  final List<CheckRow> testRows = [];
  String testSummary = '';
  DateTime? testTime;
  int? cardSize;
  String cardSizeStop = '';
}

/// Everything the screens show, and the card work behind the buttons.
class AppState extends ChangeNotifier implements Logger {
  /// [simulator] is only passed by the tests, which give it no delay so a run finishes at once.
  AppState({this.startArgs = const [], this.writeFiles = true, SimulatedCard? simulator})
      : simulator = simulator ?? SimulatedCard() {
    aidController.text = defaultAidList;
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
  }

  static const defaultAidList = AppletAid.defaultHex;

  /// The applet every screen talks to: the first usable AID in the box at the top. Burning an applet with another AID
  /// puts that one there, so the check, the console, the read and the full test all follow the card.
  Uint8List get appletAid {
    final usable = IosRules.parse(aidController.text).entries.where((e) => e.usable).firstOrNull;
    return usable?.aid ?? AppletAid.byDefault;
  }

  /// Puts [aid] at the front of the AID box, keeping whatever else is listed.
  void useAppletAid(Uint8List aid) {
    final rest = IosRules.parse(aidController.text)
        .entries
        .where((e) => e.aid == null || !Hex.same(e.aid!, aid))
        .map((e) => e.text.trim())
        .where((t) => t.isNotEmpty);
    aidController.text = [Hex.of(aid), ...rest].join(', ');
    notifyListeners();
  }

  final List<String> startArgs;

  /// False in the tests: reports, logs and dumps are then not written to disk.
  final bool writeFiles;
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  final commandController = TextEditingController();
  final aidController = TextEditingController();
  final themeMode = ValueNotifier<ThemeMode>(ThemeMode.dark);
  final SimulatedCard simulator;

  int page = 0;
  PhonePlatform platform = PhonePlatform.iphone;

  /// How the Read, Write and Block-editor screens talk to the card: which file to select, how to read and write, how
  /// big it is. The EMG profile is the default, so nothing changes for the EMG card. The console and Burner ignore it.
  final List<CardProfile> profiles = [...CardProfile.builtInProfiles];
  CardProfile cardProfile = CardProfile.emg;

  /// Switches the active card profile, and points the AID box at the profile's applet(s).
  void setCardProfile(CardProfile p) {
    cardProfile = p;
    aidController.text = p.aidHex;
    info('Card profile: ${p.name}. The AID box now holds its applet(s).');
    notifyListeners();
  }

  static String get _profilesFile {
    final appData = Platform.environment['APPDATA'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return '$appData\\NFC Card Tester\\card_profiles.json';
  }

  /// Reads the custom profiles saved last time, keeping the built-in ones first.
  Future<void> _loadProfiles() async {
    try {
      final f = File(_profilesFile);
      if (!f.existsSync()) return;
      final custom = CardProfile.decode(await f.readAsString());
      profiles
        ..clear()
        ..addAll(CardProfile.builtInProfiles)
        ..addAll(custom);
    } catch (_) {
      // a damaged profiles file should not stop the app from starting
    }
  }

  Future<void> saveProfiles() async {
    if (!writeFiles) return;
    try {
      final f = File(_profilesFile);
      await f.parent.create(recursive: true);
      await f.writeAsString(CardProfile.encode(profiles));
    } catch (e) {
      snack('Could not save the profiles: $e', error: true);
    }
  }

  /// Adds or replaces a custom profile (matched by name), makes it active, and saves them.
  Future<void> addProfile(CardProfile p) async {
    final problem = p.problem;
    if (problem != null) {
      snack(problem, error: true);
      return;
    }
    profiles.removeWhere((x) => !x.builtIn && x.name == p.name);
    profiles.add(p);
    setCardProfile(p);
    await saveProfiles();
    snack('Saved the "${p.name}" card profile.');
  }

  Future<void> deleteProfile(CardProfile p) async {
    if (p.builtIn) return;
    profiles.remove(p);
    if (cardProfile.name == p.name) setCardProfile(CardProfile.emg);
    await saveProfiles();
  }

  List<String> readers = [];
  String? selected;

  // connection (Connect / Disconnect)
  bool connected = false;
  bool connecting = false;
  String? connectedReader;
  Uint8List? cardAtr;
  Uint8List? cardUid;
  Uint8List? cardId; // the applet's card ID, from the last GET UID (80 08) answer
  AtrInfo? cardInfo;

  bool busy = false;
  String busyTitle = '';
  String? lastError;

  CardChannel? _channel;
  String? _channelKey;
  PhoneSession? session;

  final Map<PhonePlatform, PhoneResults> _results = {for (final p in PhonePlatform.values) p: PhoneResults(p)};

  /// The results of the phone chosen at the top. The pages read everything through it.
  PhoneResults get results => _results[platform]!;
  PhoneResults resultsFor(PhonePlatform p) => _results[p]!;

  PhonePhase get phase => results.phase;
  String get phoneTitle => results.phoneTitle;
  String get phoneDetail => results.phoneDetail;

  List<StepRow> get checkRows => results.checkRows;
  String get verdict => results.verdict;
  bool? get verdictYes => results.verdictYes;
  int get verdictWarnings => results.verdictWarnings;
  PhonePlatform? get checkPlatform => results.checkTime == null ? null : platform;
  DateTime? get checkTime => results.checkTime;
  String? get checkError => results.checkError;

  List<ConsoleItem> get consoleItems => results.consoleItems;
  final List<String> commandHistory = []; // oldest first; shared, so a command typed for one phone can be sent as the other

  CardReadResult? get readResult => results.readResult;
  bool reading = false;
  int get readProgress => results.readProgress;
  String? get readReportPath => results.readReportPath;

  CardWriteResult? get writeResult => results.writeResult;
  bool writing = false;
  int writeProgress = 0;

  /// The last write whose old bytes are known, so "Undo last write" can put them back. It belongs to the card, not
  /// to a phone, and it only goes back to the card it was made on.
  CardWriteResult? undoable;

  List<CheckRow> get testRows => results.testRows;
  String get testSummary => results.testSummary;
  bool testRunning = false;
  PhonePlatform? get testPlatform => results.testTime == null ? null : platform;
  DateTime? get testTime => results.testTime;
  int? get cardSize => results.cardSize;
  String get cardSizeStop => results.cardSizeStop;

  final List<LogEntry> logEntries = [];

  /// Keeps the live log along the bottom open after a run has finished. While a run is going it opens by itself, so
  /// every test can be watched without leaving its page.
  bool logDockPinned = false;

  bool get logDockOpen => logDockPinned || busy;

  void toggleLogDock() {
    // closing it during a run means "leave it closed", so the pin follows what is on screen now
    logDockPinned = !logDockOpen;
    notifyListeners();
  }

  Timer? _ticker;
  bool _notifyQueued = false;
  bool _disposed = false;

  bool get usingSimulator => selected == SimulatedCard.key;

  /// The buttons that talk to the card work only after Connect.
  bool get canRun => connected && !busy;

  // ------------------------------------------------------------------ start, readers, theme, platform

  Future<void> start() async {
    await _gpLoadOwnKeys();
    await _loadProfiles();
    await refreshReaders();
    if (startArgs.contains('--sim')) selected = SimulatedCard.key;
    if (startArgs.contains('--light')) themeMode.value = ThemeMode.light;
    if (startArgs.contains('--android')) platform = PhonePlatform.android;
    notifyListeners();
    final run = startArgs.any((a) => a.startsWith('--run-'));
    if (startArgs.contains('--connect') || run) await connect();
    if (startArgs.contains('--run-check')) {
      await runCheck();
    } else if (startArgs.contains('--run-test')) {
      await runTest();
    } else if (startArgs.contains('--run-read')) {
      await readCard(openReport: false);
    } else if (startArgs.contains('--run-all')) {
      await runAllTests();
    } else if (startArgs.contains('--run-burner')) {
      // read-only: read the key file, open the secure channel and list what is on the card. Nothing is changed.
      final i = startArgs.indexOf('--keys');
      // the keys the tool already holds are used unless another file is named
      if (i >= 0 && i + 1 < startArgs.length) {
        await gpReadKeyFile(startArgs[i + 1]);
      } else if (gpKeys == null) {
        await gpReadKeyFile();
      }
      if (gpKeys != null) await gpAuthenticate();
    } else if (startArgs.contains('--run-console')) {
      for (final q in quickCommands.where((q) => !q.writes).take(5)) {
        await sendCommand(q.hex);
      }
      await sendCommand('00 A4 04 00 05 A0 00 00 09 99'); // shows what iOS blocks
      useCommand('00 B0 00 00 10');
    }
    final p = startArgs.indexOf('--page'); // applied after a --run-..., so a run can be followed by another page
    if (p >= 0 && p + 1 < startArgs.length) {
      final n = int.tryParse(startArgs[p + 1]);
      if (n != null && n >= 1 && n <= Pages.count) setPage(n - 1);
    }
    if (startArgs.contains('--report')) await saveHtmlReport(open: false);
  }

  /// Shows the page a run belongs to, unless "Run all tests" is driving: it keeps you on its own page so you can
  /// watch the stages go by instead of being thrown between screens.
  void _goTo(int value) {
    if (!runAllRunning) page = value;
  }

  void setPage(int value) {
    Tooltip.dismissAllToolTips(); // a tooltip of the page we leave must not stay on screen
    page = value;
    notifyListeners();
  }

  void toggleTheme() {
    themeMode.value = themeMode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  }

  void setPlatform(PhonePlatform value) {
    if (busy || value == platform) return;
    platform = value;
    session?.end(); // a phone of another kind starts with a new tap
    session?.platform = value;
    info('Phone rules: ${value.short}. The pages show the ${value.short} results.');
    // the pages now show this phone's own results; a tap it was in the middle of is over, as the session ended
    if (connected && (phase == PhonePhase.tapping || phase == PhonePhase.connected)) {
      _phone(PhonePhase.idle, 'Connected', 'Ready to act as an ${value.phone}');
    }
    notifyListeners();
  }

  Future<void> refreshReaders() async {
    if (busy || connected) return;
    List<String> list;
    try {
      list = await PcscChannel.listReaders();
    } catch (e) {
      list = const [];
      warn('Cannot list the readers: $e');
    }
    readers = list;
    final keys = [...list, SimulatedCard.key];
    if (selected == null || !keys.contains(selected)) {
      selected = list.firstWhere((r) => AtrInfo.looksContactless(r) && !r.toLowerCase().contains('virtual'),
          orElse: () => SimulatedCard.key);
    }
    info('Readers: ${list.isEmpty ? 'none found' : list.join(' | ')}');
    notifyListeners();
  }

  void selectReader(String key) {
    if (busy || connected) return;
    selected = key;
    notifyListeners();
  }

  // ------------------------------------------------------------------ Connect / Disconnect

  /// Opens the reader (exclusive), powers the card and reads its ATR and UID. No command reaches the applet yet.
  Future<void> connect() async {
    if (busy || connected || connecting) return;
    final key = selected;
    if (key == null) {
      snack('Choose a reader first.');
      return;
    }
    connecting = true;
    lastError = null;
    notifyListeners();
    final s = _sessionFor(key);
    try {
      section('Connect: $key');
      await s.channel.connect();
      cardAtr = s.channel.atr;
      cardUid = await s.channel.getUid();
      cardInfo = AtrInfo.parse(cardAtr);
      connected = true;
      connectedReader = key;
      info('Connected. ATR ${cardAtr == null ? '-' : Hex.of(cardAtr)}${cardUid == null ? '' : ', UID ${Hex.of(cardUid)}'}. '
          '${cardInfo!.isoDep ? 'Contactless ISO-DEP card.' : cardInfo!.description}');
      _phoneAll(PhonePhase.idle, 'Connected', (p) => 'Ready to act as an ${p.phone}');
    } on CardException catch (e) {
      lastError = e.message;
      warn('Connect failed: ${e.message}');
      _phoneAll(PhonePhase.failure, 'Not connected', (_) => e.message);
      snack(e.message, error: true);
    } catch (e) {
      lastError = '$e';
      warn('Connect failed: $e');
      snack('$e', error: true);
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  /// Ends the phone session and releases the reader, so other programs (PyApduTool) can use it.
  Future<void> disconnect() async {
    if (busy) return;
    session?.end();
    final ch = _channel;
    if (ch != null) {
      try {
        await ch.disconnect();
      } catch (_) {
        // already gone
      }
    }
    if (connected) info('Disconnected. Other programs, such as PyApduTool, can use the reader now.');
    _markDisconnected();
    notifyListeners();
  }

  void _markDisconnected() {
    gpManager = null; // the reader is gone, and with it any card-manager channel
    gpContents = null;
    connected = false;
    connectedReader = null;
    cardAtr = null;
    cardUid = null;
    cardInfo = null;
    _phoneAll(PhonePhase.idle, 'Not connected', (_) => 'Choose the reader and click Connect');
  }

  // ------------------------------------------------------------------ work

  /// The open reader, for the work that is not a phone at all: the card manager.
  CardChannel? get channel => _channel;

  PhoneSession _sessionFor(String key) {
    final rules = IosRules.parse(aidController.text);
    if (_channel == null || _channelKey != key) {
      final old = _channel;
      if (old != null && !old.isSimulated) old.dispose();
      final channel = key == SimulatedCard.key ? simulator : PcscChannel(key);
      _channel = channel;
      _channelKey = key;
      final s = PhoneSession(channel, rules, this, platform: platform);
      s.onTapStart = () {
        _phone(PhonePhase.tapping, 'Tap',
            s.platform == PhonePlatform.iphone ? 'The card meets the iPhone. iOS selects the AIDs of the list.' : 'The card touches the Android phone.');
        _changed();
      };
      s.onTapDone = (found) {
        if (found) {
          _phone(PhonePhase.connected, 'Card found',
              s.platform == PhonePlatform.iphone ? 'initialSelectedAID ${s.initialSelectedAid}' : 'IsoDep, no AID needed');
        } else {
          _phone(PhonePhase.failure, 'Card not found',
              s.platform == PhonePlatform.iphone ? 'No AID of the list answered 90 00' : 'The card is not ISO-DEP');
        }
        _changed();
      };
      session = s;
    }
    session!
      ..rules = rules
      ..platform = platform;
    return session!;
  }

  /// Runs [body] on the phone session. Returns false when it did not run (not connected) or stopped with an error.
  Future<bool> _work(String title, Future<void> Function(PhoneSession s) body) async {
    if (busy) return false;
    if (!connected) {
      snack('Connect first: choose the reader at the top and click Connect.');
      return false;
    }
    final s = _sessionFor(connectedReader!);
    // every phone job taps, and a tap powers the card down and up, which ends any card-manager channel
    closeGpChannel('this job taps the card, and a tap resets it');
    busy = true;
    busyTitle = title;
    lastError = null;
    notifyListeners();
    try {
      await body(s);
      return true;
    } on CardException catch (e) {
      _stopped(title, e.message);
      if (scardConnectionLost(e.code)) {
        _markDisconnected();
        info('The connection is lost. Click Connect again.');
      }
    } catch (e) {
      _stopped(title, '$e');
    } finally {
      busy = false;
      busyTitle = '';
      notifyListeners();
    }
    return false;
  }

  void _stopped(String title, String message) {
    lastError = message;
    warn('$title stopped: $message');
    _phone(PhonePhase.failure, 'Stopped', message);
    snack(message, error: true);
  }

  /// The phone picture of the phone chosen at the top.
  void _phone(PhonePhase p, String title, String detail) {
    results
      ..phase = p
      ..phoneTitle = title
      ..phoneDetail = detail;
  }

  /// The phone picture of both phones, for what both share: the connection.
  void _phoneAll(PhonePhase p, String title, String Function(PhonePlatform p) detail) {
    for (final r in _results.values) {
      r
        ..phase = p
        ..phoneTitle = title
        ..phoneDetail = detail(r.platform);
    }
  }

  // ------------------------------------------------------------------ page 1: phone check

  Future<void> runCheck() async {
    if (busy) return;
    _goTo(Pages.check);
    final r = results; // the phone chosen now; it cannot change while the check runs
    r.checkRows.clear();
    r.verdict = '';
    r.verdictYes = null;
    r.verdictWarnings = 0;
    r.checkError = null;
    notifyListeners();
    final ran = await _work('${platform.short} check', (s) async {
      section('${s.platform.short} check: ${s.channel.name}');
      r.checkTime = DateTime.now();
      final check = PhoneCheck(appletAid: appletAid, (row) {
        r.checkRows.add(row);
        _changed();
      });
      await check.run(s);
      r.verdict = check.verdict;
      r.verdictYes = check.yes;
      r.verdictWarnings = check.warnings;
      if (!check.yes) {
        _phone(PhonePhase.failure, 'NO', 'An ${s.platform.app} would not work with this card');
      } else if (check.warnings > 0) {
        _phone(PhonePhase.warning, 'YES', 'Works, with ${check.warnings} warning${check.warnings == 1 ? '' : 's'}');
      } else {
        _phone(PhonePhase.success, 'YES', 'Works with an ${s.platform.app}');
      }
      info('Verdict: ${check.verdict}');
    });
    if (!ran && r.checkRows.isNotEmpty) r.checkError = lastError;
  }

  // ------------------------------------------------------------------ page 2: APDU console

  Future<void> runTap() async {
    if (busy) return;
    page = Pages.console;
    await _work('Tap', (s) async {
      await _consoleTap(s);
    });
  }

  Future<bool> _consoleTap(PhoneSession s) async {
    final found = await s.tap();
    final ios = s.platform == PhonePlatform.iphone;
    consoleItems.add(ConsoleItem(ConsoleKind.tap,
        ok: found,
        text: found
            ? (ios
                ? 'Tap: the app got the card, initialSelectedAID ${s.initialSelectedAid}. The 60 s session starts now.'
                : 'Tap: Android gave the card to the app as IsoDep. No session limit.')
            : (ios ? 'Tap: the app did NOT get the card. No AID of the list answered 90 00.' : 'Tap: the card is not ISO-DEP.')));
    _changed();
    return found;
  }

  /// Common commands for the applet in the AID box. A button only fills the box: nothing reaches the card until Send
  /// is pressed, so the writing ones are safe to click and then edit.
  List<QuickCommand> get quickCommands => [
    QuickCommand('SELECT applet', AppletAid.select(appletAid)),
    QuickCommand('GET UID', '80 08 00 00 0A'),
    QuickCommand('SELECT EF 3040', '00 A4 00 00 02 30 40'),
    QuickCommand('SELECT MF 3F00', '00 A4 00 00 02 3F 00'),
    QuickCommand('READ 16 bytes', '00 B0 00 00 10'),
    QuickCommand('READ 256 bytes', '00 B0 00 00 00'),
    QuickCommand('READ byte 7FFF', '00 B0 7F FF 01'),
    // UPDATE BINARY. EF 3040 has to be selected first, or the applet answers 69 86.
    QuickCommand('WRITE 2 bytes at 0000', '00 D6 00 00 02 11 22', writes: true),
    QuickCommand('WRITE 16 bytes at 0000', '00 D6 00 00 10 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F', writes: true),
    QuickCommand('WRITE byte 7FFF', '00 D6 7F FF 01 5A', writes: true),
  ];

  void useCommand(String hex) {
    commandController.value = TextEditingValue(text: hex, selection: TextSelection.collapsed(offset: hex.length));
  }

  /// Sends the one APDU typed in the box (or [text]) under the current phone's rules. If there is no phone session
  /// yet, or the iPhone session is over, it taps first.
  Future<void> sendCommand([String? text]) async {
    if (busy) return;
    final input = (text ?? commandController.text).trim();
    if (input.isEmpty) {
      snack('Type an APDU in hex, for example 00 A4 00 00 02 30 40.');
      return;
    }
    Uint8List apdu;
    try {
      apdu = Hex.parse(input);
    } on FormatException catch (e) {
      snack(e.message, error: true);
      return;
    }
    if (apdu.length < 4) {
      snack('An APDU needs at least 4 bytes: CLA INS P1 P2.', error: true);
      return;
    }
    page = Pages.console;
    final shown = Hex.of(apdu);
    commandHistory.remove(shown);
    commandHistory.add(shown);
    if (commandHistory.length > 30) commandHistory.removeAt(0);
    await _work('APDU console', (s) async {
      if (!s.active || !s.detected || s.expired) {
        consoleItems.add(ConsoleItem(ConsoleKind.note,
            text: s.expired ? 'The iPhone session is over (60 s). Tapping again.' : 'No phone session yet. Tapping first.'));
        if (!await _consoleTap(s)) return;
      }
      final no = ++results.commandNo;
      final r = await s.send(apdu, 'command $no');
      consoleItems.add(ConsoleItem(r.ok ? ConsoleKind.exchange : ConsoleKind.notSent,
          lineNo: no, typed: r.typed, sent: r.sent, response: r.response, ms: r.ms, reason: r.reason));
      _changed();
    });
  }

  void clearConsole() {
    consoleItems.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------------ page 3: read card

  /// Reads the whole card (read-only), keeping everything that can be read even when some of it fails, then always
  /// writes the HTML data report and opens it. The page shows the data first, then the exception.
  Future<void> readCard({bool openReport = true}) async {
    if (busy) return;
    _goTo(Pages.read);
    final r = results;
    r.readResult = null;
    r.readProgress = 0;
    r.readReportPath = null;
    reading = true;
    notifyListeners();
    await _work('Read card', (s) async {
      final reader = CardReader(s, this, appletAid: appletAid, profile: cardProfile, onProgress: (n) {
        r.readProgress = n;
        _changed();
      });
      final result = await reader.run();
      r.readResult = result;
      if (result.cardId != null) cardId = result.cardId;
      r.readReportPath = await _saveAndShow(
        'card_data',
        'html',
        buildDataReport(result,
            reader: connectedReader ?? selected ?? '-',
            atr: cardAtr == null ? null : Hex.of(cardAtr),
            uid: cardUid == null ? null : Hex.of(cardUid)),
        bom: false,
        openFile: openReport,
        openFolder: false,
      );
      final kb = '${(result.expected / 1024).toStringAsFixed(result.expected % 1024 == 0 ? 0 : 1)} KB';
      if (result.ok && result.warnings.isEmpty) {
        _phone(PhonePhase.success, '$kb OK', 'All ${result.expected} bytes were read');
      } else if (result.ok) {
        _phone(PhonePhase.warning, '$kb OK', 'All bytes read, ${result.warnings.length} warning${result.warnings.length == 1 ? '' : 's'}');
      } else {
        _phone(PhonePhase.failure, 'Exception', '${result.bytesRead} of ${result.expected} bytes read');
        warn(result.message);
      }
    });
    reading = false;
    notifyListeners();
  }

  /// Saves the last read as a 32768-byte .bin file (offset = file position). Bytes that were not read are 00.
  Future<void> saveReadBin() async {
    final r = readResult;
    if (r == null || r.bytesRead == 0) {
      snack('Read the card first.');
      return;
    }
    await _saveBytes(r.bytesRead == r.expected ? 'card_data' : 'card_data_partial', 'bin', r.image);
    if (r.bytesRead < r.expected) {
      snack('Saved a ${r.expected}-byte .bin; the ${r.expected - r.bytesRead} bytes that were not read are 00 in it.');
    }
  }

  /// Saves the last read as hex text, the form the Elsewedy Smart Card Utility writes and reads, so the two tools can
  /// pass card files to each other.
  Future<void> saveReadHexText() async {
    final r = readResult;
    if (r == null || r.bytesRead == 0) {
      snack('Read the card first.');
      return;
    }
    final whole = r.bytesRead == r.expected;
    await _saveAndShow(whole ? 'card_data' : 'card_data_partial', 'txt', CardFile.toHexText(r.image), bom: false);
    if (!whole) {
      snack('Saved all ${r.expected} bytes as hex; the ${r.expected - r.bytesRead} bytes '
          'that were not read are 00 in it.');
    }
  }

  Future<void> openReadReport() async {
    final path = readReportPath;
    if (path == null) return;
    await Process.run('explorer.exe', [path]);
  }

  // ------------------------------------------------------------------ page 3: block editor

  bool blockReading = false;

  /// Reads [length] bytes of EF 3040 from [offset], for the block editor. Returns the bytes, or null when the read
  /// could not be done (the reason is shown). It taps, selects the applet (a failure there is only a warning, as the
  /// default applet may still answer), then SELECT EF 3040, which must work, and READ BINARY 256 bytes at a time.
  Future<Uint8List?> readBlocks(int offset, int length, {String label = 'Block editor'}) async {
    if (busy) return null;
    final profile = cardProfile;
    if (offset < 0 || length <= 0 || offset + length > profile.fileSize) {
      snack('That range is outside the card (0000-${h4(profile.lastOffset)}).', error: true);
      return null;
    }
    Uint8List? out;
    blockReading = true;
    notifyListeners();
    await _work('Read ${(length / 16).ceil()} block${length == 16 ? '' : 's'} from ${h4(offset)}', (s) async {
      await s.tap();
      await s.sendHex(AppletAid.select(appletAid), '$label: SELECT applet');
      if (profile.hasIdCommand) {
        final idr = await s.sendHex(profile.idCommand, '$label: card ID');
        if (idr.ok && idr.response!.sw == 0x9000 && idr.response!.data.isNotEmpty) cardId = idr.response!.data;
      }
      if (profile.hasSelectFile) {
        final ef = await s.sendHex(profile.selectFile, '$label: SELECT file');
        if (!(ef.ok && ef.response!.sw == 0x9000)) {
          throw CardException('SELECT file answered ${ef.ok ? ef.response!.swText : (ef.reason ?? ef.short)}.');
        }
      }
      final buf = Uint8List(length);
      var pos = 0;
      while (pos < length) {
        final at = offset + pos;
        final want = length - pos < 256 ? length - pos : 256;
        String read(int le) => profile.readCommand(at, le);
        var r = await s.sendHex(read(want), '$label: READ ${h4(at)}');
        if (r.ok && r.response!.sw1 == 0x6C) {
          // the card says how many are left: re-read with that length
          r = await s.sendHex(read(r.response!.sw2), '$label: READ ${h4(at)} Le ${h2(r.response!.sw2)}');
        }
        if (!(r.ok && r.response!.sw == 0x9000 && r.response!.data.isNotEmpty)) {
          throw CardException('READ at ${h4(at)} answered ${r.ok ? r.response!.swText : (r.reason ?? r.short)}.');
        }
        final got = r.response!.data;
        final n = got.length < length - pos ? got.length : length - pos;
        buf.setRange(pos, pos + n, got, 0);
        pos += n;
      }
      out = buf;
    });
    blockReading = false;
    notifyListeners();
    return out;
  }

  // ------------------------------------------------------------------ applet command log (80 F0/F1/F2/F3)

  /// The decoded records from the last "Read log", and the one-line status (count + bytes). Null until read.
  List<AppletLogRecord>? appletLog;
  String? appletLogStatus;

  /// Sends one log-control command (80 F0 arm, 80 F1 freeze) after selecting the applet.
  Future<void> _logCmd(String title, String hex) async {
    if (busy) return;
    await _work(title, (s) async {
      await s.tap();
      await s.sendHex(AppletAid.select(appletAid), '$title: SELECT applet');
      final r = await s.sendHex(hex, title);
      if (!(r.ok && r.response!.sw == 0x9000)) {
        throw CardException('$title answered ${r.short}'
            '${r.sw == 0x6D00 ? ' - this card has no logger. Burn the logger applet build.' : ''}.');
      }
    });
    notifyListeners();
  }

  /// Clears the applet log and turns logging ON (80 F0). Send this before a capture.
  Future<void> armAppletLog() => _logCmd('Arm log (80 F0)', '80 F0 00 00');

  /// Turns logging OFF (80 F1). Send after a capture, before reading, so the read does not pollute the log.
  Future<void> freezeAppletLog() => _logCmd('Freeze log (80 F1)', '80 F1 00 00');

  /// Reads the applet's own command log: 80 F2 for the size, then 80 F3 in 256-byte chunks, decoded into [appletLog].
  Future<void> readAppletLog() async {
    if (busy) return;
    appletLog = null;
    appletLogStatus = null;
    notifyListeners();
    await _work('Read applet log', (s) async {
      await s.tap();
      await s.sendHex(AppletAid.select(appletAid), 'Read applet log: SELECT applet');
      final st = await s.sendHex('80 F2 00 00 04', 'Read applet log: 80 F2 status');
      if (!(st.ok && st.response!.sw == 0x9000 && st.response!.data.length >= 4)) {
        throw CardException('Log status (80 F2) answered ${st.short}'
            '${st.sw == 0x6D00 ? ' - this card has no logger. Burn the logger applet build.' : ''}.');
      }
      final d0 = st.response!.data;
      final count = (d0[0] << 8) | d0[1];
      final ptr = (d0[2] << 8) | d0[3];
      appletLogStatus = '$count record${count == 1 ? '' : 's'}, $ptr bytes';
      final bytes = <int>[];
      for (var off = 0; off < ptr; off += 256) {
        final r = await s.sendHex('80 F3 ${h2((off >> 8) & 0xff)} ${h2(off & 0xff)} 00', 'Read applet log: 80 F3 @${h4(off)}');
        if (!(r.ok && r.response!.sw == 0x9000)) {
          throw CardException('Log read (80 F3) at ${h4(off)} answered ${r.short}.');
        }
        bytes.addAll(r.response!.data);
      }
      final d = bytes.length > ptr ? bytes.sublist(0, ptr) : bytes;
      final recs = <AppletLogRecord>[];
      for (var i = 0; i + AppletLogRecord.size <= d.length; i += AppletLogRecord.size) {
        recs.add(AppletLogRecord(Uint8List.fromList(d.sublist(i, i + AppletLogRecord.size))));
      }
      appletLog = recs;
    });
    notifyListeners();
  }

  // ------------------------------------------------------------------ page 3: write card

  /// Writes [request] into EF 3040 under the chosen phone's rules, then reads it back. The bytes there before are kept
  /// for "Undo last write" and saved as card_backup_*.bin.
  Future<void> writeCard(CardWriteRequest request, {bool skipUnchanged = true}) =>
      _write(request, skipUnchanged: skipUnchanged);

  /// Writes back what the last write replaced, but only on the card it was made on.
  Future<void> undoLastWrite() async {
    final u = undoable;
    final old = u?.before;
    if (u == null || old == null) {
      snack('There is no write to undo.');
      return;
    }
    // only the part that was done changed the card; the rest of the range still holds what it held
    await _write(
        CardWriteRequest(u.request.offset, Uint8List.sublistView(old, 0, u.done),
            source: 'undo of ${u.request.range}', fileSize: cardProfile.fileSize),
        undoOf: u);
  }

  Future<void> _write(CardWriteRequest request, {bool skipUnchanged = true, CardWriteResult? undoOf}) async {
    if (busy) return;
    final problem = request.problem;
    if (problem != null) {
      snack(problem, error: true);
      return;
    }
    _goTo(Pages.read);
    final r = results;
    r.writeResult = null;
    writing = true;
    writeProgress = 0;
    notifyListeners();
    await _work(undoOf == null ? 'Write card' : 'Undo write', (s) async {
      final writer = CardWriter(s, this, request,
          appletAid: appletAid, profile: cardProfile, skipUnchanged: skipUnchanged, expectCardId: undoOf?.cardId, onProgress: (n) {
        writeProgress = n;
        _changed();
      });
      final result = await writer.run();
      r.writeResult = result;
      if (result.cardId != null) cardId = result.cardId;
      if (result.changedCard) {
        // what Read card showed is not what the card holds any more
        for (final x in _results.values) {
          x
            ..readResult = null
            ..readProgress = 0
            ..readReportPath = null;
        }
        info('The card was written, so the earlier Read card results were cleared.');
      }
      if (undoOf != null) {
        if (result.ok) undoable = null; // undone: nothing left to put back
      } else if (result.before != null && result.changedCard) {
        undoable = result;
        // named after the range it holds, so writing it back at that offset puts the card as it was
        result.backupPath = await _saveBytes('card_backup_${h4(request.offset)}-${h4(request.offset + result.done - 1)}',
            'bin', Uint8List.sublistView(result.before!, 0, result.done),
            quiet: true);
      }
      if (result.ok && result.warnings.isEmpty) {
        _phone(PhonePhase.success, undoOf == null ? 'Written' : 'Undone', '${request.length} bytes at ${request.range}, read back');
      } else if (result.ok) {
        _phone(PhonePhase.warning, undoOf == null ? 'Written' : 'Undone',
            '${result.warnings.length} warning${result.warnings.length == 1 ? '' : 's'}');
      } else {
        _phone(PhonePhase.failure, 'Write stopped', '${result.done} of ${request.length} bytes');
        warn(result.message);
      }
    });
    writing = false;
    notifyListeners();
  }

  /// Shows the backup of the last write in Explorer.
  Future<void> openWriteBackup() async {
    final path = writeResult?.backupPath ?? undoable?.backupPath;
    if (path == null) return;
    await Process.run('explorer.exe', ['/select,', path]);
  }

  // ------------------------------------------------------------------ page 4: card unit test

  Future<void> runTest() async {
    if (busy) return;
    _goTo(Pages.test);
    final r = results;
    r.testRows.clear();
    r.testSummary = '';
    r.cardSize = null;
    r.cardSizeStop = '';
    testRunning = true;
    notifyListeners();
    await _work('Card Unit Test', (s) async {
      r.testTime = DateTime.now();
      final test = CardTest(s, this, appletAid: appletAid, onRow: (row) {
        r.testRows.add(row);
        _changed();
      });
      try {
        await test.run();
      } finally {
        r.testSummary = test.summary;
        r.cardSize = test.cardSize;
        r.cardSizeStop = test.cardSizeStop;
        testRunning = false;
      }
      final failed = test.failed;
      if (failed == 0) {
        _phone(PhonePhase.success, 'All good', 'The card unit test works the ${s.platform.short} way');
      } else {
        _phone(PhonePhase.failure, '$failed failed', 'See the red rows');
      }
    });
    testRunning = false;
    notifyListeners();
  }

  Future<void> saveCsv() async {
    if (testRows.isEmpty) {
      snack('Run the test first.');
      return;
    }
    String cell(String v) => '"${v.replaceAll('"', '""')}"';
    final sb = StringBuffer('"Group","Id","Result","Check","APDU","Expected","Got","ms","Type","Error map"\r\n');
    for (final r in testRows) {
      sb.write([
        r.group.name,
        r.id,
        r.result,
        r.check,
        r.apdu,
        r.expected,
        r.got,
        r.ms.toStringAsFixed(1),
        r.answer?.tag ?? '',
        r.answer?.text ?? '',
      ].map(cell).join(','));
      sb.write('\r\n');
    }
    await _saveAndShow('card_test', 'csv', sb.toString());
  }

  // ------------------------------------------------------------------ page 5: run all tests

  /// The extra production checks, and the picture every run adds up to.
  final List<StepRow> productionRows = [];
  ProductionSummary? production;
  DateTime? productionTime;
  double productionSeconds = 0;
  String? productionReportPath;
  final List<String> productionDataReports = [];

  /// Which part of "Run all tests" is going on, so the screen can show it. Empty when nothing is running.
  String runAllStage = '';
  bool runAllRunning = false;

  /// The stages, in the order they run. The screen lists them before anything starts.
  static const runAllStages = [
    'iPhone check',
    'iPhone read card',
    'iPhone card unit test',
    'Android check',
    'Android read card',
    'Android card unit test',
    'Production checks',
  ];

  /// Runs every test on both phones, then the production checks, then writes one report.
  ///
  /// The read-only runs come first on each phone, and the card unit test last, so a card that is already wrong is
  /// found before anything is written to it.
  Future<void> runAllTests() async {
    if (busy || runAllRunning) return;
    if (!connected) {
      snack('Connect first: choose the reader at the top and click Connect.');
      return;
    }
    final watch = Stopwatch()..start();
    page = Pages.runAll;
    runAllRunning = true;
    productionRows.clear();
    productionDataReports.clear();
    production = null;
    productionReportPath = null;
    productionTime = DateTime.now();
    final wanted = platform;
    notifyListeners();
    try {
      for (final p in PhonePlatform.values) {
        setPlatform(p);
        runAllStage = '${p.short} check';
        notifyListeners();
        await runCheck();
        if (!connected) break;

        runAllStage = '${p.short} read card';
        notifyListeners();
        await readCard(openReport: false);
        if (readReportPath != null) productionDataReports.add(readReportPath!);
        if (!connected) break;

        runAllStage = '${p.short} card unit test';
        notifyListeners();
        await runTest();
        if (!connected) break;
      }
      if (connected) {
        runAllStage = 'Production checks';
        notifyListeners();
        await _work('Production checks', (s) async {
          s.end(); // these go straight to the reader, not through the phone rules
          productionRows.addAll(await ProductionChecks(s.channel, this, appletAid: appletAid).run());
        });
      }
    } finally {
      setPlatform(wanted);
      productionSeconds = watch.elapsedMicroseconds / 1e6;
      production = ProductionSummary(
        [for (final p in PhonePlatform.values) _outcomeFor(p)],
        List.of(productionRows),
        simulated: usingSimulator,
      );
      runAllStage = '';
      runAllRunning = false;
      page = Pages.runAll; // the verdict is here, whatever the last run looked at
      final s = production!;
      _phone(s.ready ? (s.warnings > 0 ? PhonePhase.warning : PhonePhase.success) : PhonePhase.failure,
          s.ready ? 'READY' : 'NOT READY', s.ready ? 'Every test ran' : '${s.failures} failed');
      notifyListeners();
    }
    productionReportPath = await saveProductionReport();
  }

  PlatformOutcome _outcomeFor(PhonePlatform p) {
    final r = resultsFor(p);
    return PlatformOutcome(
      platform: p,
      checkRows: List.of(r.checkRows),
      checkVerdict: r.verdict,
      checkYes: r.verdictYes,
      checkWarnings: r.verdictWarnings,
      read: r.readResult,
      testRows: List.of(r.testRows),
      testSummary: r.testSummary,
      cardSize: r.cardSize,
    );
  }

  /// Writes the one report that covers every run, and opens it.
  Future<String?> saveProductionReport({bool open = true}) async {
    final s = production;
    if (s == null) {
      snack('Run all the tests first.');
      return null;
    }
    final info = cardInfo;
    return _saveAndShow(
      'card_readiness',
      'html',
      buildProductionReport(ProductionReportInput(
        generatedAt: productionTime ?? DateTime.now(),
        summary: s,
        reader: connectedReader ?? selected ?? '-',
        aidList: aidController.text,
        appletAid: Hex.of(appletAid),
        atr: cardAtr == null ? null : Hex.of(cardAtr),
        cardType: info?.description,
        uid: cardUid == null ? null : Hex.of(cardUid),
        historical: info?.historical == null ? null : Hex.of(info!.historical),
        cardId: cardId == null ? null : Hex.of(cardId),
        seconds: productionSeconds,
        dataReports: List.of(productionDataReports),
        log: [for (final e in logEntries) '${stamp(e.time)}  ${e.text}'],
      )),
      bom: false,
      openFile: open,
      openFolder: false,
    );
  }

  // ------------------------------------------------------------------ page 0: the guide

  /// Writes the guide as a web page and opens it, so it can be read, printed or sent on without the app.
  Future<void> saveGuide() async {
    await _saveAndShow('guide', 'html', buildGuideHtml(), bom: false, openFile: true, openFolder: false);
  }

  // ------------------------------------------------------------------ page 5: card manager (the burner)

  /// The three boxes the keys are typed into. Only these three values are ever needed: nothing else of a card
  /// manager's setup comes from a file.
  final gpEncController = TextEditingController();
  final gpMacController = TextEditingController();
  final gpDekController = TextEditingController();

  /// The card's key set, built from the boxes. It is never written to a report, a log or an APDU dump.
  GpKeys? gpKeys;
  int gpKeyVersion = 0;
  String gpKeyFile = GpKeys.pyApduToolConfig;
  String gpKeySource = '';
  CardManager? gpManager;
  CardContents? gpContents;
  CapFile? gpCap;
  String gpCapPath = '';
  String? gpError;
  int gpLoadDone = 0;
  int gpLoadTotal = 0;

  bool get gpOpen => gpManager?.open ?? false;

  /// A card-manager channel lives only while the card stays powered and the card manager stays selected. A tap, a
  /// SELECT of an applet, or unplugging the reader ends it, and the card would then refuse the next command.
  void closeGpChannel(String why) {
    if (!gpOpen) return;
    gpManager!.close();
    info('The card manager channel closed: $why. Open it again before using the burner.');
  }

  /// Runs one card-manager job straight on the reader, outside the phone rules: no phone sends these commands.
  Future<bool> _gpWork(String title, Future<void> Function(CardManager gp) body) async {
    if (busy) return false;
    final ch = _channel;
    if (!connected || ch == null) {
      snack('Connect first: choose the reader at the top and click Connect.');
      return false;
    }
    final gp = gpManager ??= CardManager(ch, this);
    busy = true;
    busyTitle = title;
    gpError = null;
    lastError = null;
    notifyListeners();
    try {
      await body(gp);
      return true;
    } on CardException catch (e) {
      gpError = e is GpException ? e.toString() : e.message;
      warn('$title stopped: $gpError');
      snack(gpError!, error: true);
      if (e is! GpException && scardConnectionLost(e.code)) {
        gpManager = null;
        _markDisconnected();
      }
    } catch (e) {
      gpError = '$e';
      warn('$title stopped: $e');
      snack('$e', error: true);
    } finally {
      busy = false;
      busyTitle = '';
      notifyListeners();
    }
    return false;
  }

  /// Builds the key set from the three boxes. Each one has to be 16 bytes of hex; [gpKeys] stays null and [gpKeyProblem]
  /// says which box is wrong until all three are right.
  String? gpKeyProblem;

  void gpApplyKeys() {
    final problems = <String>[];
    Uint8List? read(String name, TextEditingController c) {
      final text = c.text.trim();
      if (text.isEmpty) {
        problems.add('$name is empty');
        return null;
      }
      try {
        final bytes = Hex.parse(text);
        if (bytes.length != 16) {
          problems.add('$name is ${bytes.length} bytes, not 16');
          return null;
        }
        return bytes;
      } on FormatException {
        problems.add('$name is not hex');
        return null;
      }
    }

    final enc = read('Key-ENC', gpEncController);
    final mac = read('Key-MAC', gpMacController);
    final dek = read('Key-DEK', gpDekController);
    if (enc == null || mac == null || dek == null) {
      gpKeys = null;
      gpKeyProblem = problems.join(' · ');
    } else {
      gpKeys = GpKeys(enc: enc, mac: mac, dek: dek, keyVersion: gpKeyVersion);
      gpKeyProblem = null;
    }
    notifyListeners();
  }

  void _gpFillKeys(GpKeys keys, String source) {
    gpEncController.text = Hex.of(keys.enc);
    gpMacController.text = Hex.of(keys.mac);
    gpDekController.text = Hex.of(keys.dek);
    gpKeyVersion = keys.keyVersion;
    gpKeySource = source;
    gpError = null;
    gpApplyKeys();
  }

  /// A path as typed or pasted. Explorer's "Copy as path" puts it in quotes.
  static String _cleanPath(String path) {
    final p = path.trim();
    return p.length >= 2 && p.startsWith('"') && p.endsWith('"') ? p.substring(1, p.length - 1).trim() : p;
  }

  /// Fills the boxes from a PyApduTool-style config.ini. Only the three keys are taken from it.
  Future<void> gpReadKeyFile([String? path]) async {
    final file = _cleanPath(path ?? gpKeyFile);
    try {
      final keys = await GpKeys.readConfig(file);
      gpKeyFile = file;
      _gpFillKeys(keys, file);
      info('Card manager keys read from $file (${keys.masked}). The key values stay in memory only.');
      snack('Keys read from $file.');
    } catch (e) {
      gpError = '$e';
      snack('$e', error: true);
      notifyListeners();
    }
  }

  /// Keeps the three keys in the tool's own file, so they do not have to be typed again.
  Future<void> gpSaveKeys() async {
    final keys = gpKeys;
    if (keys == null) {
      snack(gpKeyProblem ?? 'Type all three keys first.', error: true);
      return;
    }
    if (!writeFiles) return;
    try {
      final path = await GpKeys.writeOwnConfig(keys);
      gpKeySource = path;
      info('Card manager keys saved to $path. Keep that file private.');
      snack('Keys saved to $path.');
    } catch (e) {
      snack('Could not save the keys: $e', error: true);
    }
    notifyListeners();
  }

  /// Reads the tool's own key file at start-up, when there is one.
  Future<void> _gpLoadOwnKeys() async {
    if (!File(GpKeys.ownConfig).existsSync()) return;
    try {
      _gpFillKeys(await GpKeys.readConfig(GpKeys.ownConfig), GpKeys.ownConfig);
      info('Card manager keys read from ${GpKeys.ownConfig}.');
    } catch (_) {
      // a damaged key file should not stop the app from starting
    }
  }

  /// The "Default test key": the test card's keys from PyApduTool's config.ini, which the simulated card holds too, so
  /// one set opens both. With no config.ini on this PC it is the factory key 40 41 ... 4F.
  void gpUseTestKey() {
    final d = GpKeys.defaultTestKey();
    _gpFillKeys(
        d.keys,
        d.file == null
            ? 'the factory key 40 41 ... 4F (no PyApduTool config.ini was found)'
            : 'the default test key in ${d.file}');
  }

  void gpSetKeyVersion(int version) {
    gpKeyVersion = version;
    gpApplyKeys();
  }

  /// INITIALIZE UPDATE and EXTERNAL AUTHENTICATE. A wrong key set is refused by the card and counts against its try
  /// limit, so this is the one button that should not be clicked twice "to see".
  Future<void> gpAuthenticate() async {
    final keys = gpKeys;
    if (keys == null) {
      snack('Read the key file first.');
      return;
    }
    page = Pages.burner;
    gpContents = null;
    await _gpWork('Opening the secure channel', (gp) async {
      try {
        await gp.authenticate(keys);
      } on GpKeyException catch (e) {
        // the simulated card holds the default test key, and the boxes may hold another set saved earlier
        if (!gp.channel.isSimulated) rethrow;
        throw GpKeyException('${e.message} The simulated card holds the default test key: click "Default test key".',
            sw: e.sw);
      }
      gpContents = await gp.readCard();
      _phone(PhonePhase.success, 'Card manager open', 'SCP02, key version ${gp.initializeUpdate!.keyVersion}');
    });
    session?.end(); // the card manager is selected now, so a phone session would have to tap again
  }

  Future<void> gpReadCard() async {
    await _gpWork('Reading the card', (gp) async => gpContents = await gp.readCard());
  }

  /// DELETE. [withRelated] also removes the applets that came from a package, which deleting a package needs.
  Future<void> gpDelete(Uint8List aid, {bool withRelated = true}) async {
    final ok = await _gpWork('Deleting ${Hex.of(aid)}', (gp) async {
      await gp.delete(aid, withRelated: withRelated);
      gpContents = await gp.readCard();
    });
    if (ok) {
      snack('Deleted ${Hex.of(aid)}.');
      _cardChanged();
    }
  }

  /// SELECT by AID, the way a reader or a phone app picks an applet.
  Future<void> gpSelect(Uint8List aid) async {
    await _gpWork('SELECT ${Hex.of(aid)}', (gp) async {
      final r = await gp.selectAid(aid);
      if (r.sw == 0x9000) {
        snack('${Hex.of(aid)} answered 90 00: an app can select it.');
      } else {
        snack('${Hex.of(aid)} answered ${r.swText}: ${swMeaning(r.sw)}', error: true);
      }
      closeGpChannel('selecting an applet takes the card manager away');
    });
  }

  // ------------------------------------------------------------------ page 6: auto load (burning a tray of cards)

  /// The batch running now, or the last one that ran, so the screen keeps its list after it stops.
  BatchBurn? batch;

  /// The web page the last run wrote: how many cards were burned and the card ID of each.
  String? batchReportPath;

  bool get batchRunning => batch?.running ?? false;

  Future<void> openBatchReport() async {
    final path = batchReportPath;
    if (path == null) return;
    await Process.run('explorer.exe', [path]);
  }

  /// Burns the chosen CAP, with these settings, onto one card after another until it is stopped.
  ///
  /// Press once; after that the operator only swaps cards. It does not use [_gpWork], because that is for one job on
  /// one card: this one holds [busy] for the whole run and opens its own channel per card.
  Future<void> startAutoBurn({
    required Uint8List instanceAid,
    required Uint8List moduleAid,
    required bool defaultSelected,
    bool deleteFirst = true,
    bool force = false,
  }) async {
    if (busy || batchRunning) return;
    final keys = gpKeys;
    final cap = gpCap;
    final ch = _channel;
    if (keys == null) {
      snack(gpKeyProblem ?? 'Type the card\'s three keys first.', error: true);
      return;
    }
    if (cap == null) {
      snack('Choose a CAP file first.');
      return;
    }
    if (ch == null) {
      snack('Connect first: choose the reader at the top and click Connect.');
      return;
    }
    page = Pages.burner;
    gpError = null;
    batchReportPath = null;
    final startedAt = DateTime.now();
    closeGpChannel('the auto load opens its own channel for every card');
    final run = batch = BatchBurn(
      channel: ch,
      log: this,
      keys: keys,
      cap: cap,
      instanceAid: instanceAid,
      moduleAid: moduleAid,
      defaultSelected: defaultSelected,
      deleteFirst: deleteFirst,
      force: force,
      stopAfterFailures: 0, // the app's auto load runs until the user stops it, however many cards fail
      onChanged: _changed,
    );
    busy = true;
    busyTitle = 'Auto load';
    notifyListeners();
    try {
      await run.run();
    } finally {
      busy = false;
      busyTitle = '';
      // the cards on the reader changed many times over; nothing on the other screens describes what is there now
      gpManager = null;
      gpContents = null;
      if (run.ok > 0) useAppletAid(instanceAid);
      _cardChanged();
      notifyListeners();
    }
    // the run is over: write down what it did, so the cards can be checked afterwards
    if (run.done > 0) {
      batchReportPath = await _saveAndShow(
        'auto_load',
        'html',
        buildBatchReport(BatchReportInput(
          generatedAt: DateTime.now(),
          batch: run,
          reader: connectedReader ?? selected ?? '-',
          capName: cap.name,
          packageAid: Hex.of(cap.packageAid),
          instanceAid: Hex.of(instanceAid),
          defaultSelected: defaultSelected,
          deleteFirst: deleteFirst,
          force: force,
          startedAt: startedAt,
          simulated: usingSimulator,
        )),
        bom: false,
        openFile: true,
        openFolder: false,
      );
      notifyListeners();
    }
    snack(run.failed == 0
        ? 'Auto load finished: ${run.ok} card${run.ok == 1 ? '' : 's'} burned. The report is open in your browser.'
        : 'Auto load finished: ${run.ok} burned, ${run.failed} failed. See the report.');
  }

  void stopAutoBurn() {
    batch?.stop();
    notifyListeners();
  }

  /// Reads a CAP file so the screen can show what is in it before anything is sent to the card.
  Future<void> gpOpenCap(String path) async {
    final file = _cleanPath(path);
    try {
      gpCap = await CapFile.read(file);
      gpCapPath = file;
      gpError = null;
      info('CAP file ${gpCap!.name}: package ${Hex.of(gpCap!.packageAid)}, '
          '${gpCap!.appletAids.length} applet${gpCap!.appletAids.length == 1 ? '' : 's'}, ${gpCap!.componentBytes} bytes.');
    } catch (e) {
      gpCap = null;
      gpError = '$e';
      snack('$e', error: true);
    }
    notifyListeners();
  }

  /// INSTALL [for load], the LOAD blocks, then INSTALL [for install and make selectable].
  Future<void> gpLoadCap(
      {required Uint8List instanceAid,
      required Uint8List moduleAid,
      required bool defaultSelected,
      bool deleteFirst = true,
      bool force = false}) async {
    final cap = gpCap;
    if (cap == null) {
      snack('Choose a CAP file first.');
      return;
    }
    gpLoadDone = 0;
    gpLoadTotal = cap.loadBlocks().length;
    var touched = false; // the card changed, even if the load then stopped
    final ok = await _gpWork('Loading ${cap.name}', (gp) async {
      // A refusal halfway leaves the card worse off than before: the old package deleted, or the new one loaded with
      // no applet installed from it. So what the card would refuse is looked for first, before anything is sent.
      var contents = gpContents = await gp.readCard();
      if (force) {
        // delete whatever stands in the way first: the applet using the AID, the default-selected one, the package
        for (final (aid, withRelated) in contents.blockers(cap.packageAid, instanceAid: instanceAid, defaultSelected: defaultSelected)) {
          info('Force: deleting ${Hex.of(aid)}, which is in the way.');
          touched = true;
          try {
            await gp.delete(aid, withRelated: withRelated);
          } on GpException catch (e) {
            if (e.sw != 0x6A88) rethrow; // 6A 88 = already gone, which is fine
          }
        }
        contents = gpContents = await gp.readCard();
        final left = contents.loadProblem(cap.packageAid,
            instanceAid: instanceAid, defaultSelected: defaultSelected, deleteFirst: false);
        if (left != null) {
          throw GpException('Even after deleting what was in the way, the card still refuses: $left Nothing new was loaded.');
        }
      } else {
        final problem = contents.loadProblem(cap.packageAid,
            instanceAid: instanceAid, defaultSelected: defaultSelected, deleteFirst: deleteFirst);
        if (problem != null) throw GpException('$problem Nothing was sent to the card.');
        if (deleteFirst && contents.package(cap.packageAid) != null) {
          info('The package ${Hex.of(cap.packageAid)} is already on the card; deleting it first.');
          touched = true;
          await gp.delete(cap.packageAid);
          contents = gpContents = await gp.readCard();
          // only now is it certain which applets the delete took with it
          final left = contents.loadProblem(cap.packageAid,
              instanceAid: instanceAid, defaultSelected: defaultSelected, deleteFirst: false);
          if (left != null) {
            throw GpException('The old package ${Hex.of(cap.packageAid)} was deleted, but nothing new was loaded: $left');
          }
        }
      }
      touched = true;
      try {
        await gp.loadCap(
          cap,
          instanceAid: instanceAid,
          moduleAid: moduleAid,
          privileges: defaultSelected ? 0x04 : 0x00,
          onProgress: (done, total) {
            gpLoadDone = done;
            gpLoadTotal = total;
            _changed();
          },
        );
      } on GpException {
        // the card may now hold the package with no applet installed from it, so the list shows what is really there
        try {
          gpContents = await gp.readCard();
        } on CardException {
          // the refusal that stopped the load is the error to show
        }
        rethrow;
      }
      gpContents = await gp.readCard();
      _phone(PhonePhase.success, 'Loaded', '${cap.name} is on the card');
    });
    if (ok) {
      // the card now runs this applet, so every other screen should talk to it and not to the one burned before
      useAppletAid(instanceAid);
      snack('${cap.name} is loaded and installed as ${Hex.of(instanceAid)}. The AID box now points at it.');
      _cardChanged();
    } else if (touched) {
      _cardChanged();
    }
    notifyListeners();
  }

  /// The applet on the card is not the one the screens last talked to, so their results no longer describe it.
  void _cardChanged() {
    session?.end();
    cardId = null;
    for (final r in _results.values) {
      r
        ..checkRows.clear()
        ..verdict = ''
        ..verdictYes = null
        ..verdictWarnings = 0
        ..checkTime = null
        ..checkError = null
        ..testRows.clear()
        ..testSummary = ''
        ..testTime = null
        ..cardSize = null
        ..cardSizeStop = ''
        ..readResult = null
        ..readProgress = 0
        ..readReportPath = null
        ..writeResult = null;
    }
    undoable = null; // another applet, another file: the old bytes do not belong to it
    info('The card changed, so the earlier check, read, write and test results were cleared.');
  }

  // ------------------------------------------------------------------ HTML report

  ReportInput reportInput() {
    final info = cardInfo;
    return ReportInput(
      generatedAt: DateTime.now(),
      reader: connectedReader ?? selected ?? '-',
      platform: platform.short,
      aidList: aidController.text,
      atr: cardAtr == null ? null : Hex.of(cardAtr),
      cardType: info?.description,
      uid: cardUid == null ? null : Hex.of(cardUid),
      historical: info?.historical == null ? null : Hex.of(info!.historical),
      cardId: cardId == null ? null : Hex.of(cardId),
      checkPlatform: checkPlatform?.short,
      checkTime: checkTime,
      checkVerdict: verdict.isEmpty ? null : verdict,
      checkYes: verdictYes,
      checkRows: List.of(checkRows),
      testPlatform: testPlatform?.short,
      testTime: testTime,
      testSummary: testSummary.isEmpty ? null : testSummary,
      testRows: List.of(testRows),
      cardSize: cardSize,
      cardSizeStop: cardSizeStop,
      log: [for (final e in logEntries) '${stamp(e.time)}  ${e.text}'],
    );
  }

  /// Writes the HTML report to the Outputs_Files folder and opens it in the browser.
  Future<String?> saveHtmlReport({bool open = true}) async {
    if (checkRows.isEmpty && testRows.isEmpty) {
      snack('Run the phone check or the card unit test first.');
      return null;
    }
    return _saveAndShow('card_report', 'html', buildHtmlReport(reportInput()), bom: false, openFile: open, openFolder: false);
  }

  // ------------------------------------------------------------------ page 4: log

  Future<void> saveLog() async {
    final sb = StringBuffer();
    for (final e in logEntries) {
      sb.write('${stamp(e.time)}  ${e.text}\r\n');
    }
    await _saveAndShow('nfc_log', 'txt', sb.toString());
  }

  void clearLog() {
    logEntries.clear();
    notifyListeners();
  }

  /// The folder every report, dump, log and backup is written to: `Outputs_Files` beside the app.
  ///
  /// It is found from where the app is rather than written down, so the whole tool folder can be moved or checked out
  /// anywhere and the files still land next to it:
  /// - the built app runs from `SmartCrad_NFC_APP\App_file`, so its parent is `SmartCrad_NFC_APP`;
  /// - `flutter run` and the tests run from `SmartCrad_NFC_APP\src_file`, whose parent is the same folder.
  ///
  /// If that folder cannot be made (the app was copied somewhere read-only), it falls back to Documents, so a run
  /// never fails just because it could not save.
  static const outputFolderName = 'Outputs_Files';

  static Directory? _resolvedOutputDir;

  /// Where the files go. Worked out once, then kept.
  ///
  /// A folder that is already there is always used. One is only made where the tool folder really is, which is a
  /// folder holding `App_file` or `src_file`: without that check, a test runner or a copy unpacked into a temporary
  /// folder would leave an Outputs_Files behind wherever it happened to be.
  static Future<Directory> outputDir() async {
    final found = _resolvedOutputDir;
    if (found != null) return found;
    final places = [File(Platform.resolvedExecutable).parent.parent, Directory.current, Directory.current.parent];
    for (final check in [_outputsAlreadyThere, _looksLikeToolFolder]) {
      for (final place in places) {
        final dir = Directory('${place.path}\\$outputFolderName');
        if (!check(place, dir)) continue;
        try {
          await dir.create(recursive: true);
          return _resolvedOutputDir = dir;
        } catch (_) {
          // not somewhere we may write: try the next one
        }
      }
    }
    final home = Platform.environment['USERPROFILE'] ?? Directory.current.path;
    final fallback = Directory('$home\\Documents\\iPhone NFC Tester');
    await fallback.create(recursive: true);
    return _resolvedOutputDir = fallback;
  }

  static bool _outputsAlreadyThere(Directory place, Directory outputs) => outputs.existsSync();

  static bool _looksLikeToolFolder(Directory place, Directory outputs) =>
      Directory('${place.path}\\App_file').existsSync() || Directory('${place.path}\\src_file').existsSync();

  static String _fileName(String base, String extension) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${base}_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}.$extension';
  }

  /// Saves a generated firmware card as the hex-text (.txt) form the Elsewedy tools read, in Outputs_Files - .txt only,
  /// like the utility (no .bin). Returns the .txt path, or null when nothing was written.
  Future<String?> saveFirmwareCard(String base, Uint8List bytes) async {
    return _saveAndShow(base, 'txt', CardFile.toHexText(bytes), bom: false);
  }

  /// Saves a generated firmware card SET into Outputs_Files exactly like the Elsewedy utility: each card as hex text
  /// ONLY (.txt), named [base]_RFID_Card_1.txt, _2, ... - no .bin and no timestamp, so the files are a drop-in for the
  /// utility's. Returns the .txt paths. Opens the folder once at the end, so a set does not pop up N windows.
  Future<List<String>> saveFirmwareCardSet(String base, List<Uint8List> cards) async {
    final out = <String>[];
    if (!writeFiles) return out;
    final dir = await outputDir();
    for (var i = 0; i < cards.length; i++) {
      final file = File('${dir.path}\\${base}_RFID_Card_${i + 1}.txt');
      try {
        await file.writeAsString(CardFile.toHexText(cards[i]), flush: true);
        info('Saved ${file.path}');
        out.add(file.path);
      } catch (e) {
        snack('Could not save ${file.path}: $e', error: true);
      }
    }
    if (out.isNotEmpty) {
      snack('Saved ${out.length} card file${out.length == 1 ? '' : 's'} to ${dir.path}');
      await Process.run('explorer.exe', [dir.path]);
    }
    return out;
  }

  Future<String?> _saveAndShow(String base, String extension, String content,
      {bool bom = true, bool openFile = false, bool openFolder = true}) async {
    if (!writeFiles) return null;
    try {
      final dir = await outputDir();
      final file = File('${dir.path}\\${_fileName(base, extension)}');
      await file.writeAsString(bom ? '\uFEFF$content' : content, flush: true); // the BOM lets Excel read the CSV as UTF-8
      snack('Saved to ${file.path}');
      info('Saved ${file.path}');
      if (openFile) await Process.run('explorer.exe', [file.path]);
      if (openFolder) await Process.run('explorer.exe', [dir.path]);
      return file.path;
    } catch (e) {
      snack('Could not save the file: $e', error: true);
      return null;
    }
  }

  /// Saves [bytes] in the Outputs_Files folder. [quiet] is for a file the app keeps by itself, such as a backup:
  /// it goes to the log only, with no message and no Explorer window.
  Future<String?> _saveBytes(String base, String extension, List<int> bytes, {bool quiet = false}) async {
    if (!writeFiles) return null;
    try {
      final dir = await outputDir();
      final file = File('${dir.path}\\${_fileName(base, extension)}');
      await file.writeAsBytes(bytes, flush: true);
      info('Saved ${file.path}');
      if (quiet) return file.path;
      snack('Saved to ${file.path}');
      await Process.run('explorer.exe', [dir.path]);
      return file.path;
    } catch (e) {
      snack('Could not save the file: $e', error: true);
      return null;
    }
  }

  static String stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  }

  // ------------------------------------------------------------------ Logger

  @override
  void section(String text) => _log(LogKind.section, text);

  @override
  void info(String text) => _log(LogKind.info, text);

  @override
  void warn(String text) => _log(LogKind.warn, text);

  @override
  void exchange(String label, Uint8List sent, ResponseApdu response, double ms) {
    _log(LogKind.sent, '>> ${Hex.brief(sent, 24)}   [$label]');
    final data = response.data.isNotEmpty ? '${Hex.brief(response.data, 16)}  ' : '';
    _log(LogKind.received,
        '<< $data${response.swText}  ${explainAnswer(sent, response.sw, appletAid: appletAid).short}  (${ms.toStringAsFixed(1)} ms)',
        sw: response.sw);
    if (sent.length >= 2 && sent[0] == 0x80 && sent[1] == 0x08 && response.sw == 0x9000 && response.data.isNotEmpty) {
      cardId = response.data; // the applet's card ID
    }
    if (busy) results.phoneDetail = '$label  ->  ${response.swText}';
  }

  @override
  void blocked(String label, Uint8List typed, String reason) {
    _log(LogKind.sent, '>> ${Hex.brief(typed, 24)}   [$label]');
    _log(LogKind.blocked, 'NOT SENT: $reason');
    if (busy) results.phoneDetail = '$label  ->  not sent';
  }

  void _log(LogKind kind, String text, {int? sw}) {
    logEntries.add(LogEntry(kind, text, sw: sw));
    _changed();
  }

  // ------------------------------------------------------------------ helpers

  void snack(String text, {bool error = false}) {
    final m = messengerKey.currentState;
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      width: 640,
      showCloseIcon: true,
      backgroundColor: error ? const Color(0xFFB3261E) : null,
      duration: Duration(seconds: error ? 7 : 4),
    ));
  }

  /// Many small changes during a run become one screen update every 33 ms.
  void _changed() {
    if (_notifyQueued || _disposed) return;
    _notifyQueued = true;
    Future<void>.delayed(const Duration(milliseconds: 33), () {
      _notifyQueued = false;
      if (!_disposed) notifyListeners();
    });
  }

  void _tick() {
    final s = session;
    if (s == null || !s.active || _disposed) return;
    if (!busy && s.expired) {
      s.end(); // iOS ends the session; the reader stays connected and the next command taps again
      info('The iPhone session passed ${PhoneSession.iosLimitSeconds} s, so it ended, as on iOS. The next command taps again.');
      _phone(PhonePhase.idle, 'Session over', 'iOS ends a reader session after ${PhoneSession.iosLimitSeconds} s');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _channel?.dispose();
    commandController.dispose();
    aidController.dispose();
    gpEncController.dispose();
    gpMacController.dispose();
    gpDekController.dispose();
    themeMode.dispose();
    super.dispose();
  }
}

// The guide shown on the first page and saved as a web page. The text lives here once: the screen and the HTML file
// are both built from it, so they can never drift apart.
import 'pages.dart';
import 'platform.dart';

/// One part of the guide: what a screen is for, how to use it, and what is worth knowing about it.
class GuideSection {
  const GuideSection({
    required this.title,
    required this.icon,
    required this.intro,
    this.steps = const [],
    this.notes = const [],
    this.table = const [],
    this.tableHead,
    this.page,
  });

  /// The screen this part describes, so the heading opens it. Null for the parts that are not about one screen.
  final int? page;

  final String title;

  /// A name the screen turns into an icon; the web page uses it as a hint only.
  final String icon;
  final String intro;

  /// "How to use it", in order.
  final List<String> steps;

  /// Things worth knowing, in no order.
  final List<String> notes;

  /// An optional two-column table.
  final List<(String, String)> table;
  final (String, String)? tableHead;
}

const guideTitle = 'NFC Card Tester: what it does and how to use it';

const guideIntro =
    'This Windows app talks to your contactless card the way a phone app does, and it can load applets onto the card '
    'the way PyApduTool does. It is meant for one card: the electrical_electrometer ("EMG") applet on a Java Card. '
    'Read this page once and you will know every screen.';

/// One thing the app can do.
///
/// The home screen is built from these: every one with a [page] becomes a tile that opens that screen, which is how
/// you get around now that there is no side column. The ones without a page are things to know rather than places to
/// go, so they appear only in the guide web page.
class GuideFeature {
  const GuideFeature(this.name, this.icon, this.what, {this.page, this.platform});

  final String name;
  final String icon;
  final String what;
  final int? page;

  /// Set when the tile also chooses which phone's rules to follow, so "iPhone check" and "Android check" can lead to
  /// the same screen set up two different ways.
  final PhonePlatform? platform;

  bool get onHome => page != null;
}

/// Everything the app supports, at a glance, before any of the detail.
const guideFeatures = <GuideFeature>[
  GuideFeature('Run all tests', 'rocket',
      'One button: every test on both phones and the production checks, ending in a report that says READY or '
          'NOT READY. Start here if you only want one answer.',
      page: Pages.runAll),
  GuideFeature('iPhone (iOS) check', 'phone',
      'Would an iPhone app find this card and use the applet? It follows Apple Core NFC: the AID list, the blocked '
          'AIDs and the 60-second session.',
      page: Pages.check, platform: PhonePlatform.iphone),
  GuideFeature('Android check', 'android',
      'The same question under Android IsoDep: any ISO-DEP card is found with no AID list, nothing is blocked and '
          'there is no time limit.',
      page: Pages.check, platform: PhonePlatform.android),
  GuideFeature('APDU console', 'terminal',
      'Type one command in hex, send it under the chosen phone\'s rules, and see the status word, its meaning and the '
          'data explained.',
      page: Pages.console),
  GuideFeature('Read & write card', 'readwrite',
      'Read all 32 KB off the card with a web page of every byte, or write bytes, a .bin file or a fill into it, '
          'checked by reading back and with Undo.',
      page: Pages.read),
  GuideFeature('Read Company ID', 'badge',
      'Read the card\'s identity block - card ID, company, region and firmware/format version - the way the Elsewedy '
          'utility\'s "Read Company ID" does, in one fast read of the first 64 bytes instead of the whole 32 KB.',
      page: Pages.companyId),
  GuideFeature('Applet log', 'applog',
      'Read the applet\'s own built-in command log - every APDU the card received, including from a phone. Arm it, run '
          'the phone, then read it back; it lives in the card so it survives the phone↔PC move. Needs the logger applet build.',
      page: Pages.appletLog),
  GuideFeature('Card profiles', 'simcard',
      'Make the tool work with cards other than the EMG one. A profile holds a card\'s AID(s), how to select its file, '
          'how big it is, and the READ/UPDATE commands. EMG is the default; the one you pick here is what Read, Write '
          'and Block editor talk to.',
      page: Pages.profiles),
  GuideFeature('Make firmware card', 'bootloader',
      'Give a meter firmware .bin and make the set of cards that flash it. The SOGWAVE 1-phase recipe is built in, so '
          'it needs no template and no AES key; the output matches the Elsewedy utility byte-for-byte.',
      page: Pages.bootloader),
  GuideFeature('Card Unit Test', 'tasks',
      'The card unit test (29 checks + 14 extra checks) and the card size: 47 results, with the bytes it touches saved '
          'and written back.',
      page: Pages.test),
  GuideFeature('Burner (card manager)', 'fire',
      'Load a CAP file onto the card, and read, select or delete the packages and applets on it, over a GlobalPlatform '
          'SCP02 secure channel.',
      page: Pages.burner),
  GuideFeature('Error map', 'rule',
      'Every answer the applet can give, the check inside it that sends that answer, what to do about it, and what the '
          'old applet answered instead.',
      page: Pages.errorMap),
  GuideFeature('Log', 'list', 'Every command and answer with its timing, searchable and saveable.', page: Pages.log),
  GuideFeature('Phone rules', 'gavel',
      'Exactly which iPhone and Android rules the app applies, with a link to the Apple or Android page each one '
          'comes from.',
      page: Pages.rules),
  GuideFeature('Reports you can keep', 'report',
      'Each run is saved as a web page, and the test results also as a CSV, in the Outputs_Files folder beside the app.'),
  GuideFeature('Works with no reader', 'chip',
      'Pick "Simulated card" and every screen works, including the burner: your applet\'s logic runs in software.'),
];

const guideSections = <GuideSection>[
  GuideSection(
    title: 'What it can and cannot tell you',
    icon: 'info',
    intro: 'The app follows the written rules of iOS Core NFC and Android IsoDep, and sends real commands to your card '
        'through a PC reader. That answers most questions without a phone, a Mac or a developer account.',
    notes: [
      'It CAN tell you: whether a phone app would find the card, whether the applet answers every command correctly, '
          'what is stored on the card, and what is loaded on it.',
      'It CANNOT tell you: how well the phone\'s antenna reaches the card, how fast the phone\'s NFC chip is, or how a '
          'particular iOS or Android version behaves. A real phone app is still the final proof.',
      'A PC reader is not a phone. Where the two differ, the app says so rather than hiding it.',
    ],
  ),
  GuideSection(
    title: 'Before you start',
    icon: 'play',
    intro: 'Three things, every time.',
    steps: [
      'Put the card on the contactless reader.',
      'If PyApduTool (or any other card tool) is open, click Disconnect there. A reader can only be held by one '
          'program at a time.',
      'Start the app and click Connect, the green button at the top left. The reader is chosen for you; the bar then '
          'shows the card\'s ATR.',
      'When you are done, click Disconnect so other programs can use the reader again.',
    ],
    notes: [
      'No reader? Choose "Simulated card" in the list. It runs your applet\'s logic in software, so every screen works '
          'without hardware.',
      'Until you click Connect, the buttons that talk to the card stay switched off.',
    ],
  ),
  GuideSection(
    title: 'iPhone or Android',
    icon: 'phone',
    intro: 'The switch at the top right decides which phone\'s rules the app follows. It changes what is allowed, not '
        'just the wording.',
    table: [
      ('iPhone (Core NFC)', 'Finds the card only by the AIDs in the app\'s list, in order. The app may only SELECT '
          'those AIDs; payment AIDs are always blocked. A session ends after 60 seconds. Needs a paid Apple Developer '
          'account on a real iPhone.'),
      ('Android (IsoDep)', 'Finds any ISO-DEP card with no AID list. Sends whatever bytes you give it. No session '
          'limit. Any app with the NFC permission works, so no developer account is needed.'),
    ],
    tableHead: ('Phone', 'What it does'),
    notes: [
      'Each phone keeps its own results. Switching to Android never shows you the iPhone\'s results, and switching '
          'back brings the iPhone\'s results again.',
      'The AID box at the top right decides which applet every screen selects: the first AID in it. On an iPhone the '
          'whole list is what an app would put in its Info.plist, tried in order.',
      'Burning an applet puts its AID in that box by itself, so the check, the console, the read and the full test '
          'all follow the applet that is really on the card.',
    ],
  ),
  GuideSection(
    title: 'Page 1 - Check',
    page: Pages.check,
    icon: 'check',
    intro: 'One click answers the question: would a phone app find this card and use the applet?',
    steps: [
      'Click "Check this card like an iPhone" (or Android).',
      'Read the verdict banner: YES, YES with warnings, or NO.',
      'The steps underneath show exactly what the phone did and what the card answered.',
    ],
    notes: [
      'It is read-only: nothing on the card is changed.',
      'For your card the iPhone answer is YES with one warning, because the AID starts with 4 rather than A, D or F. '
          'Apple has no written rule against it, but one developer saw iOS refuse such an AID.',
    ],
  ),
  GuideSection(
    title: 'Page 2 - APDU console',
    page: Pages.console,
    icon: 'terminal',
    intro: 'Type one command in hex and send it the way the chosen phone would send it.',
    steps: [
      'Type the command, for example 00 A4 00 00 02 30 40. Spaces are optional.',
      'Under the box the app explains what you typed: the class, instruction, offset, how many bytes it asks for.',
      'Press Enter or click Send. The answer shows the status word, what it means, and the data.',
    ],
    notes: [
      'The quick buttons fill the box with common commands. None of them writes to the card.',
      'Up and Down in the box bring back earlier commands.',
      'Under each answer the app names the exact check inside the applet that produced it, from the error map.',
      'On iPhone rules, a command the phone would refuse is shown as BLOCKED and never reaches the card.',
    ],
  ),
  GuideSection(
    title: 'Page 3 - Read and write card',
    page: Pages.read,
    icon: 'readwrite',
    intro: 'Reads the whole file off the card and shows it, byte for byte, or writes bytes into it. The switch at '
        'the top of the page chooses Read card or Write card.',
    steps: [
      'The switch at the top of the page has three modes: Read card, Write card, and Block editor.',
      'These three modes talk to whichever card is chosen on the Card profiles page (a tile on Home). EMG is the '
          'default, so nothing changes for the EMG card.',
      'Read card: click "Read whole card" and watch the block map fill in, 128 blocks of 256 bytes. When it finishes, '
          'the data report opens in your browser by itself.',
      'Write card: choose what to write on the left: hex bytes at an offset, a .bin file, or a fill (one byte over a '
          'range). The bytes panel shows them before anything is sent.',
      'Block editor: type a start offset (in hex, 0000-7FFF) and how many 16-byte blocks to read, click "Read blocks", '
          'edit any byte in the grid, then "Write changes" sends only the blocks you changed back to the card. The '
          'offset is lined up to a 16-byte block, so 7FF0 reads the last block (7FF0-7FFF). The parameters the card '
          'carries (card ID, company, versions) show above when offset 0 is in the range.',
      'Click "Write to card" and confirm. The page then shows every byte as changed, already the same, or wrong on '
          'read-back.',
      'Changed your mind? "Undo last write" puts back what was there.',
    ],
    notes: [
      'Read card is OK only at exactly 32768 bytes. Fewer or more is an exception, and the page tells you which parts '
          'could not be read and why.',
      'It always shows the data it managed to read first, and the problem second. A bad block does not stop the rest.',
      'Bytes that could not be read appear as a red -- both on the page and in the report.',
      '"Save .bin" writes a 32768-byte file where the position in the file is the offset on the card. Write card can '
          'put such a file back.',
      '"Save .txt" writes the same bytes as one line of hex, the form the Elsewedy Smart Card Utility reads and '
          'writes, so a card read here opens there. Write card reads both kinds, so a *_RFID_Card_*.txt made by those '
          'tools can be written from here.',
      'After a read, "What the card says about itself" shows the meter card\'s own first 64 bytes: the card ID, the '
          'company, the region and the versions. A card without that block (a fresh applet, a card of 00) simply does '
          'not show the row.',
      'Choosing a firmware or bootloader card file in Write card says what it is before you write it: its version, '
          'how many frames it holds and which part of the whole firmware they are.',
      'Before Write card changes anything, it reads what is there and saves it as card_backup_<range>.bin. Undo only '
          'goes to the card the write was made on, so it cannot spoil another card.',
      'A write is only OK when reading it back gives exactly the bytes that were written.',
      'This tool is not only for the EMG card. On the Card profiles page (a Home tile) you pick or add a profile — a '
          'card\'s AID(s), how to select its file, how big it is, and the READ and UPDATE commands — and Read, Write '
          'and Block editor follow it. Offsets then run 0000 to the profile\'s last byte, not always 7FFF. The console '
          'and the Burner work with any card and do not use the profile.',
    ],
  ),
  GuideSection(
    title: 'Page 4 - Card Unit Test',
    page: Pages.test,
    icon: 'tasks',
    intro: 'The card unit test (29 checks + 14 extra checks), and the card size: 47 results in all.',
    steps: [
      'Click "Run Card Unit Test" and confirm.',
      'Tap 1 runs the checks and the card size; then the saved bytes are written back; then tap 2 checks what '
          'survives a power cycle.',
      'Use the filters (All, Not PASS, Card checks, Extra) to find what you care about.',
      '"HTML report" saves everything as a web page; "Save CSV" gives you a spreadsheet.',
    ],
    notes: [
      'It writes to the card, but only inside 0000-003F, 0100-01FE and 7FC0-7FFF. Those areas are saved first and '
          'written back at the end. If they cannot be saved, nothing is written at all.',
      'Every check runs, even after a failure, so a card that answers wrongly still shows all its answers.',
      'The TYPE column names the applet check behind each answer, or marks it as an answer only the OLD applet gives.',
      'Card size passes only at 32768 bytes.',
    ],
  ),
  GuideSection(
    title: 'Page 5 - Run all tests',
    page: Pages.runAll,
    icon: 'rocket',
    intro: 'One button that does everything else on this list and ends with a single answer: is this card ready?',
    steps: [
      'Click "Run all tests" and confirm.',
      'Watch the stages: the check, the card read and the card unit test as an iPhone, then the same as an Android, '
          'then the production checks.',
      'Read the verdict at the top, and the report that opens in your browser.',
    ],
    notes: [
      'The read-only runs come first on each phone and the card unit test last, so a card that is already wrong is '
          'found before anything is written to it.',
      'The production checks are the ones no other screen makes: that the card picks the applet by itself after a '
          'power-up, that the card ID is usable and stays the same over five power-ups, that an app can select the '
          'applet by its AID, and that the whole data file is addressable.',
      'The verdict is NOT READY if anything failed, READY with warnings if only warnings, READY if nothing at all.',
      'Running it on the simulated card says so next to the verdict: a READY from the simulator says nothing about '
          'your hardware.',
    ],
  ),
  GuideSection(
    title: 'Page 6 - Burner',
    page: Pages.burner,
    icon: 'fire',
    intro: 'The card manager: load an applet onto the card, and read, select or delete what is already there. This is '
        'the only page that changes which code is on the card.',
    steps: [
      'Type the card\'s three keys in the boxes, click "Default test key" for the keys in PyApduTool\'s config.ini, or '
          'click "From a config.ini" to take them out of another one. Click "Save keys" and the app will remember them '
          'next time.',
      'Click "Open channel". The card proves it has the same keys and then lists everything on it.',
      'To load an applet: choose the .cap file, check the package AID and the instance AID it shows, then click '
          '"Load and install" and confirm. The instance AID box is what the applet will answer to, so change it there '
          'if you want a different one; the AID box at the top then points at it.',
      'The arrow button next to an applet selects it the way an app would. The bin button deletes a package or an '
          'applet.',
      'To burn a whole tray: set the CAP and the settings once, then click "Auto load" instead of "Load and install". '
          'From there you only swap cards.',
    ],
    notes: [
      'If a card was burned before, its applet may already use that AID, or another applet holds "Default selected", '
          'and the install is refused. Tick "Force" (under the settings) and the tool deletes that applet — and any '
          'default-selected one — first, then installs the new one; their data is lost. Auto load follows the Force tick too.',
      'Only three keys are ever needed. Nothing else about the card manager comes from a file.',
      'The keys never go to the card and are never written to a report, a log or the APDU list: only cryptograms '
          'travel. The boxes stay hidden until you click the eye.',
      'A wrong key set is caught before the card is asked to accept it, so it does not count against the card\'s '
          'limit on failed attempts.',
      'Only ONE applet on a card can be "Default selected", the one the card picks after every power-up. If another '
          'applet already holds it, the app tells you which one before sending anything.',
      'Whatever else the card would refuse (the package already there, an AID already taken) is also said before '
          'anything is sent, so a load never stops halfway with the old package gone.',
      '"Default test key" takes the test card\'s keys from PyApduTool\'s config.ini. The simulated card holds the same '
          'keys, so they open both. A burn on the simulated card gives a new card ID and an empty file, as on the real '
          'card.',
      '"Auto load" burns the same CAP, with the same settings, onto one card after another. Press it once and '
          'confirm; after that put a card on, wait for "OK finished for 1", take it off and put the next one on. The '
          'panel counts them and names every card.',
      'Auto load needs the three keys and a CAP, but not an open channel: it opens one for every card by itself. It '
          'keeps going until you press "Stop auto load" — it does not stop by itself, even if some cards fail. The card '
          'being burned is always finished first.',
      'A card has to leave the reader before the next one counts, so the same card is never burned twice.',
      'At the end of the run a report opens by itself: how many cards were burned and three numbers for every card, '
          'with the IDs again on their own so they can be pasted into a list. "Open report" brings it back.',
      'Which number names a card? The **chip ID** is burned in when the card is made and never changes, even after '
          'the card is burned again: that is the one to keep. The **card ID** (GET UID 80 08) is made afresh by every '
          'install, so it names the installation. The **reader UID** is random at every tap on this card, so it names '
          'only the tap.',
      'Deleting a package also deletes the applets made from it, and their stored data. There is no undo.',
      'Running a check, a read or the full test taps the card, and a tap resets it. That closes the card manager '
          'channel, so open it again before using the burner.',
    ],
  ),
  GuideSection(
    title: 'Page 7 - Log',
    page: Pages.log,
    icon: 'list',
    intro: 'Every command and answer, with the time it took.',
    notes: [
      'You do not have to come here to watch a test. The **live log** along the bottom of every page shows the same '
          'lines as they happen, and it opens by itself whenever a run starts.',
      'Press the strip, or the arrow at its right, to keep it open or to put it away. Closed, it still shows the last '
          'line.',
      'A line starting >> is what was sent and << is what the card answered, in green when the answer was 90 00 and '
          'red when it was not. The name in brackets is the check that sent it.',
      'Search and filter the full log here, and save it as a text file.',
      'Keys never appear in it, on purpose.',
    ],
  ),
  GuideSection(
    title: 'Page 8 - Rules',
    page: Pages.rules,
    icon: 'gavel',
    intro: 'Exactly which iPhone and Android rules the app applies, and a link to the Apple or Android page each rule '
        'comes from.',
    notes: ['Read it if you want to check the app\'s homework, or to quote a rule to someone else.'],
  ),
  GuideSection(
    title: 'Page 9 - Error map',
    page: Pages.errorMap,
    icon: 'rule',
    intro: 'Every answer your applet can give, the check inside it that produces that answer, what the meter should do '
        'about it, and what the OLD applet answered instead.',
    notes: [
      'The arrow next to an example puts that command in the APDU console.',
      'This is the same map the app uses to label answers everywhere else.',
    ],
  ),
  GuideSection(
    title: 'Page 10 - Card profiles',
    page: Pages.profiles,
    icon: 'simcard',
    intro: 'Which card the Read, Write and Block-editor screens talk to. The tool was built for the EMG electrometer '
        'applet, but a card profile moves everything card-specific here, so the same screens work with another card.',
    steps: [
      'Pick a profile in the list on the left to make it the card the three screens use. EMG is the default.',
      'Click "New profile" to add one, or "Duplicate" a built-in to start from it.',
      'Fill in the fields on the right: a name, the applet AID(s), the SELECT-file APDU (empty if selecting the applet '
          'already opens the file), the card-ID APDU (empty if the card has none), the file size, and the READ/UPDATE '
          'class and instruction. "Save" keeps it and makes it the active card.',
    ],
    notes: [
      'A profile covers a card that keeps its data in one transparent binary file, read and written by offset, like '
          'EMG. MIFARE sector cards and record files are a different shape and are not covered.',
      'The built-in profiles (EMG electrometer, Plain binary file) cannot be changed or deleted — duplicate one to '
          'make your own.',
      'Your profiles are saved in %APPDATA%\\NFC Card Tester\\card_profiles.json and come back next time.',
      'The console and the Burner work with any card and do not use the profile.',
    ],
  ),
  GuideSection(
    title: 'Page 11 - Make firmware card',
    page: Pages.bootloader,
    icon: 'bootloader',
    intro: 'Turns a meter firmware image into the set of RFID cards that write it to the meter. It never touches a '
        'reader; it makes the .txt (and .bin) files you then write to the card with the Burner or the Elsewedy utility.',
    steps: [
      'Choose the meter firmware image (.bin) — the finished image your build produces. A 5-character version is filled '
          'in from the file name; check it matches the build.',
      'Click Make. The tool knows the SOGWAVE 1-phase recipe (the auth blocks 0x40 and 0xD0), so it splits the firmware '
          'into cards of 117 frames and writes them — no template needed.',
      'The card files land in Outputs_Files (hex text + .bin), named _RFID_Card_1, _2, ... Write them to the card in '
          'order to flash the meter.',
    ],
    notes: [
      'Each card carries the product\'s auth blocks — 0x40 (one value for the family) and 0xD0 (one per card frame-count) '
          '— copied from real cards, plus fresh frames and CRCs. No AES key is needed; the output is byte-for-byte what '
          'the Elsewedy utility makes.',
      'For a firmware the built-in recipe does not cover (another product, or a size whose last card has a frame-count '
          'with no stored 0xD0), give a TEMPLATE set in step 2: pick one card of an existing set for that product and '
          'its headers are copied.',
      'The firmware must be the finished meter image: a whole number of 256-byte pages carrying its own length and CRC '
          'tail in the last page.',
      'Tested against a real EM120 set: the cards built from the firmware match the utility\'s files byte-for-byte.',
    ],
  ),
  GuideSection(
    title: 'Files the app writes',
    icon: 'folder',
    intro: 'Everything is saved in the Outputs_Files folder next to the app and opens by itself. The app finds that '
        'folder from where it runs, so moving or checking out the tool folder keeps the files with it.',
    table: [
      ('card_report_*.html', 'The check and card unit test results, with the card and the setup.'),
      ('card_data_*.html', 'A read of the card: every block as hex and text, with a map and the parts not read.'),
      ('card_data_*.bin / .txt', 'The bytes of a read, as a 32 KB file or as one line of hex for the Smart Card Utility.'),
      ('card_backup_*.bin', 'What a write replaced, saved before it was written, so it can be put back.'),
      ('auto_load_*.html', 'One Auto load run: how many cards were burned, and the chip ID and card ID of each.'),
      ('card_test_*.csv', 'The test results as a spreadsheet.'),
      ('nfc_log_*.txt', 'The APDU log.'),
      ('guide.html', 'This guide, saved from the first page.'),
    ],
    tableHead: ('File', 'What it holds'),
    notes: [
      'The card manager keys and your card profiles are kept separately in %APPDATA%\\NFC Card Tester and never in these files.',
      'If the app is somewhere it may not write, it falls back to Documents\\iPhone NFC Tester rather than losing the '
          'file. The message after every save names the full path.',
    ],
  ),
  GuideSection(
    title: 'If something goes wrong',
    icon: 'help',
    intro: 'The usual causes, in the order worth checking.',
    table: [
      ('Connect fails, "in use"', 'Another program holds the reader. Click Disconnect in PyApduTool and try again.'),
      ('The phone does not find the card', 'On iPhone rules, one AID in the list must answer 90 00. Check the AID '
          'list box, and that the applet is installed and selected by default.'),
      ('Everything answers 6D 00', 'The card is running a different applet than you think. Open the Burner and look '
          'at what is actually installed.'),
      ('The burner says 69 85 on install, or "an applet with that AID is already on the card"',
          'A card burned before. Tick "Force" to delete that applet (and any default-selected one) and install the new '
          'one, or delete it by hand first, or untick "Default selected".'),
      ('Commands stop halfway', 'The card was taken off the reader, or the iPhone\'s 60 seconds ran out. Tap again.'),
    ],
    tableHead: ('What you see', 'What it usually means'),
  ),
];

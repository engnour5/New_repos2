import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';

class RulesPage extends StatelessWidget {
  const RulesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(children: [
      const _RuleCard(
        icon: Icons.nfc_rounded,
        color: nfcColor,
        title: 'iPhone 1. Finding the card (a tap)',
        points: [
          'The RF field goes off and on, so the card powers up as when it touches the iPhone.',
          "iOS sends SELECT by AID for each AID in the app's Info.plist list "
              '(com.apple.developer.nfc.readersession.iso7816.select-identifiers), in the listed order.',
          'The first AID that answers 90 00 becomes initialSelectedAID, and the app gets the card.',
          'If no AID answers 90 00, the app never gets the card as an ISO 7816 tag.',
          'The tool sends this SELECT as 00 A4 04 00 Lc AID 00. Apple does not document the exact bytes.',
        ],
      ),
      const _RuleCard(
        icon: Icons.send_rounded,
        color: seed,
        title: 'iPhone 2. Commands the app sends',
        points: [
          'A SELECT by AID (INS A4, P1 04) is checked against the same list. Any other AID is refused with '
              'NFCReaderErrorSecurityViolation and never reaches the card.',
          'Payment AIDs (Visa, Mastercard, PPSE ...) are always refused. Apple does not publish the list; '
              'the tool uses the well-known payment RIDs.',
          'The APDU must be valid for NFCISO7816APDU: Lc 1 to 65535 bytes, Le 1 to 65536. iOS rebuilds the bytes from '
              'CLA, INS, P1, P2, data and Le (the short form when it fits).',
          'iOS does not answer 61 xx with GET RESPONSE and does not repeat a command after 6C xx. The app must do it.',
          'CLA FF commands (FF CA = UID) belong to PC readers. An iPhone app reads the UID from tag.identifier.',
        ],
      ),
      const _RuleCard(
        icon: Icons.timer_outlined,
        color: warnColor,
        title: 'iPhone 3. Time and account',
        points: [
          'iOS ends a reader session after 60 seconds. The work must fit in one tap, or the user taps again.',
          'An iPhone app can read NFC cards only when it is signed by a paid Apple Developer Program account.',
        ],
      ),
      const _RuleCard(
        icon: Icons.sim_card_alert_outlined,
        color: warnColor,
        title: 'iPhone: your AID',
        points: [
          '45 4D 47 30 30 30 30 30 30 30 starts with 4. Registered AIDs start with A or D, proprietary ones with F.',
          'Apple has no written rule against other first digits, but one developer reported that iOS would not select '
              'the AID 01 02 03 04 05 06.',
          'If a real iPhone does not find your card, an AID that starts with F is the first thing to try.',
        ],
      ),
      const _RuleCard(
        icon: Icons.smartphone_rounded,
        color: okColor,
        title: 'Android (IsoDep)',
        points: [
          'Android finds any ISO-DEP card without an AID: the app gets an IsoDep object for it.',
          'By default the Android NFC service first checks the card for NDEF data: it selects the NDEF application '
              '(00 A4 04 00 07 D2 76 00 00 85 01 01 00). Reader-mode apps can skip this with FLAG_READER_SKIP_NDEF_CHECK. '
              'Your applet answers 6A 86 and nothing changes.',
          'IsoDep.transceive() sends the bytes exactly as given. Android checks no SELECT and blocks no AID.',
          'Android does not send GET RESPONSE after 61 xx or repeat a command after 6C xx, like iOS.',
          'There is no session limit; each command has a timeout (IsoDep.setTimeout). Many phones send at most '
              '261 bytes per command (IsoDep.getMaxTransceiveLength); longer commands need extended-length support.',
          'The UID comes from Tag.getId(). Your card gives a random UID at every tap, so an app must use GET UID (80 08).',
          'Any app with the NFC permission works, and an APK can be installed directly: no developer account is needed.',
        ],
      ),
      const _RuleCard(
        icon: Icons.do_not_disturb_on_outlined,
        color: failColor,
        title: 'What a PC cannot check',
        points: [
          "The phone's antenna and radio (distance, field strength) and the timing of its NFC chip.",
          'Changes and bugs in iOS and Android versions. The final proof is a real phone app.',
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const PanelHeader(icon: Icons.menu_book_rounded, title: 'Sources'),
            const SizedBox(height: 8),
            const _Source(
              text: 'Apple Core NFC header NFCISO7816Tag.h: the SELECT check, the AID list and the APDU limits',
              url: 'https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS13.0.sdk/System/Library/Frameworks/CoreNFC.framework/Headers/NFCISO7816Tag.h',
            ),
            const _Source(
              text: 'Apple forum 122314: payment AIDs and the card manager A000000003000000 are blocked',
              url: 'https://developer.apple.com/forums/thread/122314',
            ),
            const _Source(
              text: 'Apple forum 710200: a custom AID 01 02 03 04 05 06 that iOS would not select',
              url: 'https://developer.apple.com/forums/thread/710200',
            ),
            const _Source(
              text: 'Apple forum 715536: the AID check may behave differently between iOS versions',
              url: 'https://developer.apple.com/forums/thread/715536',
            ),
            const _Source(
              text: 'Apple, Supported capabilities (iOS): NFC Tag Reading needs a paid Apple Developer Program membership',
              url: 'https://developer.apple.com/help/account/reference/supported-capabilities-ios',
            ),
            const _Source(
              text: 'Android IsoDep: transceive, getMaxTransceiveLength, setTimeout, getHistoricalBytes',
              url: 'https://developer.android.com/reference/android/nfc/tech/IsoDep',
            ),
            const _Source(
              text: 'Android NfcAdapter reader mode: FLAG_READER_SKIP_NDEF_CHECK',
              url: 'https://developer.android.com/reference/android/nfc/NfcAdapter#FLAG_READER_SKIP_NDEF_CHECK',
            ),
            const SizedBox(height: 10),
            Text(
                'Command line: iphone_nfc_tester.exe [--sim] [--android] [--connect] '
                '[--run-check | --run-read | --run-test | --run-console] [--page 1..7] [--report] [--light]',
                style: mono(size: 12, color: subtleText(context))),
          ]),
        ),
      ),
    ]);
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({required this.icon, required this.color, required this.title, required this.points});

  final IconData icon;
  final Color color;
  final String title;
  final List<String> points;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Panel(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              for (final p in points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(p, style: const TextStyle(fontSize: 13.5, height: 1.45))),
                  ]),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Source extends StatelessWidget {
  const _Source({required this.text, required this.url});

  final String text;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => openLink(url),
        icon: const Icon(Icons.open_in_new_rounded, size: 16),
        label: Text(text, textAlign: TextAlign.left),
      ),
    );
  }
}

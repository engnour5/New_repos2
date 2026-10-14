import 'hex.dart';

/// Status word meanings: ISO 7816-4, with the EMG applet's cases from the error map.
String swMeaning(int sw) {
  final sw1 = sw >> 8, sw2 = sw & 0xFF;
  switch (sw) {
    case 0x9000:
      return 'Success';
    case 0x6986:
      return 'Command not allowed: no file selected (send SELECT 3040 first)';
    case 0x6700:
      return 'Wrong length (Lc, Le or data)';
    case 0x6B00:
      return 'Wrong P1-P2: the offset is past 7FFF';
    case 0x6A82:
      return 'File not found (only 3F00 and 3040 exist)';
    case 0x6A86:
      return 'Incorrect P1-P2';
    case 0x6E00:
      return 'Class (CLA) not supported';
    case 0x6D00:
      return 'Instruction (INS) not supported';
    case 0x6F00:
      return 'No precise diagnosis (unexpected error in the applet)';
    case 0x6A80:
      return 'Incorrect data';
    case 0x6A81:
      return 'Function not supported';
    case 0x6A88:
      return 'Referenced data not found';
    case 0x6982:
      return 'Security status not satisfied';
    case 0x6983:
      return 'Authentication method blocked';
    case 0x6985:
      return 'Conditions of use not satisfied';
    case 0x6999:
      return 'Applet selection failed';
    case 0x6283:
      return 'Selected file or applet is invalidated (locked)';
  }
  if (sw1 == 0x6C) {
    return 'Wrong Le: ${sw2 == 0 ? 256 : sw2} bytes are available, send it again with Le = ${h2(sw2)} (iOS does not do this for you)';
  }
  if (sw1 == 0x61) {
    return '${sw2 == 0 ? 256 : sw2} more bytes: send GET RESPONSE 00 C0 00 00 ${h2(sw2)} (iOS does not do this for you)';
  }
  if (sw1 == 0x63 && (sw2 & 0xF0) == 0xC0) return 'Verification failed, ${sw2 & 0x0F} tries left';
  if (sw1 == 0x62 || sw1 == 0x63) return 'Warning';
  if (sw1 == 0x64 || sw1 == 0x65) return 'Execution error';
  return 'Unknown status word';
}

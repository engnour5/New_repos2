import 'dart:typed_data';

import 'hex.dart';

/// How a card file keeps its bytes.
enum CardFileFormat {
  /// One long line of hex digits, the way the Elsewedy Smart Card Utility writes read.txt and reads write.txt.
  /// Its own files are continuous uppercase hex with no separators and no line ends.
  hexText,

  /// The bytes themselves, as "Save .bin" writes them.
  binary,
}

extension CardFileFormatName on CardFileFormat {
  String get label => this == CardFileFormat.hexText ? 'hex text' : 'binary';
}

/// A card file read from the disk: its bytes, and how the file kept them.
///
/// The other tools around this card (the Smart Card Utility, and the *_RFID_Card_*.txt files the meter people pass
/// around) keep card data as hex text, while this app writes .bin. Both are read here, so a file from either side can
/// be written to the card, and [toHexText] writes a file those tools can read back.
class CardFile {
  CardFile(this.data, this.format);

  final Uint8List data;
  final CardFileFormat format;

  int get length => data.length;

  /// Reads a file whichever way it keeps its bytes. Hex text is taken when the whole file is hex digits and
  /// separators, which is what a card file looks like; anything else is used as it is.
  ///
  /// Throws [FormatException] when the file looks like hex text but cannot be one (an odd number of digits).
  static CardFile parse(Uint8List bytes, {String name = ''}) {
    if (bytes.isEmpty) throw const FormatException('The file is empty.');
    var digits = 0;
    for (final b in bytes) {
      if (_isHexDigit(b)) {
        digits++;
      } else if (!_isSeparator(b)) {
        return CardFile(bytes, CardFileFormat.binary); // a byte that cannot be in a hex file: it is one
      }
    }
    if (digits == 0) return CardFile(bytes, CardFileFormat.binary);
    if (digits.isOdd) {
      throw FormatException('$name holds $digits hex digits, an odd number, so the last byte is incomplete.');
    }
    return CardFile(Hex.parse(String.fromCharCodes(bytes)), CardFileFormat.hexText);
  }

  /// The bytes as one line of uppercase hex with nothing between them: the form the Smart Card Utility writes and
  /// reads, so a file written here opens there.
  static String toHexText(Uint8List data) => Hex.compact(data);

  /// The firmware frames this file carries, or null when it is not a firmware card.
  CardFrames? get frames => CardFrames.parse(data);

  static bool _isHexDigit(int b) =>
      (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66);

  /// What may sit between the digits of a hex file: spaces, tabs, line ends, commas, colons and dashes.
  static bool _isSeparator(int b) =>
      b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A || b == 0x2C || b == 0x3A || b == 0x2D;
}

/// One frame of a firmware card: a piece of the firmware with its place in the whole.
class CardFrame {
  CardFrame({required this.start, required this.header, required this.payload, this.check});

  /// Where the frame's header starts in the card image.
  final int start;

  /// The frame's 15 header bytes, exactly as the card carries them.
  ///
  /// They are kept raw, not rebuilt from the fields, because the two bytes after the version are not always 00 00
  /// (the Spain 3PH cards carry 00 40) and the version field is padded differently from one product to the next. The
  /// CRC covers whatever is really there, so only the real bytes will do.
  final Uint8List header;

  /// This frame's place in the firmware, counted across every card of the set.
  int get seq => header[4] | (header[5] << 8);

  /// How many frames the whole firmware takes, over all the cards together.
  int get total => header[6] | (header[7] << 8);

  /// The 5 bytes that name the version, as the card carries them.
  Uint8List get versionBytes => Hex.sub(header, 8, 5);

  /// The version to show, e.g. "2.433" for an application or "v.101" for a bootloader.
  String get version => String.fromCharCodes(versionBytes.where((c) => c >= 0x20 && c < 0x7F)).trim();

  /// The payload the frame carries: 256 firmware bytes, then one inner CRC over them. The meter's
  /// `rfid_bootloader_check` reads the firmware from `&ptr_buf[11]` (256 bytes) and the inner CRC from the byte after
  /// it, which is `calc_crc(&ptr_buf[11], 256)`.
  final Uint8List payload;

  /// The 256 firmware bytes (the last frame of a set carries the whole-image CRC, type and length in its tail).
  Uint8List get firmware => Hex.sub(payload, 0, payload.length < 256 ? payload.length : 256);

  /// The inner CRC the card carries for the firmware bytes, or null when the payload is short.
  int? get innerCheck => payload.length > 256 ? payload[256] : null;

  /// The inner CRC those 256 firmware bytes should have: `calc_crc(firmware, 256)`.
  int get wantedInner => CardFrames.calcCrc(firmware);

  /// The byte that follows the frame's "!" terminator: the frame CRC, `calc_crc(&buf[1], 275)`.
  final int? check;

  /// The frame CRC this frame should carry, over the frame from the length field through the terminator (the meter
  /// skips the leading STX). Mathematically the same as a CRC started at 0x02 over the whole frame and terminator.
  int get wantedCheck =>
      CardFrames.calcCrc(Hex.sub(Hex.concat([header, payload, CardFrames.terminator]), 1, headerLength));

  int get headerLength => header.length + payload.length + CardFrames.terminator.length - 1;

  /// True when both the frame CRC and the inner firmware CRC are right. Null when the file ended before the check byte.
  bool? get checkOk => check == null ? null : (check == wantedCheck && (innerCheck == null || innerCheck == wantedInner));
}

/// A firmware or bootloader card, as the Elsewedy tools write it.
///
/// The frames were read off 75 real card files in the Vango tree (5133 full frames, every one the same shape):
///
///     <file header, 256 bytes>            two 16-byte blocks at 0x40 and 0xD0, the rest 00
///     then, repeated:
///       02 0C 01 00 <seq16> <total16> <version 5 bytes> 00 00 <payload 257>   21 0D 0A 03 <check>
///
/// `0C 01` is 268 = the 11 header bytes after it plus the 257 payload bytes. The payload is the firmware itself: put
/// the payloads together in [seq] order, across every card of the set, and the first bytes are the ARM vector table.
class CardFrames {
  CardFrames(this.frames, this.headerBytes, this.data);

  /// `! CR LF ETX`, which closes every frame.
  static final terminator = Hex.parse('21 0D 0A 03');

  /// The marker a frame header starts with: type 02, then the length 010C and a 00.
  static final headerMark = Hex.parse('02 0C 01 00');

  static const headerFields = 15; // 02 + len16 + 00 + seq16 + total16 + version5 + 00 00
  static const payloadBytes = 257;

  final List<CardFrame> frames;

  /// The bytes before the first frame. 256 on nearly every file.
  final int headerBytes;

  /// The whole card file these frames were read from. It is kept so the card can be rebuilt byte-for-byte: a rebuild
  /// rewrites only the firmware bytes and the CRCs, and leaves the header (with its auth blocks at 0x40 and 0xD0) and
  /// any trailing padding exactly as they were.
  final Uint8List data;

  /// Reads the frames of a firmware card, or null when the bytes are not one.
  ///
  /// Each frame's own length field says where it ends, which matters: firmware bytes can happen to spell the
  /// terminator, so looking for `21 0D 0A 03` alone would cut a frame in half and stop the reading early. The
  /// terminator is only used to find the way back when a frame does not add up.
  static CardFrames? parse(Uint8List data) {
    final out = <CardFrame>[];
    var start = _find(data, headerMark, 0);
    if (start < 0) return null;
    final headerBytes = start;
    while (start >= 0 && start + headerFields < data.length) {
      final length = data[start + 1] | (data[start + 2] << 8);
      final payload = length - (headerFields - 4); // the length counts from the seq field to the end of the payload
      final end = start + headerFields + payload; // where the terminator should be
      final framed = payload > 0 && end + 3 < data.length && _same(data, end, terminator);
      if (framed) {
        out.add(CardFrame(
          start: start,
          header: Hex.sub(data, start, headerFields),
          payload: Hex.sub(data, start + headerFields, payload),
          check: end + 4 < data.length ? data[end + 4] : null,
        ));
        start = _find(data, headerMark, end + 4);
      } else {
        // this one does not add up: take the next frame header after the next terminator, if there is one
        final next = _find(data, terminator, start + headerFields);
        start = next < 0 ? -1 : _find(data, headerMark, next + 4);
      }
    }
    return out.isEmpty ? null : CardFrames(out, headerBytes, data);
  }

  static bool _same(Uint8List data, int at, Uint8List what) {
    if (at + what.length > data.length) return false;
    for (var i = 0; i < what.length; i++) {
      if (data[at + i] != what[i]) return false;
    }
    return true;
  }

  static int _find(Uint8List data, Uint8List what, int from) {
    for (var i = from; i + what.length <= data.length; i++) {
      var ok = true;
      for (var j = 0; j < what.length && ok; j++) {
        ok = data[i + j] == what[j];
      }
      if (ok) return i;
    }
    return -1;
  }

  /// The meter's `calc_crc`: CRC-8, polynomial 0x31, starting at 0x00, no final flip. Confirmed against the meter
  /// firmware (`rfid_sys.c`), which uses it for both the inner firmware CRC and the frame CRC, and against the card
  /// files: of the 5146 frames in the 75 real files of the Vango tree, 5145 carry exactly these, and every genuine
  /// card reproduces byte-for-byte. The one exception is `435-delta.txt`, a working file whose frames are damaged
  /// (one names its version "40240", the next "000000"), so the file is wrong, not the rule.
  static const crcPolynomial = 0x31;

  static int calcCrc(Uint8List data) {
    var crc = 0x00;
    for (final byte in data) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = crc & 0x80 != 0 ? ((crc << 1) ^ crcPolynomial) & 0xFF : (crc << 1) & 0xFF;
      }
    }
    return crc;
  }

  /// The chained whole-image CRC the meter checks on the last frame (`cal_crc_image`): page by page, the previous
  /// page's result is appended to the 256 firmware bytes as a 257th byte and the CRC is taken over all 257; the first
  /// page starts from 0. The last frame carries this value, the file type and the file length in its tail.
  static int imageCrc(List<Uint8List> firmwarePages, {int? lastPageLength}) {
    var prev = 0;
    for (var i = 0; i < firmwarePages.length; i++) {
      final page = firmwarePages[i];
      final len = i == firmwarePages.length - 1 && lastPageLength != null ? lastPageLength : page.length;
      prev = calcCrc(Hex.concat([Hex.sub(page, 0, len), [prev]]));
    }
    return prev;
  }

  /// The frames whose CRC is not the one they should carry: a damaged or hand-edited file.
  List<CardFrame> get damaged => frames.where((f) => f.checkOk == false).toList();

  bool get allChecksPass => damaged.isEmpty;

  int get total => frames.first.total;
  String get version => frames.first.version;
  int get firstSeq => frames.map((f) => f.seq).reduce((a, b) => a < b ? a : b);
  int get lastSeq => frames.map((f) => f.seq).reduce((a, b) => a > b ? a : b);

  /// The firmware bytes on this card, in order: 256 per frame, without the inner CRC byte.
  Uint8List get firmware => Hex.concat([for (final f in frames) f.firmware]);

  /// True when this one card holds the whole firmware; otherwise it is one of a set.
  bool get complete => frames.length == total && firstSeq == 0 && lastSeq == total - 1;

  // --- the file tail the final frame carries, which the meter checks, and rebuilding the card ---

  /// The index of the frame that carries the whole-image CRC/type/length (the one whose seq is the last of the set),
  /// or null when this card does not hold it.
  int? _metaFrameIndex() {
    for (var i = 0; i < frames.length; i++) {
      if (frames[i].seq == total - 1) return i;
    }
    return null;
  }

  int? get _metaIdx => complete ? _metaFrameIndex() : null;

  /// True when this card holds the whole firmware and so carries the file CRC/type/length the meter checks.
  bool get hasFileMeta => _metaIdx != null;

  /// 0 = a full firmware, 1 = a delta, 2 = a bootloader; null when this card does not carry the tail.
  int? get fileType => _metaIdx == null ? null : frames[_metaIdx!].firmware[251];

  /// What [fileType] means, for the screen.
  String get fileTypeText => switch (fileType) { 0 => 'full firmware', 1 => 'delta', 2 => 'bootloader', _ => 'unknown' };

  /// The firmware length the tail records, in bytes; null when this card does not carry the tail.
  int? get fileLengthBytes => _metaIdx == null ? null : _u32(frames[_metaIdx!].firmware, 252);

  /// The whole-image CRC the tail records; null when this card does not carry the tail.
  int? get fileCrc => _metaIdx == null ? null : frames[_metaIdx!].firmware[250];

  static int _u32(Uint8List b, int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

  /// The card file rebuilt from its frames, with every CRC recomputed.
  ///
  /// With [firmware] null it reproduces the file byte-for-byte. With [firmware] given (exactly the same length as
  /// [this.firmware]) it writes that firmware in instead, recomputing each frame's inner CRC and frame CRC and, on a
  /// complete card, the whole-image file CRC in the final frame's tail. The header (with its auth blocks at 0x40 and
  /// 0xD0) and any trailing padding are copied over untouched, so only the firmware and the CRCs change. Firmware of a
  /// different length, or a card that is only one of a set, is refused, so a card can only be made the meter accepts.
  Uint8List rebuildWith({Uint8List? firmware}) {
    final current = this.firmware;
    final fw = firmware ?? current;
    if (firmware != null && fw.length != current.length) {
      throw ArgumentError('The new firmware is ${fw.length} bytes, but this card holds ${current.length}. Replacing the '
          'firmware keeps the card the same size, so give firmware of exactly ${current.length} bytes.');
    }
    if (firmware != null && !complete) {
      throw ArgumentError('This card is only one of a set (frames $firstSeq-$lastSeq of $total). New firmware can be '
          'written only onto a card that holds the whole firmware.');
    }
    for (final f in frames) {
      if (f.payload.length != payloadBytes || f.firmware.length != 256) {
        throw StateError('This card has an unusual frame shape (payload ${f.payload.length} bytes), so it is not '
            'rebuilt, to be safe.');
      }
    }

    final out = Uint8List.fromList(data);
    final pages = [for (var i = 0; i < frames.length; i++) Uint8List.fromList(Hex.sub(fw, i * 256, 256))];

    // the final frame carries the whole-image CRC, the file type and the file length in its firmware tail
    final metaIdx = _metaFrameIndex();
    if (metaIdx != null && complete) {
      final meta = pages[metaIdx];
      final type = frames[metaIdx].firmware[251];
      final len = _u32(frames[metaIdx].firmware, 252);
      meta[251] = type;
      meta[252] = len & 0xFF;
      meta[253] = (len >> 8) & 0xFF;
      meta[254] = (len >> 16) & 0xFF;
      meta[255] = (len >> 24) & 0xFF;
      meta[250] = imageCrc(pages, lastPageLength: len % 256 == 0 ? 256 : len % 256);
    }

    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      final ps = f.start + headerFields; // payload start
      out.setRange(ps, ps + 256, pages[i]); // the 256 firmware bytes
      out[ps + 256] = calcCrc(pages[i]); // inner CRC over them
      final checkOff = ps + f.payload.length + terminator.length; // the byte right after the terminator
      if (checkOff < out.length) {
        out[checkOff] = calcCrc(Hex.sub(out, f.start + 1, checkOff - f.start - 1)); // frame CRC, the STX skipped
      }
    }
    return out;
  }

  /// Rebuilds a whole firmware card SET from its template cards, optionally with new [firmware].
  ///
  /// The meter firmware is one image split across several cards (the real tool writes ~117 frames a card). Given the
  /// template set — the cards the utility already made for this product, which carry the right header and auth blocks
  /// (0x40 constant, 0xD0 per frame-count) — this writes the firmware into them: it splits the firmware across the
  /// cards exactly as the template does, recomputes every CRC and the whole-image file CRC, and copies each card's
  /// header and padding untouched. With [firmware] null it reproduces the set byte-for-byte; with [firmware] given it
  /// must be the finished meter image (a whole number of 256-byte pages equal to the set's frame count, carrying its
  /// own file length/type tail in the last page, the way the build produces it). Returns one byte image per template
  /// card, in frame order. Firmware that does not fit the set's frame count is refused, so only a card the meter
  /// accepts can be made.
  static List<Uint8List> rebuildSet(List<CardFrames> template, {Uint8List? firmware}) {
    if (template.isEmpty) throw ArgumentError('No template cards were given.');
    final cards = [...template]..sort((a, b) => a.firstSeq.compareTo(b.firstSeq));
    final total = cards.first.total;
    var next = 0;
    for (final c in cards) {
      if (c.total != total) {
        throw ArgumentError('The template cards are from different sets (one says $total frames in all, another ${c.total}).');
      }
      if (c.firstSeq != next) {
        throw ArgumentError('The template set is not in order or has a gap: expected the next card to start at frame '
            '$next, but one starts at ${c.firstSeq}.');
      }
      next = c.lastSeq + 1;
      for (final f in c.frames) {
        if (f.payload.length != payloadBytes || f.firmware.length != 256) {
          throw StateError('A template card has an unusual frame shape (payload ${f.payload.length} bytes), so the set '
              'is not rebuilt, to be safe.');
        }
      }
    }
    if (next != total) {
      throw ArgumentError('The template set covers $next of $total frames; some cards of the set are missing.');
    }

    final fw = firmware ?? Hex.concat([for (final c in cards) for (final f in c.frames) f.firmware]);
    if (fw.length != total * 256) {
      throw ArgumentError('The firmware is ${fw.length} bytes, but this set holds $total frames = ${total * 256} bytes '
          '($total pages of 256). Give the finished meter image for a set this size.');
    }
    final pages = [for (var i = 0; i < total; i++) Hex.sub(fw, i * 256, 256)];
    final fileType = pages[total - 1][251];
    final fileLen = _u32(pages[total - 1], 252);
    if (fileLen <= (total - 1) * 256 || fileLen > total * 256) {
      throw ArgumentError('This firmware does not carry a valid file-length tail (it reads $fileLen for a $total-page '
          'image). The set builder needs the finished firmware image your build produces, not a raw dump.');
    }
    final fileCrc = imageCrc(pages, lastPageLength: fileLen % 256 == 0 ? 256 : fileLen % 256);

    final out = <Uint8List>[];
    for (final c in cards) {
      final bytes = Uint8List.fromList(c.data);
      for (final f in c.frames) {
        final page = Uint8List.fromList(Hex.sub(fw, f.seq * 256, 256));
        if (f.seq == total - 1) {
          page[250] = fileCrc;
          page[251] = fileType;
          page[252] = fileLen & 0xFF;
          page[253] = (fileLen >> 8) & 0xFF;
          page[254] = (fileLen >> 16) & 0xFF;
          page[255] = (fileLen >> 24) & 0xFF;
        }
        final ps = f.start + headerFields;
        bytes.setRange(ps, ps + 256, page);
        bytes[ps + 256] = calcCrc(page);
        final checkOff = ps + f.payload.length + terminator.length;
        if (checkOff < bytes.length) {
          bytes[checkOff] = calcCrc(Hex.sub(bytes, f.start + 1, checkOff - f.start - 1));
        }
      }
      out.add(bytes);
    }
    return out;
  }

  /// Builds a firmware card set from the firmware ALONE, using a known product recipe [p] for the header (its auth
  /// blocks 0x40 and 0xD0) and the 5-character [version] for the frames — no template file needed.
  ///
  /// It splits the firmware into cards of [FirmwareProduct.framesPerCard] frames (the last card the remainder), writes
  /// each card's header (0x40 for the product, and 0xD0 for that card's frame count when the recipe has it) and its
  /// frames with the inner and frame CRCs, and pads each card to [FirmwareProduct.padMultiple]. The firmware is the
  /// finished meter image (a whole number of 256-byte pages, carrying its own length/CRC tail in the last page).
  ///
  /// Works for ANY firmware size. 0xD0 is the card's reserved block (RFID_RESERVED_BLOCK_1 in the meter's rfid_sys.c):
  /// the meter never reads it while flashing - it validates the frames, the inner firmware CRC and the frame CRC, and
  /// the 0x40 auth block only. So a card is accepted whatever 0xD0 holds. When the recipe knows the utility's value for
  /// a card's frame count, it is written (the file is then byte-identical to the utility); for a frame count not in the
  /// recipe, 0xD0 is left zero, which the meter flashes just the same. Throws only when the firmware is not whole pages
  /// or the version is not 5 characters.
  static List<Uint8List> buildSet(Uint8List firmware, FirmwareProduct p, String version) {
    if (firmware.isEmpty || firmware.length % 256 != 0) {
      throw ArgumentError('The firmware must be a whole number of 256-byte pages; this is ${firmware.length} bytes.');
    }
    final vb = version.codeUnits;
    if (vb.length != 5) {
      throw ArgumentError('The version must be 5 characters, like "4.526"; "$version" is ${vb.length}.');
    }
    final total = firmware.length ~/ 256;
    final counts = <int>[];
    for (var left = total; left > 0;) {
      final c = left >= p.framesPerCard ? p.framesPerCard : left;
      counts.add(c);
      left -= c;
    }
    final a40 = Hex.parse(p.auth40);
    final out = <Uint8List>[];
    var seq = 0;
    for (final count in counts) {
      final header = Uint8List(p.headerBytes);
      header.setRange(0x40, 0x50, a40);
      // 0xD0 is the card's reserved block; the meter ignores it when flashing. Write the utility's known per-count
      // value when the recipe has it (so the file is byte-identical to the utility), otherwise leave it zero.
      final d0 = p.d0ByCount[count];
      if (d0 != null) header.setRange(0xD0, 0xE0, Hex.parse(d0));
      final b = <int>[...header];
      for (var k = 0; k < count; k++, seq++) {
        final page = Hex.sub(firmware, seq * 256, 256);
        final frame = <int>[
          0x02, 0x0C, 0x01, 0x00, seq & 0xFF, (seq >> 8) & 0xFF, total & 0xFF, (total >> 8) & 0xFF,
          ...vb, ...p.versionTrailer, ...page, calcCrc(page), ...terminator,
        ];
        frame.add(calcCrc(Hex.sub(Uint8List.fromList(frame), 1, 275)));
        b.addAll(frame);
      }
      while (b.length % p.padMultiple != 0) {
        b.add(0);
      }
      out.add(Uint8List.fromList(b));
    }
    return out;
  }

  /// One line for the screen: what the file is, and whether its frames are intact.
  String get summary => 'Firmware card: version $version, ${frames.length} frame${frames.length == 1 ? '' : 's'} '
      '($firstSeq-$lastSeq of $total), ${firmware.length} bytes of firmware'
      '${complete ? ', the whole firmware' : ', one card of a set'}. '
      '${allChecksPass ? 'Every frame passes its CRC.' : '${damaged.length} frame${damaged.length == 1 ? '' : 's'} '
          'fail their CRC (${damaged.take(4).map((f) => f.seq).join(', ')}): the file is damaged.'}';

  /// Learns the utility's 0xD0 block for each card frame-count by reading its own reference card files, so a recipe can
  /// match the utility byte-for-byte for any size the utility has already made - with no hand-entered value. The 0xD0
  /// block is generated inside the utility and cannot be computed here, so the only sure source for a given size is a
  /// real card of that size; this reads it straight off one. Only cards whose 0x40 auth block equals [auth40] (the same
  /// product family) are learned, and a zero 0xD0 (an unfilled card) is ignored. Returns {frameCount: 0xD0 hex}.
  static Map<int, String> learnD0(Iterable<Uint8List> referenceCards, {required String auth40}) {
    final out = <int, String>{};
    final want = auth40.toUpperCase();
    const zero = '00000000000000000000000000000000';
    for (final data in referenceCards) {
      if (data.length < 0xE0) continue;
      if (Hex.compact(Hex.sub(data, 0x40, 16)).toUpperCase() != want) continue;
      final fr = parse(data);
      if (fr == null) continue;
      final d0 = Hex.compact(Hex.sub(data, 0xD0, 16)).toUpperCase();
      if (d0 != zero) out[fr.frames.length] = d0;
    }
    return out;
  }
}

/// A known product's header recipe, so its firmware cards can be built from a firmware image alone, with no template
/// file. [auth40] (the 0x40 block) is the card's auth block, one value for the product family, which the meter reads to
/// know the card is a bootloader card. [d0ByCount] gives the utility's 0xD0 block per card frame-count - but 0xD0 is the
/// card's reserved block (RFID_RESERVED_BLOCK_1), which the meter does NOT read while flashing, so it only makes the
/// file byte-identical to the utility and is not needed for a working card. Both were read off real cards; the frame
/// payloads, the version and all CRCs are made fresh. A recipe can build firmware of ANY size: a card whose frame-count
/// is not in [d0ByCount] simply gets a zero 0xD0, which the meter flashes the same.
class FirmwareProduct {
  const FirmwareProduct({
    required this.name,
    required this.auth40,
    required this.d0ByCount,
    this.framesPerCard = 117,
    this.headerBytes = 256,
    this.padMultiple = 255,
    this.versionTrailer = const [0, 0],
    this.defaultVersionPrefix = '',
    this.versionPrefixes = const {},
  });

  final String name;

  /// The 0x40 block (16 bytes of hex), constant across the product family.
  final String auth40;

  /// The 0xD0 block (16 bytes of hex) for a card of this many frames.
  final Map<int, String> d0ByCount;

  /// How many frames a full card holds; the last card holds the remainder.
  final int framesPerCard;
  final int headerBytes;

  /// Each card file is zero-padded to a multiple of this many bytes.
  final int padMultiple;

  /// The two header bytes after the 5 version bytes (00 00 for the single-phase boards).
  final List<int> versionTrailer;

  /// What a version string usually starts with for this product (e.g. "4." for EM120 AMER), so one can be offered from
  /// the firmware's file name.
  final String defaultVersionPrefix;

  /// The version prefix per product, by a keyword in the firmware's file name (e.g. "GPRS" -> "b.", "4G" -> "g." for the
  /// EM122 4G GPRS AMER board). Checked in order, first keyword that appears in the name wins, so the more specific
  /// keyword goes first (4G before GPRS, since that board's name also contains GPRS). The card version is prefix + the
  /// number in the file name; it is only the offered default - the version field shows it and must be confirmed, since
  /// the prefix cannot always be told from the name.
  final Map<String, String> versionPrefixes;

  /// The frame-counts the recipe can make a card for, smallest first.
  List<int> get knownCounts => d0ByCount.keys.toList()..sort();

  /// A copy of this recipe with [extra] 0xD0 blocks merged in - the ones learned from the utility's reference cards by
  /// [CardFrames.learnD0]. A learned value wins over the built-in one for the same frame-count (it is read straight off
  /// the utility's own card), so the output matches whatever the utility actually made, with no hand-entered value.
  FirmwareProduct withExtraD0(Map<int, String> extra) => FirmwareProduct(
        name: name,
        auth40: auth40,
        d0ByCount: {...d0ByCount, ...extra},
        framesPerCard: framesPerCard,
        headerBytes: headerBytes,
        padMultiple: padMultiple,
        versionTrailer: versionTrailer,
        defaultVersionPrefix: defaultVersionPrefix,
        versionPrefixes: versionPrefixes,
      );

  /// The SOGWAVE single-phase board family (EM120 AMER and the newer Egypt / Spain / GPRS / bootloader 1PH boards all
  /// share this 0x40 auth block and the same 0xD0-by-frame-count values). The 0xD0 values below are the utility's and
  /// were read off the real 1PH card sets in the Vango archive (confirmed: within this family each frame-count maps to
  /// exactly one 0xD0, firmware- and position-independent); they make the output byte-identical to the utility but are
  /// not required by the meter (0xD0 is a reserved block it does not read). A full card is 117 frames; the rest are
  /// remainder-card counts seen in the archive. A count not listed here (e.g. 54) still builds, with a zero 0xD0.
  static const sogwave1Ph = FirmwareProduct(
    name: 'SOGWAVE 1-phase (EM120 / GPRS / newer boards)',
    auth40: '66E94BD4EF8A2C3B884CFA59CA342B2E',
    defaultVersionPrefix: '4.',
    versionPrefixes: {'EM120': '4.', '4G': 'g.', 'GPRS': 'b.', 'SPAIN': 's.', 'EGYPT': '2.', 'BOOTLOADER': 'v.'},
    d0ByCount: {
      1: 'F0353F064D784FB7ECAD342635F2EA3F',
      10: 'EF2601B7952A7EA0DEF61EB819BDDD82',
      12: '520DC8CDBF982818412C81A40BFA879C',
      13: 'E67E6AEB269E65D8CCEFA470C2335D47',
      14: 'A3D2FCE95484E51226F7BA822452250B',
      15: 'B88D302F224F65B9F996C930CD016E42',
      17: '6F2B43E8E21A93D3E02536B1C6ACA591',
      20: '4810CD6497E5CF58505D7DA25EA62BC0',
      23: '1137A193DA35107364C0600B4151EFA4',
      25: '013EF981E5D6C1A7C05B1ADA2AD471A7',
      27: 'B8788D5FE269A7F3AD75F1742FAB9F85',
      28: '50D6BE9845763A57DD34E1F504A4E15F',
      29: '1A2E52AA93EBA7D551E8697CD8F7EAA7',
      30: '204A8D8C0C4703600581D57C075A63C3',
      33: '4936073C9A1EBE9A297681028D3ECA40',
      36: 'B7B1142FD64C3FC7D967F30A56DE35AC',
      39: '913CE51ED1662B72ED1A8159944D4864',
      41: '0B11F9C816300EFCAFC75CF5AF6958CC',
      52: 'B73CBDF6D488482CD879244FBE9B1D87',
      56: 'A0EC74F0648052C70D51FE57C764E4AE',
      61: 'DBF058CA4F49258B599ED6859EABAAAA',
      90: 'F1E8CBC15F706557FBF64EB1968054E9',
      112: 'C76C900A77C0D4BF5F9A1A4A0C5903D6',
      117: '3958A175EE55AB950C268A5F19C44E95',
    },
  );

  static const all = [sogwave1Ph];
}

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/errors.dart';
import 'card_channel.dart';

// Windows PC/SC (winscard.dll). All calls run in one worker isolate, so a slow card never freezes the window.

const _scopeSystem = 2;
const _shareExclusive = 1; // no other program or Windows probe can step in during a session
const _protocolT0T1 = 3;
const _leaveCard = 0;
const _unpowerCard = 2;
const _attrAtrString = 0x00090303;

String describeScard(int code, String call) {
  final rc = code & 0xFFFFFFFF;
  final text = switch (rc) {
    0x8010000B => 'The reader is in use by another program. If PyApduTool is open, click Disconnect there, then try again.',
    0x8010000C => 'There is no card on the reader. Put the card on the reader and try again.',
    0x80100069 => 'There is no card on the reader, or it was removed. Put the card on the reader and try again.',
    0x80100066 => 'The card does not answer. Place it flat on the reader and try again.',
    0x80100067 => 'The card is not powered. Try again.',
    0x80100068 => 'Another program reset the card. Try again.',
    0x8010002E => 'No smart card reader was found. Plug in the reader and refresh the list.',
    0x80100009 => 'Windows does not know this reader (unplugged?). Refresh the reader list.',
    0x80100017 => 'The reader is not available (unplugged?). Refresh the reader list.',
    0x8010001D => 'The Windows smart card service is not running.',
    0x8010001E => 'The Windows smart card service stopped.',
    0x80100016 => 'The command did not reach the card (did it move?). Try again.',
    0x8010000F => 'The card and the reader use different protocols.',
    0x80100008 => 'The answer does not fit in the buffer.',
    0x8010000A => 'The reader timed out.',
    0x80100003 => 'The connection to the card was lost. Try again.',
    _ => 'Smart card error.',
  };
  return '$text ($call 0x${rc.toRadixString(16).padLeft(8, '0').toUpperCase()})';
}

bool _cardGone(int code) {
  final rc = code & 0xFFFFFFFF;
  return rc == 0x80100069 || rc == 0x80100068 || rc == 0x80100067 || rc == 0x80100003 || rc == 0x80100017;
}

/// True for errors after which there is no usable connection: the user must click Connect again.
bool scardConnectionLost(int code) {
  final rc = code & 0xFFFFFFFF;
  return _cardGone(code) ||
      rc == 0x8010000B || // in use by another program
      rc == 0x8010000C || // no card
      rc == 0x80100066 || // card does not answer
      rc == 0x80100009 || // unknown reader
      rc == 0x8010002E || // no readers
      rc == 0x8010001D || // service not running
      rc == 0x8010001E; // service stopped
}

/// A card on a PC/SC reader.
class PcscChannel implements CardChannel {
  PcscChannel(this.name);

  @override
  final String name;

  Uint8List? _atr;

  @override
  bool get isSimulated => false;

  @override
  Uint8List? get atr => _atr;

  static Future<List<String>> listReaders() async {
    final worker = await _PcscWorker.instance();
    final r = await worker.call('list', const {});
    if (r['ok'] != true) return const [];
    return (r['readers'] as List).cast<String>();
  }

  Future<Map<Object?, Object?>> _call(String op, [Map<String, Object?> extra = const {}]) async {
    final worker = await _PcscWorker.instance();
    final r = await worker.call(op, {'reader': name, ...extra});
    if (r['ok'] != true) {
      final message = r['message'] as String?;
      throw CardException(message ?? describeScard(r['code'] as int, r['call'] as String), r['code'] as int? ?? 0);
    }
    final atr = r['atr'];
    if (atr is Uint8List) _atr = atr;
    return r;
  }

  @override
  Future<void> connect() async {
    await _call('connect');
  }

  @override
  Future<void> fieldReset() async {
    await _call('reset');
  }

  @override
  Future<Uint8List> transmit(Uint8List apdu) async {
    final r = await _call('transmit', {'apdu': apdu});
    return r['data'] as Uint8List;
  }

  @override
  Future<Uint8List?> getUid() async {
    try {
      final r = await transmit(Uint8List.fromList(const [0xFF, 0xCA, 0x00, 0x00, 0x00]));
      if (r.length > 2 && r[r.length - 2] == 0x90 && r[r.length - 1] == 0x00) return Uint8List.sublistView(r, 0, r.length - 2);
    } on CardException {
      // the reader cannot give a UID
    }
    return null;
  }

  @override
  Future<void> disconnect() async {
    await _call('disconnect');
  }

  @override
  Future<void> dispose() => disconnect();
}

// ------------------------------------------------------------------ worker isolate

class _PcscWorker {
  _PcscWorker._(this._send);

  static Future<_PcscWorker>? _starting;

  final SendPort _send;
  final _pending = <int, Completer<Map<Object?, Object?>>>{};
  var _next = 0;

  static Future<_PcscWorker> instance() => _starting ??= _start();

  static Future<_PcscWorker> _start() async {
    final receive = ReceivePort();
    final ready = Completer<SendPort>();
    _PcscWorker? worker;
    receive.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is Map) {
        final id = message['id'] as int;
        worker?._pending.remove(id)?.complete(message);
      }
    });
    await Isolate.spawn(_workerMain, receive.sendPort, debugName: 'pcsc');
    worker = _PcscWorker._(await ready.future);
    return worker;
  }

  Future<Map<Object?, Object?>> call(String op, Map<String, Object?> args) {
    final id = _next++;
    final completer = Completer<Map<Object?, Object?>>();
    _pending[id] = completer;
    _send.send({'id': id, 'op': op, ...args});
    return completer.future;
  }
}

class _ScardError implements Exception {
  _ScardError(this.code, this.call);

  final int code;
  final String call;
}

void _workerMain(SendPort toMain) {
  final port = ReceivePort();
  toMain.send(port.sendPort);
  _PcscState? state;
  port.listen((message) {
    final m = message as Map;
    final id = m['id'] as int;
    try {
      state ??= _PcscState();
      final result = state!.handle(m);
      toMain.send({'id': id, 'ok': true, ...result});
    } on _ScardError catch (e) {
      toMain.send({'id': id, 'ok': false, 'code': e.code, 'call': e.call});
    } catch (e) {
      toMain.send({'id': id, 'ok': false, 'code': 0, 'call': 'PC/SC', 'message': 'PC/SC problem: $e'});
    }
  });
}

class _Connection {
  _Connection(this.handle, this.protocol);

  final int handle;
  int protocol;
  Uint8List? atr;
}

typedef _EstablishC = Int32 Function(Uint32, Pointer<Void>, Pointer<Void>, Pointer<IntPtr>);
typedef _EstablishD = int Function(int, Pointer<Void>, Pointer<Void>, Pointer<IntPtr>);
typedef _ReleaseC = Int32 Function(IntPtr);
typedef _ReleaseD = int Function(int);
typedef _ListC = Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint32>);
typedef _ListD = int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint32>);
typedef _ConnectC = Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>, Pointer<Uint32>);
typedef _ConnectD = int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>, Pointer<Uint32>);
typedef _ReconnectC = Int32 Function(IntPtr, Uint32, Uint32, Uint32, Pointer<Uint32>);
typedef _ReconnectD = int Function(int, int, int, int, Pointer<Uint32>);
typedef _DisconnectC = Int32 Function(IntPtr, Uint32);
typedef _DisconnectD = int Function(int, int);
typedef _TransmitC = Int32 Function(IntPtr, Pointer<Uint32>, Pointer<Uint8>, Uint32, Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _TransmitD = int Function(int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _GetAttribC = Int32 Function(IntPtr, Uint32, Pointer<Uint8>, Pointer<Uint32>);
typedef _GetAttribD = int Function(int, int, Pointer<Uint8>, Pointer<Uint32>);

/// Lives in the worker isolate: the PC/SC context and the open card connections.
class _PcscState {
  _PcscState() {
    final lib = DynamicLibrary.open('winscard.dll');
    _establish = lib.lookupFunction<_EstablishC, _EstablishD>('SCardEstablishContext');
    _release = lib.lookupFunction<_ReleaseC, _ReleaseD>('SCardReleaseContext');
    _list = lib.lookupFunction<_ListC, _ListD>('SCardListReadersW');
    _connect = lib.lookupFunction<_ConnectC, _ConnectD>('SCardConnectW');
    _reconnect = lib.lookupFunction<_ReconnectC, _ReconnectD>('SCardReconnect');
    _disconnect = lib.lookupFunction<_DisconnectC, _DisconnectD>('SCardDisconnect');
    _transmit = lib.lookupFunction<_TransmitC, _TransmitD>('SCardTransmit');
    _getAttrib = lib.lookupFunction<_GetAttribC, _GetAttribD>('SCardGetAttrib');
  }

  late final _EstablishD _establish;
  late final _ReleaseD _release;
  late final _ListD _list;
  late final _ConnectD _connect;
  late final _ReconnectD _reconnect;
  late final _DisconnectD _disconnect;
  late final _TransmitD _transmit;
  late final _GetAttribD _getAttrib;

  int _context = 0;
  final _connections = <String, _Connection>{};

  Map<String, Object?> handle(Map m) {
    final op = m['op'] as String;
    final reader = m['reader'] as String?;
    switch (op) {
      case 'list':
        return {'readers': _readers()};
      case 'connect':
        return {'atr': _open(reader!).atr};
      case 'reset':
        return {'atr': _reset(reader!).atr};
      case 'transmit':
        final data = _send(reader!, m['apdu'] as Uint8List);
        return {'data': data, 'atr': _connections[reader]?.atr};
      case 'disconnect':
        _close(reader!);
        return {};
    }
    throw _ScardError(0, 'unknown request $op');
  }

  int _ensureContext() {
    if (_context != 0) return _context;
    final p = calloc<IntPtr>();
    try {
      final rc = _establish(_scopeSystem, nullptr, nullptr, p);
      if (rc != 0) throw _ScardError(rc, 'SCardEstablishContext');
      _context = p.value;
      return _context;
    } finally {
      calloc.free(p);
    }
  }

  List<String> _readers() {
    final ctx = _ensureContext();
    const size = 16384;
    final buffer = calloc<Uint16>(size);
    final length = calloc<Uint32>()..value = size;
    try {
      final rc = _list(ctx, nullptr, buffer.cast<Utf16>(), length);
      if (rc != 0) {
        if ((rc & 0xFFFFFFFF) == 0x8010001E || (rc & 0xFFFFFFFF) == 0x8010001D) {
          _release(ctx); // the service restarted: get a new context next time
          _context = 0;
        }
        return const [];
      }
      final n = length.value < size ? length.value : size;
      return String.fromCharCodes(buffer.asTypedList(n)).split('\u0000').where((s) => s.isNotEmpty).toList();
    } finally {
      calloc.free(buffer);
      calloc.free(length);
    }
  }

  _Connection _open(String reader) {
    final existing = _connections[reader];
    if (existing != null) return existing;
    final ctx = _ensureContext();
    final name = reader.toNativeUtf16(allocator: calloc);
    final handle = calloc<IntPtr>();
    final protocol = calloc<Uint32>();
    try {
      final rc = _connect(ctx, name, _shareExclusive, _protocolT0T1, handle, protocol);
      if (rc != 0) throw _ScardError(rc, 'SCardConnect');
      final c = _Connection(handle.value, protocol.value);
      c.atr = _readAtr(c.handle);
      _connections[reader] = c;
      return c;
    } finally {
      calloc.free(name);
      calloc.free(handle);
      calloc.free(protocol);
    }
  }

  _Connection _reset(String reader) {
    final c = _open(reader);
    final protocol = calloc<Uint32>();
    try {
      final rc = _reconnect(c.handle, _shareExclusive, _protocolT0T1, _unpowerCard, protocol);
      if (rc != 0) {
        _close(reader);
        if (!_cardGone(rc)) throw _ScardError(rc, 'SCardReconnect');
        return _open(reader); // the card was put back or reset: a fresh connection powers it up, which is also a new tap
      }
      c.protocol = protocol.value;
      c.atr = _readAtr(c.handle);
      return c;
    } finally {
      calloc.free(protocol);
    }
  }

  Uint8List _send(String reader, Uint8List apdu) {
    final c = _open(reader);
    final extended = apdu.length > 5 && apdu[4] == 0;
    final size = extended ? 65538 + 64 : 1024;
    final pci = calloc<Uint32>(2);
    final send = calloc<Uint8>(apdu.length);
    final receive = calloc<Uint8>(size);
    final length = calloc<Uint32>();
    try {
      pci[0] = c.protocol;
      pci[1] = 8; // sizeof(SCARD_IO_REQUEST)
      send.asTypedList(apdu.length).setAll(0, apdu);
      length.value = size;
      final rc = _transmit(c.handle, pci, send, apdu.length, nullptr, receive, length);
      if (rc != 0) {
        if (_cardGone(rc)) _close(reader);
        throw _ScardError(rc, 'SCardTransmit');
      }
      if (length.value < 2) throw _ScardError(0, 'SCardTransmit returned no status word');
      return Uint8List.fromList(receive.asTypedList(length.value));
    } finally {
      calloc.free(pci);
      calloc.free(send);
      calloc.free(receive);
      calloc.free(length);
    }
  }

  Uint8List? _readAtr(int handle) {
    final buffer = calloc<Uint8>(64);
    final length = calloc<Uint32>()..value = 64;
    try {
      final rc = _getAttrib(handle, _attrAtrString, buffer, length);
      if (rc != 0 || length.value == 0) return null;
      return Uint8List.fromList(buffer.asTypedList(length.value));
    } finally {
      calloc.free(buffer);
      calloc.free(length);
    }
  }

  void _close(String reader) {
    final c = _connections.remove(reader);
    if (c != null) _disconnect(c.handle, _leaveCard);
  }
}

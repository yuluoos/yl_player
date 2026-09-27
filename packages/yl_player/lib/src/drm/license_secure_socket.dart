import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Adapts an already verified TLS raw socket for HttpClient. Owning the raw TCP
/// socket before this adapter exists makes handshake cancellation deterministic.
final class YlLicenseSecureSocket extends Stream<Uint8List>
    implements SecureSocket {
  YlLicenseSecureSocket(this._raw) {
    _input = StreamController<Uint8List>(
      onPause: () => _raw.readEventsEnabled = false,
      onResume: () => _raw.readEventsEnabled = true,
      onCancel: destroy,
    );
    _sink = IOSink(_LicenseSocketConsumer(this));
    // Errors on the sink are also observed by HttpClient's flush/close futures.
    unawaited(_sink.done.then<void>((_) {}, onError: (Object _) {}));
    _raw.writeEventsEnabled = false;
    _raw.listen(
      _event,
      onError: (Object error, StackTrace stack) {
        if (!_input.isClosed) _input.addError(error, stack);
        destroy();
      },
      onDone: destroy,
    );
  }
  final RawSecureSocket _raw;
  late final StreamController<Uint8List> _input;
  late final IOSink _sink;
  Completer<void>? _writable;
  bool _destroyed = false;

  void _event(RawSocketEvent event) {
    if (_destroyed) return;
    switch (event) {
      case RawSocketEvent.read:
        final bytes = _raw.read();
        if (bytes != null && !_input.isClosed) _input.add(bytes);
      case RawSocketEvent.write:
        _writable?.complete();
        _writable = null;
      case RawSocketEvent.readClosed:
        _input.close();
      case RawSocketEvent.closed:
        destroy();
    }
  }

  Future<void> _write(List<int> data) async {
    var offset = 0;
    while (offset < data.length) {
      if (_destroyed) throw const SocketException('Closed');
      offset += _raw.write(data, offset, data.length - offset);
      if (offset < data.length) {
        final ready = Completer<void>();
        _writable = ready;
        _raw.writeEventsEnabled = true;
        await ready.future;
      }
    }
  }

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _raw.close();
    _writable?.complete();
    _writable = null;
    _input.close();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _input.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  X509Certificate? get peerCertificate => _raw.peerCertificate;
  @override
  String? get selectedProtocol => _raw.selectedProtocol;
  @override
  InternetAddress get address => _raw.address;
  @override
  InternetAddress get remoteAddress => _raw.remoteAddress;
  @override
  int get port => _raw.port;
  @override
  int get remotePort => _raw.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _raw.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _raw.setRawOption(option);
  @override
  Encoding get encoding => _sink.encoding;
  @override
  set encoding(Encoding value) => _sink.encoding = value;
  @override
  Future<void> get done => _sink.done;
  @override
  void add(List<int> data) => _sink.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnsupportedError('Socket.addError');
  @override
  Future<void> addStream(Stream<List<int>> stream) => _sink.addStream(stream);
  @override
  Future<void> flush() => _sink.flush();
  @override
  Future<void> close() => _sink.close();
  @override
  void write(Object? object) => _sink.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _sink.writeln(object);
  // Socket has private SDK members which HttpClient never calls. They cannot be
  // implemented outside dart:io; fail explicitly if that contract changes.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Socket operation');
}

final class _LicenseSocketConsumer implements StreamConsumer<List<int>> {
  _LicenseSocketConsumer(this.socket);
  final YlLicenseSecureSocket socket;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      await socket._write(chunk);
    }
  }

  @override
  Future<void> close() async {
    if (!socket._destroyed) socket._raw.shutdown(SocketDirection.send);
  }
}

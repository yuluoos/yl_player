import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Observes transport errors before HttpClient erases their type while parsing
/// response headers. Delegates all I/O and keeps SecureSocket identity for TLS.
Socket observeSubtitleSocket(Socket socket, void Function(Object) onError) =>
    socket is SecureSocket
    ? _ObservedSecureSocket(socket, onError)
    : _ObservedSocket(socket, onError);

class _ObservedSocket extends Stream<Uint8List> implements Socket {
  _ObservedSocket(this.socket, this.onTransportError);
  final Socket socket;
  final void Function(Object) onTransportError;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => socket
      .handleError((Object error, StackTrace stack) {
        onTransportError(error);
        Error.throwWithStackTrace(error, stack);
      })
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  InternetAddress get address => socket.address;
  @override
  InternetAddress get remoteAddress => socket.remoteAddress;
  @override
  int get port => socket.port;
  @override
  int get remotePort => socket.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => socket.setRawOption(option);
  @override
  Encoding get encoding => socket.encoding;
  @override
  set encoding(Encoding value) => socket.encoding = value;
  @override
  Future<void> get done => socket.done;
  @override
  void add(List<int> data) => socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      socket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => socket.addStream(stream);
  @override
  Future<void> flush() => socket.flush();
  @override
  Future<void> close() => socket.close();
  @override
  void destroy() => socket.destroy();
  @override
  void write(Object? object) => socket.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      socket.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => socket.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => socket.writeln(object);
  // Socket has private SDK members which HttpClient never invokes.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Socket operation');
}

final class _ObservedSecureSocket extends _ObservedSocket
    implements SecureSocket {
  _ObservedSecureSocket(SecureSocket super.socket, super.onTransportError);
  @override
  X509Certificate? get peerCertificate =>
      (socket as SecureSocket).peerCertificate;
  @override
  String? get selectedProtocol => (socket as SecureSocket).selectedProtocol;
}

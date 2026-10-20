import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const control = MethodChannel('dev.ylplayer.shutdown_test');
  const factory = MethodChannel('dev.ylplayer.media_delivery');
  String? owner;
  control.setMethodCallHandler((call) async {
    if (call.method == 'prepare') {
      owner = await factory.invokeMethod<String>('create');
      return MethodChannel(
        'dev.ylplayer.media_delivery.$owner',
      ).invokeMethod<Object?>('prepare', {
        'id': 'd1',
        'source': {
          'kind': 'network',
          'uri': call.arguments,
          'intent': 'live',
          'format': 'flv',
          'headers': <String, String>{},
          'credentials': <String, String>{},
          'networkPolicy': {'kind': 'platformDefault'},
        },
        'options': {
          'autoplay': false,
          'bufferStrategy': {'kind': 'automatic'},
        },
      });
    }
    if (call.method == 'channelsRemoved') {
      Future<bool> absent(MethodChannel channel, String method) async {
        try {
          await channel.invokeMethod<Object?>(method);
          return false;
        } on MissingPluginException {
          return true;
        }
      }

      return await absent(factory, 'create') &&
          await absent(
            MethodChannel('dev.ylplayer.media_delivery.$owner'),
            'dispose',
          );
    }
    throw MissingPluginException();
  });
  control.invokeMethod<void>('ready');
}

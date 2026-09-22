import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_source_resolver/src/native_runtime.dart';

void main() {
  test('pinned CryptoJS has MD5 HMAC and AES CBC known answers', () async {
    final job = NativeRuntimeJob.start('''
function main(){
 const C=CryptoJS;
 const decrypted=C.AES.decrypt(C.lib.CipherParams.create({ciphertext:C.enc.Hex.parse('7649abac8119b246cee98e9b12e9197d8964e0b149c10b7b682e6e39aaeb731c')}),C.enc.Hex.parse('2b7e151628aed2a6abf7158809cf4f3c'),{iv:C.enc.Hex.parse('000102030405060708090a0b0c0d0e0f'),mode:C.mode.CBC,padding:C.pad.Pkcs7});
 return {md5:C.MD5('abc').toString(),hmac:C.HmacSHA256('The quick brown fox jumps over the lazy dog','key').toString(),aes:decrypted.toString()};
}
''');
    addTearDown(job.close);
    while (job.status == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(job.status, 1);
    expect(jsonDecode(job.resultJson!), {
      'md5': '900150983cd24fb0d6963f7d28e17f72',
      'hmac':
          'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
      'aes': '6bc1bee22e409f96e93d7e117393172a',
    });
  });
}

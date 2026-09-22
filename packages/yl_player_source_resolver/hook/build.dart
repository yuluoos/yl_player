import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os != OS.android && os != OS.iOS && os != OS.macOS) {
      throw UnsupportedError(
        'yl_player_source_resolver supports Android, iOS and macOS.',
      );
    }
    await CBuilder.library(
      name: 'yl_script_runtime',
      assetName: 'src/native_runtime.dart',
      sources: [
        'src/yl_script_runtime.c',
        'src/quickjs/quickjs.c',
        'src/quickjs/cutils.c',
        'src/quickjs/dtoa.c',
        'src/quickjs/libregexp.c',
        'src/quickjs/libunicode.c',
      ],
      includes: ['src/quickjs'],
      defines: {'_GNU_SOURCE': null, 'CONFIG_VERSION': '"2026-06-04"'},
      flags: [
        '-std=gnu11',
        '-fwrapv',
        '-funsigned-char',
        '-fvisibility=hidden',
      ],
      libraries: os == OS.android ? ['m'] : [],
    ).run(input: input, output: output);
  });
}

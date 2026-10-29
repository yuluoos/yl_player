// Process-local compatibility for the installed ARM iproxy. No SDK files change.
import 'dart:io';
import 'package:process/process.dart';
import 'package:flutter_tools/executable.dart' as executable;
import 'package:flutter_tools/src/base/context.dart';

class ArmProxyProcesses extends LocalProcessManager {
  @override
  Future<Process> start(List<Object> command, {
    String? workingDirectory, Map<String, String>? environment,
    bool includeParentEnvironment = true, bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    if (command.first == '/Users/yy2021_8689/flutter/bin/cache/artifacts/libusbmuxd/iproxy') {
      command = ['/opt/homebrew/bin/iproxy', ...command.skip(1)];
      environment = {...?environment}..remove('DYLD_LIBRARY_PATH');
      stderr.writeln('Using installed ARM iproxy for this test process.');
    }
    return super.start(command, workingDirectory:workingDirectory,
      environment:environment, includeParentEnvironment:includeParentEnvironment,
      runInShell:runInShell, mode:mode);
  }
}
Future<void> main(List<String> args) => context.run<void>(
  body:() => executable.main(args), overrides:{ProcessManager:() => ArmProxyProcesses()});

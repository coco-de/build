// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'common/utils.dart';

// This doesn't actually change anything since we're using precompiled tests,
// but it gets the compiler selector in tests right.
const _testArgs = ['-c', 'dart2wasm'];

void main() {
  group('Can run tests using dart2wasm', timeout: const Timeout.factor(2), () {
    test(
      'via build.yaml config flag',
      () async {
        await expectTestsPass(
          usePrecompiled: true,
          buildArgs: ['--config=dart2wasm', '--output=${d.sandbox}'],
          testArgs: _testArgs,
        );
        await _expectWasCompiledWithDart2Wasm();
      },
      onPlatform: {'windows': const Skip('flaky on windows')},
    );

    test('via --define flag', () async {
      await expectTestsPass(
        usePrecompiled: true,
        buildArgs: [
          '--define',
          'jaspr_web_compilers:entrypoint=compiler=dart2wasm',
          '--define',
          'jaspr_web_compilers:entrypoint=dart2wasm_args='
              '["--enable-asserts", "-E--enable-experimental-ffi"]',
          '--output=${d.sandbox}',
        ],
        testArgs: _testArgs,
      );
      await _expectWasCompiledWithDart2Wasm();
    }, onPlatform: {'windows': const Skip('flaky on windows')});

    test('via --release mode', () async {
      await expectTestsPass(
        usePrecompiled: true,
        buildArgs: ['--release', '--config=dart2wasm', '--output=${d.sandbox}'],
        testArgs: _testArgs,
      );
      await _expectWasCompiledWithDart2Wasm();
    }, onPlatform: {'windows': const Skip('flaky on windows')});

    test(
      'when also enabling dart2js',
      () async {
        await expectTestsPass(
          usePrecompiled: true,
          buildArgs: ['--release', '--config=both', '--output=${d.sandbox}'],
          testArgs: [..._testArgs, '-p', 'chrome_without_wasm', '-p', 'chrome'],
        );
        await _expectWasCompiledWithDart2Wasm();

        await d.dir('test', [
          d.file(
            'hello_world_deferred_test.dart.browser_test.dart2js.js',
            startsWith('// Generated by dart2js'),
          ),
        ]).validate();
      },
      onPlatform: {'windows': const Skip('flaky on windows')},
    );
  });
}

Future<void> _expectWasCompiledWithDart2Wasm() async {
  await d.dir('test', [
    d.file('hello_world_deferred_test.dart.browser_test.wasm', anything),
  ]).validate();
}

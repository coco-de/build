// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'common/utils.dart';

const _outputDir = 'dart2js_test';

void main() {
  group('Can run tests using dart2js', () {
    tearDown(() async {
      var dir = Directory(_outputDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test(
      'via build.yaml config flag',
      () async {
        await expectTestsPass(
          usePrecompiled: true,
          buildArgs: ['--config=dart2js', '--output=$_outputDir'],
        );
        await _expectWasCompiledWithDart2JS(minified: false);
      },
      onPlatform: {'windows': const Skip('flaky on windows')},
    );

    test('via --define flag', () async {
      await expectTestsPass(
        usePrecompiled: true,
        buildArgs: [
          '--define',
          'jaspr_web_compilers:entrypoint=compiler=dart2js',
          '--define',
          'jaspr_web_compilers:entrypoint=dart2js_args=["--minify"]',
          '--output=$_outputDir',
        ],
      );
      await _expectWasCompiledWithDart2JS(minified: true);
    }, onPlatform: {'windows': const Skip('flaky on windows')});

    test('via --release mode', () async {
      await expectTestsPass(
        usePrecompiled: true,
        buildArgs: ['--release', '--output=$_outputDir'],
      );
      await _expectWasCompiledWithDart2JS(minified: true);
    }, onPlatform: {'windows': const Skip('flaky on windows')});

    test(
      '--define overrides --config',
      () async {
        await expectTestsPass(
          usePrecompiled: true,
          buildArgs: [
            '--config',
            'dart2js',
            '--define',
            'jaspr_web_compilers:entrypoint=compiler=dart2js',
            '--define',
            'jaspr_web_compilers:entrypoint=dart2js_args=["--minify"]',
            '--output=$_outputDir',
          ],
        );
        await _expectWasCompiledWithDart2JS(minified: true);
      },
      onPlatform: {'windows': const Skip('flaky on windows')},
    );
  });
}

Future<void> _expectWasCompiledWithDart2JS({bool minified = false}) async {
  var jsFile = File(
    '$_outputDir/test/hello_world_deferred_test.dart.browser_test.dart.js',
  );
  expect(await jsFile.exists(), isTrue);
  // sanity check that it was indeed compiled with dart2js
  var content = await jsFile.readAsString();
  if (minified) {
    expect(content, isNot(startsWith('//')));
    expect(content, contains('typeof dartMainRunner==="function"'));
  } else {
    expect(content, startsWith('// Generated by dart2js'));
  }

  var jsDeferredPartFile = File(
    '$_outputDir/test/hello_world_deferred_test.dart.browser_test.dart.js'
    '_1.part.js',
  );
  expect(await jsDeferredPartFile.exists(), isTrue);
}

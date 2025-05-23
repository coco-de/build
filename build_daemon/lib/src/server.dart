// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:built_value/serializer.dart';
import 'package:http_multi_server/http_multi_server.dart';
import 'package:pool/pool.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_transform/stream_transform.dart';
import 'package:watcher/watcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../change_provider.dart';
import '../constants.dart';
import '../daemon_builder.dart';
import '../data/build_request.dart';
import '../data/build_target.dart';
import '../data/build_target_request.dart';
import '../data/serializers.dart';
import '../data/server_log.dart';
import '../data/shutdown_notification.dart';
import 'managers/build_target_manager.dart';

/// A server which communicates with build daemon clients over websockets.
///
/// Handles notifying clients of logs and results for registered build targets.
/// Note the server will only notify clients of pertinent events.
class Server {
  static final loggerName = 'BuildDaemonServer';
  final _isDoneCompleter = Completer<int>();
  final BuildTargetManager _buildTargetManager;
  final _pool = Pool(1);
  final Serializers _serializers;
  final ChangeProvider _changeProvider;
  late final Timer _timeout;
  HttpServer? _server;
  final DaemonBuilder _builder;
  // Channels that are interested in the current build.
  var _interestedChannels = <WebSocketChannel>{};
  final _subs = <StreamSubscription>[];
  final _outputStreamController = StreamController<ServerLog>();
  late final Stream<ServerLog> _logs;
  Server(
    this._builder,
    Duration timeout,
    ChangeProvider changeProvider, {
    Serializers? serializersOverride,
    bool Function(BuildTarget, Iterable<WatchEvent>)? shouldBuild,
  })  : _changeProvider = changeProvider,
        _serializers = serializersOverride ?? serializers,
        _buildTargetManager =
            BuildTargetManager(shouldBuildOverride: shouldBuild) {
    _logs = _outputStreamController.stream;
    _forwardData();
    if (changeProvider is AutoChangeProvider) {
      _handleChanges(changeProvider.changes);
    }
    // Stop the server if nobody connects.
    _timeout = Timer(timeout, () async {
      if (_buildTargetManager.isEmpty) {
        await stop();
      }
    });
  }

  /// Returns exit code.
  Future<int> get onDone => _isDoneCompleter.future;

  /// Starts listening for build daemon clients.
  Future<int> listen() async {
    var handler = webSocketHandler((WebSocketChannel channel, _) async {
      channel.stream.listen((message) async {
        dynamic request;
        try {
          request = _serializers.deserialize(jsonDecode(message as String));
        } catch (e, s) {
          _logMessage(Level.WARNING, 'Unable to parse message: $message', e, s);
          return;
        }
        if (request is BuildTargetRequest) {
          _buildTargetManager.addBuildTarget(request.target, channel);
        } else if (request is BuildRequest) {
          // We can only get explicit build requests if we have a manual change
          // provider.
          var changeProvider = _changeProvider;
          var changes = changeProvider is ManualChangeProvider
              ? await changeProvider.collectChanges()
              : <WatchEvent>[];
          var targets = changes.isEmpty
              ? _buildTargetManager.targets
              : _buildTargetManager.targetsForChanges(changes);
          await _build(targets, changes);
        }
      }, onDone: () {
        _removeChannel(channel);
      });
    });
    var server = _server = await HttpMultiServer.loopback(0);
    // Serve requests in an error zone to prevent failures
    // when running from another error zone.
    runZonedGuarded(() => serveRequests(server, handler), (e, s) {
      _logMessage(Level.WARNING, 'Error serving requests', e, s);
    });
    return server.port;
  }

  Future<void> stop({String message = '', int failureType = 0}) async {
    if (message.isNotEmpty && failureType != 0) {
      for (var connection in _buildTargetManager.allChannels) {
        connection.sink
            .add(jsonEncode(_serializers.serialize(ShutdownNotification((b) => b
              ..message = message
              ..failureType = failureType))));
      }
    }
    _timeout.cancel();
    await _server?.close(force: true);
    await _builder.stop();
    for (var sub in _subs) {
      await sub.cancel();
    }
    await _outputStreamController.close();
    if (!_isDoneCompleter.isCompleted) _isDoneCompleter.complete(failureType);
  }

  Future<void> _build(
          Set<BuildTarget> buildTargets, Iterable<WatchEvent> changes) =>
      _pool.withResource(() {
        _interestedChannels =
            buildTargets.expand(_buildTargetManager.channels).toSet();
        return _builder.build(buildTargets, changes);
      });
  void _forwardData() {
    _subs
      ..add(_builder.logs.listen((log) {
        var message = jsonEncode(_serializers.serialize(log));
        for (var channel in _interestedChannels) {
          channel.sink.add(message);
        }
      }))
      ..add(_builder.builds.listen((status) {
        // Don't serialize or send changed assets if the client isn't interested
        // in them.
        String? message, messageWithoutChangedAssets;
        for (var channel in _interestedChannels) {
          var targets = _buildTargetManager.targetsFor(channel);
          var wantsChangedAssets = targets
              .any((e) => e is DefaultBuildTarget && e.reportChangedAssets);
          String messageForChannel;
          if (wantsChangedAssets) {
            messageForChannel =
                message ??= jsonEncode(_serializers.serialize(status));
          } else {
            messageForChannel = messageWithoutChangedAssets ??= jsonEncode(
                _serializers
                    .serialize(status.rebuild((b) => b.changedAssets = null)));
          }
          channel.sink.add(messageForChannel);
        }
      }))
      ..add(_logs.listen((log) {
        var message = jsonEncode(_serializers.serialize(log));
        for (var channel in _interestedChannels) {
          channel.sink.add(message);
        }
      }));
  }

  void _handleChanges(Stream<List<WatchEvent>> changes) {
    _subs.add(changes.asyncMapBuffer((changesLists) async {
      var changes = changesLists.expand((x) => x).toList();
      if (changes.isEmpty) return;
      if (_buildTargetManager.targets.isEmpty) return;
      var buildTargets = _buildTargetManager.targetsForChanges(changes);
      if (buildTargets.isEmpty) return;
      await _build(buildTargets, changes);
    }).listen((_) {}, onError: (Object? e) {
      stop(
          message: 'Error in file change event: $e',
          failureType: fileChangeEventErrorCode);
    }, onDone: () {
      stop(
          message: 'File change stream closed',
          failureType: fileChangeStreamClosedErrorCode);
    }));
  }

  void _removeChannel(WebSocketChannel channel) async {
    _buildTargetManager.removeChannel(channel);
    if (_buildTargetManager.isEmpty) {
      await stop();
    }
  }

  void _logMessage(Level level, String message,
          [Object? error, StackTrace? stackTrace]) =>
      _outputStreamController.add(ServerLog((b) => b
        ..message = message
        ..level = level
        ..loggerName = loggerName
        ..error = error?.toString()
        ..stackTrace = stackTrace?.toString()));
}

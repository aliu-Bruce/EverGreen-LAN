// 回环通道:提权核心经本机 TCP 连回界面,首行令牌通过后复用行协议。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/ipc.dart';

const token = '0123456789abcdef0123456789abcdef';

Future<(IpcBridge, Socket, Socket, ServerSocket)> pair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final clientFuture = Socket.connect(InternetAddress.loopbackIPv4, server.port);
  final acceptedFuture = server.first;
  final client = await clientFuture;
  final accepted = await acceptedFuture;
  return (IpcBridge(), accepted, client, server);
}

void main() {
  test('回环通道:认证后请求与应答走同一行协议', () async {
    final (bridge, accepted, client, server) = await pair();
    client.write('${jsonEncode({'type': 'auth', 'token': token})}\n');
    await bridge.adoptSocket(accepted, token);

    final lines = client
        .cast<List<int>>()
        .transform(const Utf8Decoder())
        .transform(const LineSplitter());
    final first = Completer<String>();
    final sub = lines.listen((line) {
      if (!first.isCompleted) first.complete(line);
    });

    final pending = bridge.request({'op': 'status'}, timeout: const Duration(seconds: 5));
    final request = jsonDecode(await first.future) as Map<String, dynamic>;
    expect(request['op'], 'status');
    expect(request['id'], isNotEmpty);
    client.write('${jsonEncode({'type': 'status', 'state': 'idle', 'id': request['id']})}\n');
    final ack = await pending;
    expect(ack['state'], 'idle');

    await sub.cancel();
    await bridge.stop();
    await client.close();
    await server.close();
  });

  test('回环通道:令牌不符时拒绝接管', () async {
    final (bridge, accepted, client, server) = await pair();
    client.write('${jsonEncode({'type': 'auth', 'token': 'ffff'})}\n');
    await expectLater(bridge.adoptSocket(accepted, token), throwsA(isA<IpcError>()));
    expect(bridge.running, isFalse);
    await bridge.stop();
    await client.close();
    await server.close();
  });
}

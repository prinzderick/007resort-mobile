import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r007_mobile/core/api/r007_api.dart';
import 'package:r007_mobile/core/config/app_config.dart';
import 'package:r007_mobile/core/realtime/pusher_client.dart';

/// Minimal Reverb/Pusher-protocol server for the client test.
class FakeReverb {
  late HttpServer server;
  final received = <Map<String, dynamic>>[];
  // ignore: close_sinks
  WebSocket? socket;
  final connected = Completer<void>();

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      // ignore: close_sinks
      final ws = await WebSocketTransformer.upgrade(req);
      socket = ws;
      ws.add(
        jsonEncode({
          'event': 'pusher:connection_established',
          'data': jsonEncode({
            'socket_id': '1234.5678',
            'activity_timeout': 30,
          }),
        }),
      );
      ws.listen((dynamic m) {
        received.add(jsonDecode(m as String) as Map<String, dynamic>);
        if (!connected.isCompleted) {
          connected.complete();
        }
      });
    });
  }

  void send(String event, Map<String, dynamic> envelope, {String? channel}) =>
      socket!.add(
        jsonEncode({
          'event': event,
          'channel': channel,
          'data': jsonEncode(envelope),
        }),
      );

  Future<void> stop() => server.close(force: true);
}

void main() {
  test(
    'authorises private channels, unwraps envelopes, de-dupes by eventId, answers ping',
    () async {
      final reverb = FakeReverb();
      await reverb.start();
      addTearDown(reverb.stop);

      final auths = <String>[];
      final client = PusherClient(
        config: RealtimeConfig(
          host: '127.0.0.1',
          port: reverb.server.port,
          appKey: 'k',
        ),
        channels: ['private-facility.f1.orders', 'private-device.d1'],
        authorize: (socketId, channel) async {
          auths.add('$socketId|$channel');
          return 'k:sig-$channel';
        },
      );
      final events = <RealtimeEvent>[];
      final sub = client.events.listen(events.add);
      addTearDown(sub.cancel);

      await reverb.connected.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // channel auth used the socket id and both private channels were subscribed
      expect(auths, [
        '1234.5678|private-facility.f1.orders',
        '1234.5678|private-device.d1',
      ]);
      final subs = reverb.received.where(
        (m) => m['event'] == 'pusher:subscribe',
      );
      expect(subs.map((m) => (m['data'] as Map)['channel']), [
        'private-facility.f1.orders',
        'private-device.d1',
      ]);
      expect(
        (subs.first['data'] as Map)['auth'],
        'k:sig-private-facility.f1.orders',
      );
      // reload-on-connect hint
      expect(events.first.name, 'realtime.connected');

      final env = {
        'eventId': 'e-1',
        'occurredAt': '2026-09-23T10:31:02Z',
        'data': {'orderId': 'o1', 'orderNumber': 'RST1-1', 'tableLabel': 'T12'},
      };
      reverb.send('.order.ready', env, channel: 'private-facility.f1.orders');
      reverb.send(
        '.order.ready',
        env,
        channel: 'private-facility.f1.orders',
      ); // dup
      reverb.send('order.updated', {
        'eventId': 'e-2',
        'data': {'rowVersion': 4},
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final named = events
          .where((e) => e.name != 'realtime.connected')
          .toList();
      expect(named.map((e) => e.name), ['order.ready', 'order.updated']);
      expect(named.first.data['tableLabel'], 'T12');
      expect(named.first.eventId, 'e-1');

      reverb.socket!.add(
        jsonEncode({'event': 'pusher:ping', 'data': <String, dynamic>{}}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(reverb.received.any((m) => m['event'] == 'pusher:pong'), isTrue);
    },
  );

  test('reconnects with backoff after the server drops the socket', () async {
    final reverb = FakeReverb();
    await reverb.start();
    addTearDown(reverb.stop);
    final client = PusherClient(
      config: RealtimeConfig(
        host: '127.0.0.1',
        port: reverb.server.port,
        appKey: 'k',
      ),
      channels: ['private-device.d1'],
      authorize: (s, c) async => 'sig',
    );
    var connects = 0;
    final sub = client.events.listen((e) {
      if (e.name == 'realtime.connected') {
        connects++;
      }
    });
    addTearDown(sub.cancel);
    await reverb.connected.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(connects, 1);
    await reverb.socket!.close();
    // first retry is ~2 s (1<<1) + jitter
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(connects, 2);
  });
}

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/r007_api.dart';
import '../config/app_config.dart';

typedef ChannelAuthorizer =
    Future<String> Function(String socketId, String channel);

/// Minimal Pusher-protocol (Laravel Reverb) client per `api/realtime.md`:
/// connects, authorises private channels via `POST /broadcasting/auth`,
/// unwraps the event envelope `{eventId, occurredAt, correlationId, data}`,
/// dedupes on `eventId`, and reconnects with exponential backoff + jitter.
///
/// Realtime is a HINT channel only: after every (re)connect a synthetic
/// `realtime.connected` event is emitted so screens reload state over REST,
/// and screens also poll, so a dead socket never blocks staff.
class PusherClient {
  PusherClient({
    required this.config,
    required this.channels,
    required this.authorize,
  }) {
    _controller = StreamController<RealtimeEvent>.broadcast(
      onListen: _start,
      onCancel: _stop,
    );
  }

  final RealtimeConfig config;
  final List<String> channels;
  final ChannelAuthorizer authorize;
  late final StreamController<RealtimeEvent> _controller;

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  bool _running = false;
  int _attempt = 0;
  final Queue<String> _seen = Queue<String>();
  final _rnd = Random();

  Stream<RealtimeEvent> get events => _controller.stream;

  Uri get wsUri => Uri(
    scheme: config.scheme == 'wss' ? 'wss' : 'ws',
    host: config.host,
    port: config.port,
    path: '/app/${config.appKey}',
    queryParameters: {
      'protocol': '7',
      'client': 'r007-mobile',
      'version': '1.0',
    },
  );

  void _start() {
    _running = true;
    _connect();
  }

  void _stop() {
    _running = false;
    _retry?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_ws?.sink.close());
  }

  void _connect() {
    if (!_running) return;
    try {
      final ws = WebSocketChannel.connect(wsUri);
      _ws = ws;
      _sub = ws.stream.listen(
        (dynamic raw) => unawaited(_onMessage(raw.toString())),
        onError: (Object _) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );
    } on Object {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _retry?.cancel();
    _attempt++;
    final secs = min(30, 1 << min(_attempt, 5));
    _retry = Timer(
      Duration(milliseconds: secs * 1000 + _rnd.nextInt(700)),
      _connect,
    );
  }

  bool _isDuplicate(String? id) {
    if (id == null || id.isEmpty) return false;
    if (_seen.contains(id)) return true;
    _seen.add(id);
    if (_seen.length > 200) _seen.removeFirst();
    return false;
  }

  Future<void> _onMessage(String raw) async {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } on Object {
      return;
    }
    final event = msg['event']?.toString() ?? '';
    switch (event) {
      case 'pusher:connection_established':
        _attempt = 0;
        final data = jsonDecode(msg['data'].toString()) as Map<String, dynamic>;
        final socketId = data['socket_id'].toString();
        for (final ch in channels) {
          try {
            final auth = await authorize(socketId, ch);
            _ws?.sink.add(
              jsonEncode({
                'event': 'pusher:subscribe',
                'data': {'channel': ch, 'auth': auth},
              }),
            );
          } on Object {
            // channel auth failed (e.g. permission_denied); keep the others
          }
        }
        // Reload state over REST after every (re)connect (realtime.md §5).
        if (!_controller.isClosed) {
          _controller.add(
            const RealtimeEvent('realtime.connected', <String, dynamic>{}),
          );
        }
      case 'pusher:ping':
        _ws?.sink.add(
          jsonEncode({'event': 'pusher:pong', 'data': <String, dynamic>{}}),
        );
      default:
        if (event.startsWith('pusher')) return;
        var data = msg['data'];
        if (data is String && data.isNotEmpty) {
          try {
            data = jsonDecode(data);
          } on Object {
            // leave as-is
          }
        }
        final env = data is Map<String, dynamic> ? data : <String, dynamic>{};
        final id = env['eventId']?.toString();
        if (_isDuplicate(id)) return;
        final inner = env['data'] is Map<String, dynamic>
            ? env['data'] as Map<String, dynamic>
            : env;
        if (!_controller.isClosed) {
          _controller.add(
            RealtimeEvent(
              event.replaceFirst(RegExp(r'^\.'), ''),
              inner,
              eventId: id,
            ),
          );
        }
    }
  }
}

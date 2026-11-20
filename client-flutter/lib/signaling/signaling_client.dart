import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum SignalingState { idle, connecting, open, closed, error }

class SignalingException implements Exception {
  SignalingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 房间信令 WS：`wss://<host>/ws/signaling?token=<roomToken>&device_id=<self>`。
///
/// 服务端是**二进制透明中继**：文本帧按 JSON 广播，二进制帧原样转发。因此这里
/// 同时暴露两条流——[messages] 给控制逻辑，[binary] 给 JPEG 兜底通路。
class SignalingClient {
  SignalingClient({required this.url});

  final String url;

  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Uint8List> _binary = StreamController<Uint8List>.broadcast();
  final ValueNotifier<SignalingState> state = ValueNotifier<SignalingState>(SignalingState.idle);

  WebSocketChannel? _channel;
  HttpClient? _httpClient;
  StreamSubscription<dynamic>? _sub;
  bool _disposed = false;
  String? _lastError;

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  Stream<Uint8List> get binary => _binary.stream;
  String? get lastError => _lastError;
  bool get isOpen => state.value == SignalingState.open;

  Future<void> connect({Duration timeout = const Duration(seconds: 8)}) async {
    if (_channel != null || state.value == SignalingState.open) return;
    _stateSet(SignalingState.connecting);
    final client = HttpClient()
      ..connectionTimeout = timeout
      // 自托管常用自签证书，与 ApiClient 保持一致。
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    _httpClient = client;
    try {
      final socket = await WebSocket.connect(url, customClient: client).timeout(timeout);
      socket.pingInterval = const Duration(seconds: 20);
      final channel = IOWebSocketChannel(socket);
      _channel = channel;
      _listen(channel);
      _stateSet(SignalingState.open);
    } catch (e) {
      _lastError = _describe(e);
      _stateSet(SignalingState.error);
      await _teardown();
      throw SignalingException(_lastError!);
    }
  }

  void _listen(WebSocketChannel channel) {
    _sub = channel.stream.listen(
      _onData,
      onError: (Object error) {
        _lastError = _describe(error);
        _stateSet(SignalingState.error);
      },
      onDone: () {
        if (state.value != SignalingState.error) _stateSet(SignalingState.closed);
      },
      cancelOnError: false,
    );
  }

  void _onData(dynamic data) {
    if (_messages.isClosed || _binary.isClosed) return;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) _messages.add(decoded.cast<String, dynamic>());
      } on FormatException {
        // 非 JSON 文本帧（服务端心跳/调试信息）直接忽略
      }
      return;
    }
    if (data is List<int>) {
      _binary.add(data is Uint8List ? data : Uint8List.fromList(data));
    }
  }

  void sendJson(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null || state.value != SignalingState.open) return;
    try {
      channel.sink.add(jsonEncode(message));
    } catch (e) {
      _lastError = _describe(e);
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    await _teardown();
    if (state.value != SignalingState.error) _stateSet(SignalingState.closed);
    await _messages.close();
    await _binary.close();
  }

  Future<void> _teardown() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    final channel = _channel;
    _channel = null;
    try {
      await channel?.sink.close();
    } catch (_) {
      // 已断开，忽略
    }
    _httpClient?.close(force: true);
    _httpClient = null;
  }

  void _stateSet(SignalingState next) {
    if (!_disposed) state.value = next;
  }

  static String _describe(Object error) {
    if (error is TimeoutException) return '连接超时（服务端不可达或被防火墙拦截）';
    if (error is WebSocketException) return 'WebSocket 握手失败：${error.message}';
    if (error is HandshakeException) return 'TLS 握手失败：${error.message}';
    if (error is SocketException) return '网络错误：${error.message}';
    return '$error';
  }
}
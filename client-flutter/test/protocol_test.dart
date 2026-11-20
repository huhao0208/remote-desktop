import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/app_config.dart';
import 'package:uu_remote/core/input_events.dart';
import 'package:uu_remote/core/models.dart';

void main() {
  group('agent.hello 解析', () {
    test('缺 media 字段时按 jpeg 处理（向后兼容老 Agent）', () {
      final AgentHello hello = AgentHello.fromJson(<String, dynamic>{
        'p': 'agent.hello',
        'name': 'MY-PC',
        'os': 'Darwin',
        'screen': <String, dynamic>{'w': 2048, 'h': 1280},
        'stream': <String, dynamic>{'fps': 30, 'quality': 75, 'width': 1920},
      });
      expect(hello.media, 'jpeg');
      expect(hello.isWebRtc, isFalse);
      expect(hello.width, 2048);
      expect(hello.height, 1280);
      expect(hello.fps, 30);
    });

    test('media=webrtc 时识别为 WebRTC 通路', () {
      final AgentHello hello = AgentHello.fromJson(<String, dynamic>{
        'name': 'MY-PC',
        'os': 'Darwin',
        'screen': <String, dynamic>{'w': 1920, 'h': 1080},
        'media': 'webrtc',
        'stream': <String, dynamic>{'fps': 30, 'bitrate': 8000},
      });
      expect(hello.isWebRtc, isTrue);
      expect(hello.media, 'webrtc');
    });

    test('v2 audio 能力位：true/1 都认，缺省为 false（老 Agent）', () {
      AgentHello parse(Object? audio) => AgentHello.fromJson(<String, dynamic>{
            'media': 'webrtc',
            'audio': audio,
          });
      expect(parse(true).audio, isTrue);
      expect(parse(1).audio, isTrue);
      expect(parse(false).audio, isFalse);
      expect(parse(null).audio, isFalse);
      expect(AgentHello.fromJson(<String, dynamic>{'media': 'webrtc'}).audio, isFalse);
    });
  });

  group('device.list 解析', () {
    test('int 型布尔值正确转 bool', () {
      final DeviceInfo d = DeviceInfo.fromJson(<String, dynamic>{
        'device_id': 'abc123',
        'device_name': '工作室 Mac',
        'platform': 'pc',
        'online': 1,
        'is_self': 0,
        'controllable': 1,
        'last_seen': 1700000000000,
      });
      expect(d.online, isTrue);
      expect(d.isSelf, isFalse);
      expect(d.controllable, isTrue);
      expect(d.name, '工作室 Mac');
    });
  });

  group('信令地址组装', () {
    test('服务端下发地址与 API 同 host 时直接复用', () {
      const RoomConfig room = RoomConfig(
        signalingServer: 'wss://47-251-105-202.sslip.io:8444/ws/signaling',
        roomToken: 'room-token',
        roomId: 'r1',
        iceServers: <Object?>[],
      );
      final String url = room.signalingUrl(
        deviceId: 'dev-self',
        apiBase: 'https://47-251-105-202.sslip.io:8444',
      );
      final Uri uri = Uri.parse(url);
      expect(uri.scheme, 'wss');
      expect(uri.host, '47-251-105-202.sslip.io');
      expect(uri.port, 8444);
      expect(uri.path, '/ws/signaling');
      expect(uri.queryParameters['token'], 'room-token');
      expect(uri.queryParameters['device_id'], 'dev-self');
    });

    test('服务端下发默认域名（未配置）时回落到 API host', () {
      const RoomConfig room = RoomConfig(
        signalingServer: 'wss://api.nrd.nie.163.com/ws/signaling',
        roomToken: 't',
        roomId: 'r1',
        iceServers: <Object?>[],
      );
      final Uri uri = Uri.parse(room.signalingUrl(
        deviceId: 'd',
        apiBase: 'https://47-251-105-202.sslip.io:8444',
      ));
      expect(uri.host, '47-251-105-202.sslip.io');
      expect(uri.port, 8444);
    });
  });

  group('输入事件', () {
    test('坐标归一化并夹到 0..1', () {
      final Map<String, dynamic> move = InputEvent.move(-3, 1.4);
      expect(move['p'], 'input');
      expect(move['t'], 'move');
      expect(move['x'], 0.0);
      expect(move['y'], 1.0);
    });

    test('stream.config 字段与协议一致', () {
      final Map<String, dynamic> cfg =
          InputEvent.streamConfig(width: 1920, quality: 75, fps: 30, bitrate: 8000);
      expect(jsonEncode(cfg), contains('"p":"stream.config"'));
      expect(cfg['bitrate'], 8000);
    });
  });

  group('画质档位', () {
    test('三档位 value 与 control.html 一致', () {
      expect(AppConfig.qualityPresets.map((QualityPreset p) => p.value).toList(),
          <String>['1280,55,4000', '1920,75,8000', '2560,80,20000']);
    });

    test('未知 value 回落到高清档', () {
      expect(QualityPreset.fromValue('1280,55,4000').width, 1280);
      expect(QualityPreset.fromValue('bad').value, '1920,75,8000');
      expect(QualityPreset.fromValue(null).value, '1920,75,8000');
    });
  });

  group('FRM1 帧头', () {
    test('带 8 字节时间戳时可解析出 JPEG 起点', () {
      final Uint8List frame = Uint8List.fromList(<int>[
        0x46, 0x52, 0x4D, 0x31, // FRM1
        0, 0, 0, 0, 0, 0, 0, 1, // 8B 时间戳
        0xFF, 0xD8, 0xFF, 0xE0, // JPEG SOI
      ]);
      expect(frame.sublist(0, 4), <int>[0x46, 0x52, 0x4D, 0x31]);
      final bool hasTimestamp = !(frame[4] == 0xFF && frame[5] == 0xD8);
      expect(hasTimestamp, isTrue);
      final int offset = hasTimestamp ? 12 : 4;
      expect(frame.sublist(offset, offset + 2), <int>[0xFF, 0xD8]);
    });
  });
}
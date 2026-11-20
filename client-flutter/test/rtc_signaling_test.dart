import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uu_remote/core/models.dart';
import 'package:uu_remote/media/rtc_signaling.dart';

void main() {
  group('ice_servers → RTCIceServer 数组', () {
    test('服务端 build_ice() 的 {stun, turn} 结构', () {
      final List<Map<String, dynamic>> servers = toRtcIceServers(<String, dynamic>{
        'stun': <String>['stun:47.251.105.202:3478'],
        'turn': <Map<String, dynamic>>[
          <String, dynamic>{
            'urls': 'turn:47.251.105.202:3478?transport=udp',
            'username': '1795000000:ub40b18',
            'credential': 'base64hmac',
          },
        ],
      });
      expect(servers, hasLength(2));
      expect(servers[0], <String, dynamic>{'urls': 'stun:47.251.105.202:3478'});
      expect(servers[1]['urls'], 'turn:47.251.105.202:3478?transport=udp');
      expect(servers[1]['username'], '1795000000:ub40b18');
      expect(servers[1]['credential'], 'base64hmac');
    });

    test('扁平数组形态（老服务端/手工配置）', () {
      final List<Map<String, dynamic>> servers = toRtcIceServers(<Object?>[
        <String, dynamic>{'urls': 'stun:a:3478'},
        <String, dynamic>{'urls': <String>['turn:a:3478?transport=udp'], 'username': 'u', 'credential': 'c'},
      ]);
      expect(servers, hasLength(2));
      expect(servers[0]['urls'], 'stun:a:3478');
      expect(servers[1]['urls'], <String>['turn:a:3478?transport=udp']);
    });

    test('空值 / 脏数据不抛异常，只丢弃', () {
      expect(toRtcIceServers(null), isEmpty);
      expect(toRtcIceServers(<String, dynamic>{}), isEmpty);
      expect(toRtcIceServers('bad'), isEmpty);
      expect(
        toRtcIceServers(<Object?>[
          <String, dynamic>{'username': 'no-urls'},
          <String, dynamic>{'urls': '   '},
          null,
          42,
        ]),
        isEmpty,
      );
    });
  });

  group('rtc.offer 载荷', () {
    test('字段与协议 §2.1 一致，ice 原样透传', () {
      final Map<String, dynamic> ice = <String, dynamic>{
        'stun': <String>['stun:a:3478'],
      };
      final Map<String, dynamic> offer = buildRtcOfferMessage(
        sdp: 'v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n',
        ice: ice,
        peer: 'dev-self',
      );
      expect(offer['p'], 'rtc.offer');
      expect(offer['peer'], 'dev-self');
      expect(offer['sdp'], startsWith('v=0'));
      expect(offer['ice'], same(ice));
      expect(jsonEncode(offer), contains('"p":"rtc.offer"'));
    });

    test('ice 缺省时发空对象而不是 null（Agent 侧不用判空）', () {
      final Map<String, dynamic> offer =
          buildRtcOfferMessage(sdp: 'v=0', ice: null, peer: 'ctl');
      expect(offer['ice'], isA<Map<String, dynamic>>());
    });
  });

  group('rtc.ice 载荷', () {
    test('构造字段与协议 §2.3 一致', () {
      final Map<String, dynamic> ice = buildRtcIceMessage(
        candidate: 'candidate:1 1 udp 2130706431 10.0.0.2 54321 typ host',
        sdpMid: '0',
        sdpMLineIndex: 0,
        peer: 'dev-self',
      );
      expect(ice['p'], 'rtc.ice');
      expect(ice['sdpMid'], '0');
      expect(ice['sdpMLineIndex'], 0);
      expect(ice['peer'], 'dev-self');
    });

    test('解析对端候选：数字/字符串索引都认，空候选返回 null', () {
      final RtcIcePayload? a = RtcIcePayload.fromJson(<String, dynamic>{
        'candidate': 'candidate:1 1 udp 1 10.0.0.2 1000 typ host',
        'sdpMid': '0',
        'sdpMLineIndex': 0.0,
      });
      expect(a, isNotNull);
      expect(a!.sdpMid, '0');
      expect(a.sdpMLineIndex, 0);
      expect(RtcIcePayload.fromJson(<String, dynamic>{'candidate': ''}), isNull);
      expect(RtcIcePayload.fromJson(<String, dynamic>{}), isNull);
    });
  });

  group('RoomConfig 保留原始 ice_servers', () {
    test('服务端下发对象形态时不被丢弃（回归：旧实现只接受 List）', () {
      final RoomConfig room = RoomConfig.fromJson(<String, dynamic>{
        'signaling_server': 'wss://h:8444/ws/signaling',
        'token': 't',
        'room_id': 'r1',
        'ice_servers': <String, dynamic>{
          'stun': <String>['stun:h:3478'],
        },
      });
      expect(room.iceServers, isA<Map<String, dynamic>>());
      expect(toRtcIceServers(room.iceServers).single['urls'], 'stun:h:3478');
    });
  });
}
import '../core/models.dart';
import 'jpeg_transport.dart';
import 'media_transport.dart';
import 'webrtc_transport.dart';

/// 按 `agent.hello.media` 选择通路。
///
/// 老 Agent 不发 `media` → [AgentHello.media] 已归一化为 `jpeg`。
/// `webrtc` 时返回 [WebRtcTransport]；`start()` 抛错（平台不支持 / 建 PC 失败）或
/// 运行中 `connectionState` 变 failed 时，页面负责回落 JPEG 并提示，
/// 见 docs/media-protocol.md §5 的降级表。
MediaTransport createTransport(AgentHello hello) {
  return hello.isWebRtc ? WebRtcTransport() : JpegTransport();
}
// 邀请链接:eglan://join/<房间码>?peer=<房主地址>。
// 只承载加入房间所需的两项信息;房间码归一为大写字母数字,地址保持 host:port。
class EgInvite {
  final String code;
  final String? peer;

  const EgInvite({required this.code, this.peer});

  // 从分享文本中找出第一条邀请链接;找不到返回 null。
  static EgInvite? parse(String text) {
    final start = text.toLowerCase().indexOf('eglan://');
    if (start < 0) return null;
    var token = text.substring(start).trim();
    final stop = token.indexOf(RegExp(r'\s'));
    if (stop >= 0) token = token.substring(0, stop);
    token = token.replaceFirst(RegExp(r'[.,;:!?)\]}>，。；：！？）】]+$'), '');

    final Uri uri;
    try {
      uri = Uri.parse(token);
    } catch (_) {
      return null;
    }
    if (uri.scheme.toLowerCase() != 'eglan') return null;
    if (uri.host.toLowerCase() != 'join') return null;
    if (uri.pathSegments.isEmpty) return null;
    final code = normalizeCode(uri.pathSegments.first);
    if (code.length != 8) return null;

    final rawPeer = uri.queryParameters['peer']?.trim();
    final peer = rawPeer != null && rawPeer.isNotEmpty && _validPeer(rawPeer) ? rawPeer : null;
    return EgInvite(code: code, peer: peer);
  }

  static String build(String code, String peer) {
    return 'eglan://join/${normalizeCode(code)}?peer=${Uri.encodeQueryComponent(peer.trim())}';
  }

  // 与核心 room.Normalize 同形:大写,只留 A-Z / 0-9。
  static String normalizeCode(String raw) {
    final b = StringBuffer();
    for (final r in raw.runes) {
      final ch = String.fromCharCode(r).toUpperCase();
      if ((r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        b.write(ch);
      }
    }
    return b.toString();
  }

  static bool _validPeer(String peer) {
    final i = peer.lastIndexOf(':');
    if (i <= 0 || i == peer.length - 1) return false;
    final port = int.tryParse(peer.substring(i + 1));
    if (port == null || port < 1 || port > 65535) return false;
    final host = peer.substring(0, i);
    return host.isNotEmpty && !host.contains(RegExp(r'[/\s]'));
  }
}

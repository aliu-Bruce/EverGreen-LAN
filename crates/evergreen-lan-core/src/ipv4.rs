//! 路由器使用的最小化 IPv4 检查。
//!
//! 路由器从不改写数据包；对每个离开虚拟网卡的数据包，它只需要回答
//! 三个问题：
//!
//! 1. 这是否是可以转发的合法 IPv4 数据包？
//! 2. 它的目的地址是谁？
//! 3. 它属于单播、组播还是广播（因而需要复制）？

/// 不带选项的最小 IPv4 头部长度。
pub const IPV4_MIN_HEADER: usize = 20;

/// Minecraft Java“对局域网开放”广播使用的组播地址。
pub const MINECRAFT_LAN_MULTICAST: [u8; 4] = [224, 0, 2, 60];

/// Minecraft Java 广播局域网游戏的 UDP 端口。
pub const MINECRAFT_LAN_PORT: u16 = 4445;

/// UDP 的协议号。
pub const PROTO_UDP: u8 = 17;

/// TCP 的协议号。
pub const PROTO_TCP: u8 = 6;

/// CIDR 表示法下的 IPv4 子网。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Subnet {
    /// 基地址。无需归一化。
    pub addr: [u8; 4],
    /// 前缀长度（比特），0..=32。
    pub prefix: u8,
}

impl Subnet {
    /// 归一化的网络掩码，例如 `/16` 对应 `255.255.0.0`。
    pub fn mask(&self) -> [u8; 4] {
        let bits = self.prefix.min(32);
        let mask: u32 = if bits == 0 {
            0
        } else {
            u32::MAX << (32 - bits as u32)
        };
        mask.to_be_bytes()
    }

    /// 网络地址（基地址按掩码截取）。
    pub fn network(&self) -> [u8; 4] {
        let a = u32::from_be_bytes(self.addr);
        let m = u32::from_be_bytes(self.mask());
        (a & m).to_be_bytes()
    }

    /// 该子网的定向广播地址。
    pub fn broadcast(&self) -> [u8; 4] {
        let a = u32::from_be_bytes(self.addr);
        let m = u32::from_be_bytes(self.mask());
        (a | !m).to_be_bytes()
    }

    /// `ip` 是否落在该子网内。
    pub fn contains(&self, ip: [u8; 4]) -> bool {
        let a = u32::from_be_bytes(ip);
        let n = u32::from_be_bytes(self.network());
        let m = u32::from_be_bytes(self.mask());
        (a & m) == n
    }

    /// 可用主机地址数；/30 及前缀更短的网段会排除网络地址与广播地址。
    pub fn usable_hosts(&self) -> u32 {
        let bits = self.prefix.min(32);
        let total: u64 = 1u64 << (32 - bits);
        if total <= 2 {
            0
        } else {
            (total - 2).min(u32::MAX as u64) as u32
        }
    }
}

/// IPv4 头部中已解码的子集。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ipv4Header {
    /// 头部长度（字节），包含选项。
    pub header_len: usize,
    /// 总长度字段的值。
    pub total_length: u16,
    /// 载荷承载的协议（6 = TCP，17 = UDP）。
    pub protocol: u8,
    /// 源地址。
    pub src: [u8; 4],
    /// 目的地址。
    pub dst: [u8; 4],
    /// 当该数据包是分片时为真（设置了 MF 位或偏移非零）。
    pub is_fragment: bool,
}

impl Ipv4Header {
    /// 解析 IPv4 头部；对不允许转发的输入返回 `None`。
    pub fn parse(buf: &[u8]) -> Option<Self> {
        if buf.len() < IPV4_MIN_HEADER {
            return None;
        }
        if buf[0] >> 4 != 4 {
            return None;
        }
        let header_len = (buf[0] & 0x0f) as usize * 4;
        if header_len < IPV4_MIN_HEADER || buf.len() < header_len {
            return None;
        }
        let total_length = u16::from_be_bytes([buf[2], buf[3]]);
        if (total_length as usize) < header_len {
            return None;
        }
        let frag = u16::from_be_bytes([buf[6], buf[7]]);
        let more_fragments = frag & 0x2000 != 0;
        let fragment_offset = frag & 0x1fff;
        let mut src = [0u8; 4];
        let mut dst = [0u8; 4];
        src.copy_from_slice(&buf[12..16]);
        dst.copy_from_slice(&buf[16..20]);
        Some(Self {
            header_len,
            total_length,
            protocol: buf[9],
            src,
            dst,
            is_fragment: more_fragments || fragment_offset != 0,
        })
    }

    /// 当数据包为未分片的 UDP 包时，返回其（源、目的）端口。
    pub fn udp_ports(&self, buf: &[u8]) -> Option<(u16, u16)> {
        if self.protocol != PROTO_UDP || self.is_fragment {
            return None;
        }
        let start = self.header_len;
        if buf.len() < start + 8 {
            return None;
        }
        let src = u16::from_be_bytes([buf[start], buf[start + 1]]);
        let dst = u16::from_be_bytes([buf[start + 2], buf[start + 3]]);
        Some((src, dst))
    }
}

/// 路由器应当如何处理某个目的地址。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DestKind {
    /// 恰好一个对端（或本机）。
    Unicast,
    /// 组播组；复制给加入该组的每个对端。
    Multicast,
    /// 复制给每个对端。
    Broadcast,
}

/// `ip` 是否位于 `224.0.0.0/4` 内。
pub fn is_multicast(ip: [u8; 4]) -> bool {
    ip[0] & 0xf0 == 0xe0
}

/// `ip` 是否为 `255.255.255.255`。
pub fn is_limited_broadcast(ip: [u8; 4]) -> bool {
    ip == [255, 255, 255, 255]
}

/// 依据房间的虚拟子网对 `dst` 分类。
pub fn classify(dst: [u8; 4], subnet: &Subnet) -> DestKind {
    if is_limited_broadcast(dst) {
        DestKind::Broadcast
    } else if is_multicast(dst) {
        DestKind::Multicast
    } else if dst == subnet.broadcast() {
        DestKind::Broadcast
    } else {
        DestKind::Unicast
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROOM: Subnet = Subnet {
        addr: [10, 66, 0, 0],
        prefix: 16,
    };

    #[test]
    fn mask_and_broadcast() {
        assert_eq!(ROOM.mask(), [255, 255, 0, 0]);
        assert_eq!(ROOM.network(), [10, 66, 0, 0]);
        assert_eq!(ROOM.broadcast(), [10, 66, 255, 255]);
    }

    #[test]
    fn containment() {
        assert!(ROOM.contains([10, 66, 0, 1]));
        assert!(ROOM.contains([10, 66, 255, 255]));
        assert!(!ROOM.contains([10, 67, 0, 1]));
        assert!(!ROOM.contains([192, 168, 1, 1]));
    }

    #[test]
    fn prefix_zero_and_full() {
        let all = Subnet {
            addr: [1, 2, 3, 4],
            prefix: 0,
        };
        assert_eq!(all.mask(), [0, 0, 0, 0]);
        assert!(all.contains([8, 8, 8, 8]));

        let one = Subnet {
            addr: [10, 66, 0, 7],
            prefix: 32,
        };
        assert_eq!(one.mask(), [255, 255, 255, 255]);
        assert!(one.contains([10, 66, 0, 7]));
        assert!(!one.contains([10, 66, 0, 8]));
    }

    #[test]
    fn classification() {
        assert_eq!(
            classify(MINECRAFT_LAN_MULTICAST, &ROOM),
            DestKind::Multicast
        );
        assert_eq!(classify([10, 66, 255, 255], &ROOM), DestKind::Broadcast);
        assert_eq!(classify([255, 255, 255, 255], &ROOM), DestKind::Broadcast);
        assert_eq!(classify([10, 66, 0, 3], &ROOM), DestKind::Unicast);
        // 其他子网的子网广播并不是*本房间*的广播。
        assert_eq!(classify([10, 67, 255, 255], &ROOM), DestKind::Unicast);
    }

    #[test]
    fn parses_udp_packet() {
        let mut pkt = vec![0u8; 28];
        pkt[0] = 0x45; // IPv4，20 字节头部
        pkt[2..4].copy_from_slice(&28u16.to_be_bytes());
        pkt[9] = PROTO_UDP;
        pkt[12..16].copy_from_slice(&[10, 66, 0, 1]);
        pkt[16..20].copy_from_slice(&MINECRAFT_LAN_MULTICAST);
        pkt[20..22].copy_from_slice(&5555u16.to_be_bytes());
        pkt[22..24].copy_from_slice(&MINECRAFT_LAN_PORT.to_be_bytes());

        let h = Ipv4Header::parse(&pkt).expect("header");
        assert_eq!(h.header_len, 20);
        assert_eq!(h.dst, MINECRAFT_LAN_MULTICAST);
        assert!(!h.is_fragment);
        assert_eq!(h.udp_ports(&pkt), Some((5555, MINECRAFT_LAN_PORT)));
    }

    #[test]
    fn rejects_bad_headers() {
        assert!(Ipv4Header::parse(&[0u8; 19]).is_none());
        let mut v6 = [0u8; 40];
        v6[0] = 0x60;
        assert!(Ipv4Header::parse(&v6).is_none());
        let mut bad_len = [0u8; 20];
        bad_len[0] = 0x45;
        bad_len[2..4].copy_from_slice(&10u16.to_be_bytes());
        assert!(Ipv4Header::parse(&bad_len).is_none());
    }

    #[test]
    fn detects_fragments() {
        let mut pkt = vec![0u8; 20];
        pkt[0] = 0x45;
        pkt[2..4].copy_from_slice(&20u16.to_be_bytes());
        pkt[6..8].copy_from_slice(&0x2000u16.to_be_bytes());
        assert!(Ipv4Header::parse(&pkt).unwrap().is_fragment);

        pkt[6..8].copy_from_slice(&0x0005u16.to_be_bytes());
        assert!(Ipv4Header::parse(&pkt).unwrap().is_fragment);

        pkt[6..8].copy_from_slice(&0u16.to_be_bytes());
        assert!(!Ipv4Header::parse(&pkt).unwrap().is_fragment);
    }
}

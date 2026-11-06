//! 每个穿越虚拟网卡的数据包的转发决策。
//!
//! 保持这部分纯粹且独立于驱动，意味着无需网络适配器或管理员权限
//! 就能对关键场景做单元测试：广播复制、发往自身的数据包、试图逃出
//! 房间的数据包。
//!
//! 这里刻意没有“出口节点”行为：目的地址在 `10.66.0.0/16` 之外的数据包
//! 会被丢弃，绝不转发。EverGreen LAN 是一个局域网，而不是 VPN 网关。

use crate::ipv4::{self, DestKind, Ipv4Header, Subnet};
use crate::TUNNEL_MTU;

/// 对从虚拟网卡读到的数据包应执行的动作。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Routing {
    /// 不向任何地方转发。
    Drop(DropReason),
    /// 复制给房间内的每个对端。
    Broadcast,
    /// 仅发送给一个对端，由其虚拟地址标识。
    ToPeer([u8; 4]),
}

/// 数据包被丢弃的原因。以枚举形式保存，使日志与测试含义明确。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropReason {
    /// 不是可解析的 IPv4 数据包。
    Malformed,
    /// 首部前缀根本不是 IPv4（例如 IPv6 泄漏）。
    NotIpv4,
    /// 超过隧道 MTU，永远无法承载。
    Oversized,
    /// 发往本机；本应由操作系统处理。
    SelfAddressed,
    /// 目的地址位于房间子网之外。
    OutsideSubnet,
}

impl DropReason {
    /// 供日志使用的稳定、人类可读文本。
    pub fn as_str(self) -> &'static str {
        match self {
            DropReason::Malformed => "malformed ipv4",
            DropReason::NotIpv4 => "not ipv4",
            DropReason::Oversized => "oversized for tunnel mtu",
            DropReason::SelfAddressed => "addressed to self",
            DropReason::OutsideSubnet => "outside the virtual subnet",
        }
    }
}

/// 决定出站数据包的去向。
///
/// `self_ip` 是本对端在 `subnet` 内的地址。
pub fn route_outgoing(packet: &[u8], subnet: &Subnet, self_ip: [u8; 4]) -> Routing {
    if packet.len() > TUNNEL_MTU {
        return Routing::Drop(DropReason::Oversized);
    }
    if packet.first().is_some_and(|b| b >> 4 != 4) {
        return Routing::Drop(DropReason::NotIpv4);
    }
    let Some(header) = Ipv4Header::parse(packet) else {
        return Routing::Drop(DropReason::Malformed);
    };

    match ipv4::classify(header.dst, subnet) {
        // 组播（Minecraft 的 224.0.2.60）与两种广播形式都会到达
        // 每个对端，包括未显式订阅的对端。
        DestKind::Broadcast | DestKind::Multicast => Routing::Broadcast,
        DestKind::Unicast => {
            if header.dst == self_ip {
                Routing::Drop(DropReason::SelfAddressed)
            } else if subnet.contains(header.dst) {
                Routing::ToPeer(header.dst)
            } else {
                Routing::Drop(DropReason::OutsideSubnet)
            }
        }
    }
}

/// 判断从对端收到的数据包是否可以写入本地网卡。
///
/// 只接受源地址位于房间内的流量，这阻止对端注入看似来自
/// 互联网的数据包。
pub fn accept_incoming(packet: &[u8], subnet: &Subnet, self_ip: [u8; 4]) -> bool {
    if packet.len() > TUNNEL_MTU {
        return false;
    }
    let Some(header) = Ipv4Header::parse(packet) else {
        return false;
    };
    if !subnet.contains(header.src) {
        return false;
    }
    match ipv4::classify(header.dst, subnet) {
        DestKind::Broadcast | DestKind::Multicast => true,
        DestKind::Unicast => header.dst == self_ip || subnet.contains(header.dst),
    }
}

/// 构造最小化的 IPv4/UDP 数据包，供自检与诊断使用。
///
/// 只填充路由器会检查的字段；这不是通用的数据包构造器。
pub fn synthetic_udp_packet(
    src: [u8; 4],
    dst: [u8; 4],
    src_port: u16,
    dst_port: u16,
    payload: &[u8],
) -> Vec<u8> {
    const IP_HEADER: usize = 20;
    const UDP_HEADER: usize = 8;
    let total = IP_HEADER + UDP_HEADER + payload.len();
    let mut pkt = vec![0u8; total];
    pkt[0] = 0x45;
    pkt[2..4].copy_from_slice(&(total as u16).to_be_bytes());
    pkt[6..8].copy_from_slice(&0x4000u16.to_be_bytes()); // 不分片
    pkt[8] = 64; // TTL（生存时间）
    pkt[9] = ipv4::PROTO_UDP;
    pkt[12..16].copy_from_slice(&src);
    pkt[16..20].copy_from_slice(&dst);
    pkt[IP_HEADER..IP_HEADER + 2].copy_from_slice(&src_port.to_be_bytes());
    pkt[IP_HEADER + 2..IP_HEADER + 4].copy_from_slice(&dst_port.to_be_bytes());
    let udp_len = (UDP_HEADER + payload.len()) as u16;
    pkt[IP_HEADER + 4..IP_HEADER + 6].copy_from_slice(&udp_len.to_be_bytes());
    // 校验和留为 0：路由器中没有任何代码会校验它。
    pkt[IP_HEADER + UDP_HEADER..].copy_from_slice(payload);
    pkt
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::VIRTUAL_SUBNET;

    const SELF: [u8; 4] = [10, 66, 0, 1];

    fn route(dst: [u8; 4]) -> Routing {
        let pkt = synthetic_udp_packet(SELF, dst, 1234, 25565, b"hello");
        route_outgoing(&pkt, &VIRTUAL_SUBNET, SELF)
    }

    #[test]
    fn unicast_to_peer() {
        assert_eq!(route([10, 66, 0, 2]), Routing::ToPeer([10, 66, 0, 2]));
        assert_eq!(route([10, 66, 9, 9]), Routing::ToPeer([10, 66, 9, 9]));
    }

    #[test]
    fn minecraft_discovery_is_broadcast() {
        assert_eq!(route([224, 0, 2, 60]), Routing::Broadcast);
    }

    #[test]
    fn subnet_and_limited_broadcast() {
        assert_eq!(route([10, 66, 255, 255]), Routing::Broadcast);
        assert_eq!(route([255, 255, 255, 255]), Routing::Broadcast);
    }

    #[test]
    fn self_addressed_is_dropped() {
        assert_eq!(route(SELF), Routing::Drop(DropReason::SelfAddressed));
    }

    #[test]
    fn internet_destinations_are_dropped() {
        assert_eq!(
            route([8, 8, 8, 8]),
            Routing::Drop(DropReason::OutsideSubnet)
        );
        assert_eq!(
            route([192, 168, 1, 1]),
            Routing::Drop(DropReason::OutsideSubnet)
        );
    }

    #[test]
    fn malformed_and_oversized_are_dropped() {
        assert_eq!(
            route_outgoing(&[], &VIRTUAL_SUBNET, SELF),
            Routing::Drop(DropReason::Malformed)
        );
        assert_eq!(
            route_outgoing(&[0x45; 10], &VIRTUAL_SUBNET, SELF),
            Routing::Drop(DropReason::Malformed)
        );
        let oversized = vec![0x45u8; TUNNEL_MTU + 1];
        assert_eq!(
            route_outgoing(&oversized, &VIRTUAL_SUBNET, SELF),
            Routing::Drop(DropReason::Oversized)
        );
    }

    #[test]
    fn ipv6_is_rejected() {
        let mut pkt = vec![0u8; 40];
        pkt[0] = 0x60;
        assert_eq!(
            route_outgoing(&pkt, &VIRTUAL_SUBNET, SELF),
            Routing::Drop(DropReason::NotIpv4)
        );
    }

    #[test]
    fn incoming_from_room_is_accepted() {
        let pkt = synthetic_udp_packet([10, 66, 0, 2], SELF, 25565, 50000, b"hi");
        assert!(accept_incoming(&pkt, &VIRTUAL_SUBNET, SELF));
    }

    #[test]
    fn incoming_broadcast_from_room_is_accepted() {
        let pkt = synthetic_udp_packet(
            [10, 66, 0, 2],
            [224, 0, 2, 60],
            4445,
            4445,
            b"[MOTD]x[/MOTD]",
        );
        assert!(accept_incoming(&pkt, &VIRTUAL_SUBNET, SELF));
    }

    #[test]
    fn incoming_from_outside_room_is_rejected() {
        let spoofed = synthetic_udp_packet([8, 8, 8, 8], SELF, 1, 2, b"x");
        assert!(!accept_incoming(&spoofed, &VIRTUAL_SUBNET, SELF));

        let broken = vec![0u8; 8];
        assert!(!accept_incoming(&broken, &VIRTUAL_SUBNET, SELF));
    }

    #[test]
    fn synthetic_packet_is_well_formed() {
        let pkt = synthetic_udp_packet(SELF, [10, 66, 0, 2], 100, 200, b"abc");
        assert_eq!(pkt.len(), 20 + 8 + 3);
        let header = Ipv4Header::parse(&pkt).expect("parseable");
        assert_eq!(header.udp_ports(&pkt), Some((100, 200)));
        assert_eq!(header.total_length as usize, pkt.len());
    }
}

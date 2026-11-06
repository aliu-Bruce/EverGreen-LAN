//! EverGreen LAN 协议核心。
//!
//! 本 crate 与 UI 和操作系统无关。它包含描述房间（[`invite`]）、分类流量
//! （[`ipv4`]）、发现公网端点（[`stun`]）、认证对端（[`handshake`]）
//! 以及承载加密数据报（[`frame`]、[`session`]）所需的全部内容。
//!
//! 数据面严格点对点：没有中继、没有 rendezvous、没有厂商服务器。
//! 房间的加入通过带外交换 [`InviteCode`] 完成。

pub mod error;
pub mod frame;
pub mod handshake;
pub mod invite;
pub mod ipv4;
pub mod router;
pub mod session;
pub mod stun;
pub mod tunnel;

pub use error::{Error, Result};
pub use invite::InviteCode;
pub use ipv4::{DestKind, Ipv4Header, Subnet};
pub use session::PeerSession;

/// 每个 EverGreen LAN 房间使用的虚拟网段：`10.66.0.0/16`。
///
/// 主机始终占用 `10.66.0.1`；访客从 `10.66.0.2` 开始依次分配。
/// 因此该子网的广播地址是 `10.66.255.255`。
pub const VIRTUAL_SUBNET: Subnet = Subnet {
    addr: [10, 66, 0, 0],
    prefix: 16,
};

/// [`VIRTUAL_SUBNET`] 内主机的虚拟地址。
pub const HOST_VIRTUAL_IP: [u8; 4] = [10, 66, 0, 1];

/// 单条隧道数据报承载的最大载荷。
///
/// 该值保持在 IPv6 最小 MTU 以下，以便隧道能穿过 MTU 异常的网络路径。
/// 虚拟网卡配置为相同的值。
pub const TUNNEL_MTU: usize = 1200;

/// 重新导出，使下游 crate 无需自行固定 `snow` 版本。
pub use snow;

//! EverGreen LAN 的房间运行时。
//!
//! 本 crate 是操作系统与协议之间的接缝：
//!
//! ```text
//!   操作系统网络栈
//!         │  （原始 IPv4 数据包）
//!   ┌─────▼─────┐        ┌──────────────┐        ┌──────────┐
//!   │  Wintun   │◀──────▶│     hub      │◀──────▶│   UDP    │
//!   └───────────┘        │  （本 crate）│        └──────────┘
//!                        └──────────────┘
//! ```
//!
//! hub 是一个拥有全部 peer 会话的单一异步任务。相对于这些会话，
//! 它严格保持单线程，这正是 Noise 传输层（以及 Wintun 的
//! 接收契约）所要求的。
//!
//! [`Room`] 是公开句柄：创建它、读取其邀请码、轮询其 peer
//! 列表，丢弃它即可拆除全部资源。

pub mod device;
pub mod room;
pub mod testing;

pub use device::DeviceChannels;
pub use room::{PeerInfo, Room, RoomConfig, RoomError, RoomEvent};

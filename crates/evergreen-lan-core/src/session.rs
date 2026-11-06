//! 与单个对端建立的加密会话。
//!
//! [`PeerSession`] 封装一个 Noise [`TransportState`] 以及路由器所需的元数据：
//! 对端的 UDP 地址、静态密钥、虚拟 IP 和存活计数。它刻意保持同步——
//! 异步套接字泵位于 [`crate::tunnel`] 和桌面应用中。

use std::net::SocketAddr;
use std::time::{Duration, Instant};

use snow::TransportState;

use crate::frame::Frame;
use crate::handshake::{Role, TAG_LEN};
use crate::{Error, Result};

/// 从网络接受的最大密文数据报长度。
///
/// [`crate::TUNNEL_MTU`] 大小的数据包，加上一个标签字节与 Noise
/// 认证标签，仍能轻松容纳。
pub const MAX_DATAGRAM: usize = 1500;

/// 一个已认证的对端连接。
pub struct PeerSession {
    transport: TransportState,
    /// 可到达对端的 UDP 地址。
    pub remote_addr: SocketAddr,
    /// 对端的静态 X25519 公钥。
    pub remote_static: [u8; 32],
    /// 对端在虚拟子网内持有的地址，已知后填入。
    pub virtual_ip: Option<[u8; 4]>,
    /// 对端声明的显示名称。
    pub name: String,
    /// 对端声明的角色。
    pub role: Role,
    /// 会话完成握手的时间。
    pub established_at: Instant,
    /// 最近一次收到有效数据报的时间。
    pub last_recv_at: Instant,
    /// 累计接收的明文字节数。
    pub bytes_in: u64,
    /// 累计发送的明文字节数。
    pub bytes_out: u64,
    /// 最近一次测得的往返时延。
    pub rtt: Option<Duration>,
    pending_ping: Option<(u64, Instant)>,
    next_ping_seq: u64,
}

impl PeerSession {
    /// 封装一个已完成的 Noise 传输状态。
    pub fn new(
        transport: TransportState,
        remote_addr: SocketAddr,
        remote_static: [u8; 32],
    ) -> Self {
        let now = Instant::now();
        Self {
            transport,
            remote_addr,
            remote_static,
            virtual_ip: None,
            name: String::new(),
            role: Role::Guest,
            established_at: now,
            last_recv_at: now,
            bytes_in: 0,
            bytes_out: 0,
            rtt: None,
            pending_ping: None,
            next_ping_seq: 1,
        }
    }

    /// 将帧加密为可直接发送的数据报。
    pub fn seal(&mut self, frame: &Frame) -> Result<Vec<u8>> {
        let plaintext = frame.encode()?;
        let mut out = vec![0u8; plaintext.len() + TAG_LEN];
        let n = self.transport.write_message(&plaintext, &mut out)?;
        out.truncate(n);
        self.bytes_out += plaintext.len() as u64;
        Ok(out)
    }

    /// 将收到的数据报解密为帧。
    pub fn open(&mut self, datagram: &[u8]) -> Result<Frame> {
        if datagram.is_empty() || datagram.len() > MAX_DATAGRAM {
            return Err(Error::Protocol(format!(
                "datagram length {} out of range",
                datagram.len()
            )));
        }
        if datagram.len() <= TAG_LEN {
            return Err(Error::Protocol("datagram is shorter than the tag".into()));
        }
        let mut plaintext = vec![0u8; datagram.len()];
        let n = self.transport.read_message(datagram, &mut plaintext)?;
        plaintext.truncate(n);
        let frame = Frame::decode(&plaintext)?;
        self.last_recv_at = Instant::now();
        self.bytes_in += n as u64;
        Ok(frame)
    }

    /// 构造下一个 ping 帧并记录发送时刻。
    pub fn begin_ping(&mut self) -> Frame {
        let seq = self.next_ping_seq;
        self.next_ping_seq = self.next_ping_seq.wrapping_add(1);
        self.pending_ping = Some((seq, Instant::now()));
        Frame::Ping(seq)
    }

    /// 记录 pong 并更新往返时延估计。
    ///
    /// 当序列号与当前尚未完成的 ping 匹配时，返回测得的 RTT。
    pub fn handle_pong(&mut self, seq: u64) -> Option<Duration> {
        let (pending_seq, sent_at) = self.pending_ping?;
        if pending_seq != seq {
            return None;
        }
        let rtt = sent_at.elapsed();
        self.pending_ping = None;
        self.rtt = Some(rtt);
        Some(rtt)
    }

    /// 是否已连续 `idle` 时长没有收到该对端的任何消息。
    pub fn is_idle(&self, idle: Duration) -> bool {
        self.last_recv_at.elapsed() > idle
    }

    /// 便捷方法：封装一个 IP 数据包帧。
    pub fn send_ip(&mut self, packet: &[u8]) -> Result<Vec<u8>> {
        self.seal(&Frame::Ip(packet.to_vec()))
    }

    /// 便捷方法：构造一个告别帧。
    pub fn goodbye(&mut self, reason: &str) -> Result<Vec<u8>> {
        self.seal(&Frame::Bye(reason.to_string()))
    }
}

impl std::fmt::Debug for PeerSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PeerSession")
            .field("remote_addr", &self.remote_addr)
            .field("virtual_ip", &self.virtual_ip)
            .field("name", &self.name)
            .field("role", &self.role)
            .field("rtt", &self.rtt)
            .field("bytes_in", &self.bytes_in)
            .field("bytes_out", &self.bytes_out)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handshake::{Handshake, StaticIdentity, KEY_LEN};

    fn session_pair() -> (PeerSession, PeerSession) {
        let host_id = StaticIdentity::generate().unwrap();
        let guest_id = StaticIdentity::generate().unwrap();
        let psk = [11u8; KEY_LEN];
        let room = [12u8; 16];

        let mut host = Handshake::host(&host_id, &psk, &room).unwrap();
        let mut guest = Handshake::guest(&guest_id, &host_id.public_bytes(), &psk, &room).unwrap();

        let m1 = guest.write_message().unwrap();
        host.read_message(&m1).unwrap();
        let m2 = host.write_message().unwrap();
        guest.read_message(&m2).unwrap();

        let host_addr: SocketAddr = "10.66.0.1:4433".parse().unwrap();
        let guest_addr: SocketAddr = "192.168.1.9:5544".parse().unwrap();

        let hs = PeerSession::new(
            host.into_transport().unwrap(),
            guest_addr,
            guest_id.public_bytes(),
        );
        let gs = PeerSession::new(
            guest.into_transport().unwrap(),
            host_addr,
            host_id.public_bytes(),
        );
        (hs, gs)
    }

    #[test]
    fn frames_survive_the_tunnel() {
        let (mut host, mut guest) = session_pair();

        let d = guest
            .seal(&Frame::Hello {
                ip: [10, 66, 0, 2],
                role: Role::Guest,
                name: "Alice".into(),
            })
            .unwrap();
        let f = host.open(&d).unwrap();
        assert!(matches!(f, Frame::Hello { .. }));

        let reply = host
            .seal(&Frame::HelloAck {
                ip: [10, 66, 0, 2],
                name: "Bob".into(),
            })
            .unwrap();
        assert_eq!(
            guest.open(&reply).unwrap(),
            Frame::HelloAck {
                ip: [10, 66, 0, 2],
                name: "Bob".into()
            }
        );

        assert!(host.bytes_in > 0);
        assert!(guest.bytes_out > 0);
    }

    #[test]
    fn ip_packets_roundtrip() {
        let (mut host, mut guest) = session_pair();
        let packet = vec![0x45u8; 1200];
        let d = guest.send_ip(&packet).unwrap();
        match host.open(&d).unwrap() {
            Frame::Ip(p) => assert_eq!(p, packet),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn replay_is_rejected() {
        let (mut host, mut guest) = session_pair();
        let d = guest.seal(&Frame::Ping(1)).unwrap();
        assert!(host.open(&d).is_ok());
        assert!(host.open(&d).is_err(), "replayed datagram must fail");
    }

    #[test]
    fn short_datagrams_are_rejected() {
        let (mut host, _guest) = session_pair();
        assert!(host.open(&[]).is_err());
        assert!(host.open(&[0u8; 4]).is_err());
        assert!(host.open(&vec![0u8; MAX_DATAGRAM + 1]).is_err());
    }

    #[test]
    fn ping_pong_measures_rtt() {
        let (mut host, mut guest) = session_pair();
        let ping = guest.begin_ping();
        let seq = match ping {
            Frame::Ping(s) => s,
            other => panic!("unexpected {other:?}"),
        };
        let d = guest.seal(&ping).unwrap();
        let received = host.open(&d).unwrap();
        assert_eq!(received, Frame::Ping(seq));

        let pong = host.seal(&Frame::Pong(seq)).unwrap();
        assert_eq!(guest.open(&pong).unwrap(), Frame::Pong(seq));

        let rtt = guest.handle_pong(seq).expect("rtt recorded");
        assert!(rtt < Duration::from_secs(1));
        assert!(guest.rtt.is_some());
        // 同一序列号的第二次 pong 已没有待完成的 ping。
        assert!(guest.handle_pong(seq).is_none());
    }

    #[test]
    fn idle_detection() {
        let (host, _guest) = session_pair();
        assert!(!host.is_idle(Duration::from_secs(60)));
        assert!(host.is_idle(Duration::from_nanos(1)));
    }
}

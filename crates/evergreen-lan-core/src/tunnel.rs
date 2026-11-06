//! 在真实 UDP 套接字上驱动握手。
//!
//! `Noise_IK` 是两条消息的模式，因此会话在主机回复后即建立——只有一个
//! 往返。本模块增加了重传、候选地址竞速，以及对 Windows 在对端未监听时
//! 抛出的 ICMP 错误的容忍。
//!
//! 两个方向都是保守的：游离的数据报可以浪费一次尝试，但绝不可能推进
//! 握手，因为每条消息都经过认证。

use std::io::ErrorKind;
use std::net::SocketAddr;
use std::time::Duration;

use tokio::net::UdpSocket;

use crate::handshake::{Handshake, StaticIdentity, KEY_LEN};
use crate::session::PeerSession;
use crate::{Error, Result};

/// 重发消息 1 之前等待回复的时长。
pub const DIAL_ATTEMPT_TIMEOUT: Duration = Duration::from_millis(300);

/// 竞速候选地址期间重发消息 1 的次数。
pub const DIAL_ATTEMPTS: usize = 10;

/// 主机回送消息 2 的份数。
pub const HANDSHAKE_RESPONSE_WRITES: usize = 3;

/// 一次完成的拨号：会话以及实际给出应答的端点。
#[derive(Debug)]
pub struct Connected {
    /// 已建立的加密会话。
    pub session: PeerSession,
    /// 做出应答的候选端点。
    pub endpoint: SocketAddr,
}

/// Windows 会把 ICMP“端口不可达”报告为*下一次*接收时的错误。
/// 一个失效的候选地址不应中止整个拨号，因此这类错误被当作
/// “暂时没有结果”并重试。
fn is_soft_network_error(e: &std::io::Error) -> bool {
    matches!(
        e.kind(),
        ErrorKind::ConnectionReset
            | ErrorKind::ConnectionRefused
            | ErrorKind::TimedOut
            | ErrorKind::WouldBlock
    ) || matches!(
        e.raw_os_error(),
        // WSAECONNRESET、WSAECONNREFUSED、WSAEHOSTUNREACH、WSAENETUNREACH 等错误码
        Some(10054) | Some(10061) | Some(10065) | Some(10051)
    )
}

/// 拨号到主机，同时竞速所有候选端点。
///
/// 消息 1 同时发往全部候选地址；第一条通过认证的应答获胜。
/// 这正是打洞能够成功的原因：两个 NAT 同时看到出站流量。
pub async fn dial(
    socket: &UdpSocket,
    endpoints: &[SocketAddr],
    identity: &StaticIdentity,
    host_pub: &[u8; KEY_LEN],
    psk: &[u8; KEY_LEN],
    room_id: &[u8; 16],
) -> Result<Connected> {
    if endpoints.is_empty() {
        return Err(Error::Protocol("no candidate endpoints to dial".into()));
    }

    let mut buf = vec![0u8; 2048];
    let mut accepted: Option<SocketAddr> = None;
    let mut handshake: Option<Handshake> = None;

    'attempts: for _ in 0..DIAL_ATTEMPTS {
        // 每次尝试都用新的临时密钥，保持状态机干净。
        let mut hs = Handshake::guest(identity, host_pub, psk, room_id)?;
        let m1 = hs.write_message()?;
        for ep in endpoints {
            let _ = socket.send_to(&m1, ep).await;
        }

        let deadline = tokio::time::Instant::now() + DIAL_ATTEMPT_TIMEOUT;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            match tokio::time::timeout(remaining, socket.recv_from(&mut buf)).await {
                Ok(Ok((n, from))) => {
                    if !endpoints.iter().any(|e| e.ip() == from.ip()) {
                        tracing::trace!(%from, "忽略来自非预期主机的握手回复");
                        continue;
                    }
                    if hs.read_message(&buf[..n]).is_ok() {
                        handshake = Some(hs);
                        accepted = Some(from);
                        break 'attempts;
                    }
                    tracing::trace!(%from, "握手回复未通过认证");
                }
                Ok(Err(e)) if is_soft_network_error(&e) => break,
                Ok(Err(e)) => return Err(Error::Io(e)),
                Err(_) => break,
            }
        }
    }

    let endpoint = accepted.ok_or(Error::Timeout)?;
    let hs = handshake.ok_or(Error::Timeout)?;
    let remote_static = hs
        .remote_static()
        .ok_or_else(|| Error::Protocol("host key missing after handshake".into()))?;
    let transport = hs.into_transport()?;

    tracing::debug!(%endpoint, "已作为访客完成握手");
    Ok(Connected {
        session: PeerSession::new(transport, endpoint, remote_static),
        endpoint,
    })
}

/// 等待恰好一个访客完成握手。
///
/// 返回已建立的会话。是否保留该访客由调用方决定，确认可达性的
/// `Hello` 交换也由调用方负责。
pub async fn accept(
    socket: &UdpSocket,
    identity: &StaticIdentity,
    psk: &[u8; KEY_LEN],
    room_id: &[u8; 16],
) -> Result<PeerSession> {
    let mut buf = vec![0u8; 2048];
    let mut rejected: u64 = 0;

    loop {
        let (n, from) = match socket.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(e) if is_soft_network_error(&e) => continue,
            Err(e) => return Err(Error::Io(e)),
        };

        let mut hs = Handshake::host(identity, psk, room_id)?;
        if hs.read_message(&buf[..n]).is_err() {
            rejected += 1;
            tracing::trace!(%from, rejected, "该数据报不是有效的握手消息");
            continue;
        }

        let m2 = hs.write_message()?;
        for _ in 0..HANDSHAKE_RESPONSE_WRITES {
            let _ = socket.send_to(&m2, from).await;
        }

        let remote_static = hs
            .remote_static()
            .ok_or_else(|| Error::Protocol("guest key missing after handshake".into()))?;
        let transport = hs.into_transport()?;

        tracing::debug!(%from, "已作为主机完成握手");
        return Ok(PeerSession::new(transport, from, remote_static));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::Frame;
    use crate::handshake::Role;

    fn ids() -> (StaticIdentity, StaticIdentity, [u8; KEY_LEN], [u8; 16]) {
        (
            StaticIdentity::generate().unwrap(),
            StaticIdentity::generate().unwrap(),
            [21u8; KEY_LEN],
            [22u8; 16],
        )
    }

    #[tokio::test]
    async fn handshake_and_frame_exchange_over_udp() {
        let host_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let guest_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let host_addr = host_sock.local_addr().unwrap();

        let (host_id, guest_id, psk, room) = ids();
        let host_pub = host_id.public_bytes();
        let endpoints = [host_addr];

        let (host_res, guest_res) = tokio::join!(
            accept(&host_sock, &host_id, &psk, &room),
            dial(&guest_sock, &endpoints, &guest_id, &host_pub, &psk, &room),
        );

        let mut host = host_res.expect("host accepted");
        let guest_conn = guest_res.expect("guest dialled");
        assert_eq!(guest_conn.endpoint.ip(), host_addr.ip());
        assert_eq!(host.remote_static, guest_id.public_bytes());

        let mut guest = guest_conn.session;
        assert_eq!(guest.remote_static, host_pub);

        let d = guest
            .seal(&Frame::Hello {
                ip: [10, 66, 0, 2],
                role: Role::Guest,
                name: "Alice".into(),
            })
            .unwrap();
        match host.open(&d).unwrap() {
            Frame::Hello { name, role, .. } => {
                assert_eq!(name, "Alice");
                assert_eq!(role, Role::Guest);
            }
            other => panic!("unexpected frame {other:?}"),
        }

        let ack = host
            .seal(&Frame::HelloAck {
                ip: [10, 66, 0, 2],
                name: "Bob".into(),
            })
            .unwrap();
        assert!(matches!(guest.open(&ack).unwrap(), Frame::HelloAck { .. }));
    }

    #[tokio::test]
    async fn accept_ignores_garbage() {
        let host_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let guest_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let noise_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let host_addr = host_sock.local_addr().unwrap();

        // 垃圾数据在真正的握手之前到达，必须被跳过。
        noise_sock
            .send_to(b"garbage that is not noise", host_addr)
            .await
            .unwrap();
        noise_sock.send_to(&[0u8; 60], host_addr).await.unwrap();

        let (host_id, guest_id, psk, room) = ids();
        let host_pub = host_id.public_bytes();
        let endpoints = [host_addr];

        let (host_res, guest_res) = tokio::join!(
            accept(&host_sock, &host_id, &psk, &room),
            dial(&guest_sock, &endpoints, &guest_id, &host_pub, &psk, &room),
        );

        assert!(host_res.is_ok());
        assert!(guest_res.is_ok());
    }

    #[tokio::test]
    async fn dial_without_listener_times_out() {
        let sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let idle = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let target = idle.local_addr().unwrap();
        drop(idle);

        let (host_id, guest_id, psk, room) = ids();
        let result = dial(
            &sock,
            &[target],
            &guest_id,
            &host_id.public_bytes(),
            &psk,
            &room,
        )
        .await;
        assert!(
            matches!(result, Err(Error::Timeout)),
            "expected timeout, got {result:?}"
        );
    }

    #[tokio::test]
    async fn dial_rejects_wrong_secret() {
        let host_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let guest_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let host_addr = host_sock.local_addr().unwrap();

        let (host_id, guest_id, _psk, room) = ids();
        let host_pub = host_id.public_bytes();

        let wrong = [99u8; KEY_LEN];
        let host_psk = [21u8; KEY_LEN];
        let endpoints = [host_addr];
        let (host_res, guest_res) = tokio::join!(
            tokio::time::timeout(
                Duration::from_millis(1200),
                accept(&host_sock, &host_id, &host_psk, &room),
            ),
            dial(&guest_sock, &endpoints, &guest_id, &host_pub, &wrong, &room),
        );

        assert!(guest_res.is_err(), "guest must not authenticate");
        // 主机始终没有收到合法的消息 1，因此 `accept` 继续等待。
        assert!(host_res.is_err(), "host must not establish a session");
    }

    #[test]
    fn soft_errors_are_classified() {
        assert!(is_soft_network_error(&std::io::Error::from(
            ErrorKind::ConnectionReset
        )));
        assert!(is_soft_network_error(&std::io::Error::from_raw_os_error(
            10054
        )));
        assert!(!is_soft_network_error(&std::io::Error::from(
            ErrorKind::PermissionDenied
        )));
    }
}

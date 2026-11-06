//! 仅用于端点发现的最小 STUN 客户端（RFC 5389）。
//!
//! STUN 只回答一个问题：公网看到的地址是什么？查询公共 STUN 服务器时
//! 使用隧道所用的*同一个套接字*，因此学到的映射就是对端必须拨号的映射。
//! 媒体流量和中继流量从不经过 STUN；它只用于发现，并且可以在 UI 中禁用。

use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4};
use std::time::Duration;

use rand::RngCore;
use tokio::net::UdpSocket;

use crate::{Error, Result};

/// STUN magic cookie 常量。
pub const MAGIC_COOKIE: u32 = 0x2112_A442;

const TYPE_BINDING_REQUEST: u16 = 0x0001;
const TYPE_BINDING_SUCCESS: u16 = 0x0101;
const ATTR_MAPPED_ADDRESS: u16 = 0x0001;
const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;
const ATTR_ERROR_CODE: u16 = 0x0009;

/// 默认尝试的公共 STUN 服务器。
///
/// 它们仅用于获知本地的公网端点。它们属于普通的公共基础设施，
/// 并非 EverGreen LAN 的一部分，且该列表可配置（也可以为空）。
pub const DEFAULT_STUN_SERVERS: &[&str] = &[
    "stun.l.google.com:19302",
    "stun1.l.google.com:19302",
    "stun.cloudflare.com:3478",
];

/// 用给定事务 id 构造 STUN binding 请求。
pub fn binding_request(txid: [u8; 12]) -> Vec<u8> {
    let mut out = Vec::with_capacity(20);
    out.extend_from_slice(&TYPE_BINDING_REQUEST.to_be_bytes());
    out.extend_from_slice(&0u16.to_be_bytes());
    out.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
    out.extend_from_slice(&txid);
    out
}

/// 解析 STUN binding 响应，并校验事务 id。
pub fn parse_response(buf: &[u8], txid: &[u8; 12]) -> Result<SocketAddr> {
    if buf.len() < 20 {
        return Err(Error::Protocol("stun response shorter than header".into()));
    }
    let msg_type = u16::from_be_bytes([buf[0], buf[1]]);
    let msg_len = u16::from_be_bytes([buf[2], buf[3]]) as usize;
    let cookie = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
    if cookie != MAGIC_COOKIE {
        return Err(Error::Protocol("stun magic cookie mismatch".into()));
    }
    if &buf[8..20] != txid {
        return Err(Error::Protocol("stun transaction id mismatch".into()));
    }
    if msg_type != TYPE_BINDING_SUCCESS {
        return Err(Error::Protocol(format!(
            "stun response has type {msg_type:#06x}"
        )));
    }
    let end = 20usize.saturating_add(msg_len).min(buf.len());

    let mut offset = 20usize;
    let mut mapped: Option<SocketAddr> = None;
    let mut error_code: Option<(u8, String)> = None;

    while offset + 4 <= end {
        let attr_type = u16::from_be_bytes([buf[offset], buf[offset + 1]]);
        let attr_len = u16::from_be_bytes([buf[offset + 2], buf[offset + 3]]) as usize;
        offset += 4;
        if offset + attr_len > end {
            break;
        }
        let value = &buf[offset..offset + attr_len];
        match attr_type {
            ATTR_XOR_MAPPED_ADDRESS => {
                if let Some(addr) = decode_mapped(value, Some(MAGIC_COOKIE)) {
                    mapped.get_or_insert(addr);
                }
            }
            ATTR_MAPPED_ADDRESS => {
                if let Some(addr) = decode_mapped(value, None) {
                    mapped.get_or_insert(addr);
                }
            }
            ATTR_ERROR_CODE if value.len() >= 4 => {
                let class = value[2] & 0x07;
                let number = value[3];
                error_code = Some((
                    class * 100 + number,
                    String::from_utf8_lossy(&value[4..]).into_owned(),
                ));
            }
            _ => {}
        }
        // 属性按 4 字节边界填充。
        offset += attr_len + ((4 - attr_len % 4) % 4);
    }

    if let Some(addr) = mapped {
        return Ok(addr);
    }
    if let Some((code, reason)) = error_code {
        return Err(Error::Protocol(format!("stun error {code}: {reason}")));
    }
    Err(Error::Protocol(
        "stun response had no mapped address".into(),
    ))
}

fn decode_mapped(value: &[u8], xor: Option<u32>) -> Option<SocketAddr> {
    if value.len() < 8 {
        return None;
    }
    if value[0] != 0 {
        return None;
    }
    let family = value[1];
    let mut port = u16::from_be_bytes([value[2], value[3]]);
    let mut octets = [value[4], value[5], value[6], value[7]];
    if let Some(cookie) = xor {
        port ^= (cookie >> 16) as u16;
        let cookie_bytes = cookie.to_be_bytes();
        for i in 0..4 {
            octets[i] ^= cookie_bytes[i];
        }
    }
    if family != 0x01 {
        // 这个 IPv4 覆盖网络不使用 IPv6 映射。
        return None;
    }
    Some(SocketAddr::V4(SocketAddrV4::new(
        Ipv4Addr::new(octets[0], octets[1], octets[2], octets[3]),
        port,
    )))
}

/// 向单个 STUN 服务器询问 `socket` 的映射地址。
pub async fn discover_on(
    socket: &UdpSocket,
    server: SocketAddr,
    timeout: Duration,
) -> Result<SocketAddr> {
    let mut txid = [0u8; 12];
    rand::thread_rng().fill_bytes(&mut txid);
    let request = binding_request(txid);
    socket.send_to(&request, server).await?;

    let mut buf = [0u8; 1500];
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(Error::Timeout);
        }
        match tokio::time::timeout(remaining, socket.recv_from(&mut buf)).await {
            Ok(Ok((n, from))) => {
                if from.ip() != server.ip() && from != server {
                    continue;
                }
                if let Ok(addr) = parse_response(&buf[..n], &txid) {
                    return Ok(addr);
                }
            }
            Ok(Err(e)) => return Err(Error::Io(e)),
            Err(_) => return Err(Error::Timeout),
        }
    }
}

/// 解析地址并查询多个 STUN 服务器，返回所有给出应答的映射。
///
/// 两个或更多相同的映射意味着 NAT 与端点无关，这是直连能够成功的
/// 强信号。
pub async fn discover(socket: &UdpSocket, servers: &[&str], timeout: Duration) -> Vec<SocketAddr> {
    let mut results = Vec::new();
    for server in servers {
        let resolved: Vec<SocketAddr> = match tokio::net::lookup_host(server).await {
            Ok(iter) => iter.filter(|a| a.is_ipv4()).collect(),
            Err(_) => continue,
        };
        let Some(addr) = resolved.into_iter().next() else {
            continue;
        };
        if let Ok(mapped) = discover_on(socket, addr, timeout).await {
            if !results.contains(&mapped) {
                results.push(mapped);
            }
        }
    }
    results
}

/// 基于 STUN 观测结果推测的 NAT 穿透行为。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NatHint {
    /// 没有 STUN 服务器应答；此时只有本地候选端点。
    Unknown,
    /// 每个服务器报告的映射都相同：直连很可能成功。
    EndpointIndependent,
    /// 不同服务器给出的映射不同：可能需要端口预测。
    AddressDependent,
}

/// 依据 [`discover`] 返回的映射对 NAT 分类。
pub fn classify(mappings: &[SocketAddr]) -> NatHint {
    match mappings.len() {
        0 => NatHint::Unknown,
        1 => NatHint::Unknown,
        _ => {
            if mappings.windows(2).all(|w| w[0] == w[1]) {
                NatHint::EndpointIndependent
            } else {
                NatHint::AddressDependent
            }
        }
    }
}

/// 供 UI 使用的便捷判断：该地址是否为真正的公网地址？
pub fn is_routable(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            !(v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_unspecified()
                || v4.is_documentation()
                || is_cgnat(Ipv4Addr::from(v4)))
        }
        IpAddr::V6(_) => false,
    }
}

/// 是否属于运营商级 NAT 的共享地址段 `100.64.0.0/10`。
///
/// 手机热点、部分宽带都会把用户放在这一层。地址看起来是公网，但运营商的
/// NAT 既不转发入站，也不保证端点可预测，因此打洞基本不可能成功。
/// 把它单独识别出来，才能在界面上给出准确的原因。
pub fn is_cgnat(ip: Ipv4Addr) -> bool {
    let [first, second, ..] = ip.octets();
    first == 100 && (64..128).contains(&second)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn success_response(
        txid: [u8; 12],
        xor: Option<SocketAddrV4>,
        plain: Option<SocketAddrV4>,
    ) -> Vec<u8> {
        let mut attrs = Vec::new();
        if let Some(addr) = xor {
            let port = addr.port() ^ (MAGIC_COOKIE >> 16) as u16;
            let ip = u32::from(*addr.ip()) ^ MAGIC_COOKIE;
            let mut v = vec![0u8, 0x01];
            v.extend_from_slice(&port.to_be_bytes());
            v.extend_from_slice(&ip.to_be_bytes());
            attrs.extend_from_slice(&ATTR_XOR_MAPPED_ADDRESS.to_be_bytes());
            attrs.extend_from_slice(&(v.len() as u16).to_be_bytes());
            attrs.extend_from_slice(&v);
        }
        if let Some(addr) = plain {
            let mut v = vec![0u8, 0x01];
            v.extend_from_slice(&addr.port().to_be_bytes());
            v.extend_from_slice(&addr.ip().octets());
            attrs.extend_from_slice(&ATTR_MAPPED_ADDRESS.to_be_bytes());
            attrs.extend_from_slice(&(v.len() as u16).to_be_bytes());
            attrs.extend_from_slice(&v);
        }
        let mut out = Vec::new();
        out.extend_from_slice(&TYPE_BINDING_SUCCESS.to_be_bytes());
        out.extend_from_slice(&(attrs.len() as u16).to_be_bytes());
        out.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
        out.extend_from_slice(&txid);
        out.extend_from_slice(&attrs);
        out
    }

    #[test]
    fn request_layout() {
        let req = binding_request([1u8; 12]);
        assert_eq!(req.len(), 20);
        assert_eq!(&req[0..2], &[0x00, 0x01]);
        assert_eq!(&req[2..4], &[0x00, 0x00]);
        assert_eq!(&req[4..8], &MAGIC_COOKIE.to_be_bytes());
        assert_eq!(&req[8..20], &[1u8; 12]);
    }

    #[test]
    fn cgnat_is_not_routable() {
        use std::net::Ipv4Addr as V4;
        assert!(is_cgnat(V4::new(100, 64, 0, 1)));
        assert!(is_cgnat(V4::new(100, 127, 255, 254)));
        assert!(!is_cgnat(V4::new(100, 63, 0, 1)));
        assert!(!is_cgnat(V4::new(100, 128, 0, 1)));
        assert!(!is_routable("100.64.1.2".parse().unwrap()));
        assert!(is_routable("114.114.114.114".parse().unwrap()));
    }

    #[test]
    fn parses_xor_mapped_address() {
        let txid = [9u8; 12];
        let expected: SocketAddrV4 = "203.0.113.7:41234".parse().unwrap();
        let resp = success_response(txid, Some(expected), None);
        assert_eq!(
            parse_response(&resp, &txid).unwrap(),
            SocketAddr::V4(expected)
        );
    }

    #[test]
    fn parses_plain_mapped_address() {
        let txid = [3u8; 12];
        let expected: SocketAddrV4 = "198.51.100.4:1234".parse().unwrap();
        let resp = success_response(txid, None, Some(expected));
        assert_eq!(
            parse_response(&resp, &txid).unwrap(),
            SocketAddr::V4(expected)
        );
    }

    #[test]
    fn prefers_xor_over_plain() {
        let txid = [4u8; 12];
        let xor_addr: SocketAddrV4 = "203.0.113.1:1000".parse().unwrap();
        let plain_addr: SocketAddrV4 = "10.0.0.1:2000".parse().unwrap();
        let resp = success_response(txid, Some(xor_addr), Some(plain_addr));
        assert_eq!(
            parse_response(&resp, &txid).unwrap(),
            SocketAddr::V4(xor_addr)
        );
    }

    #[test]
    fn rejects_bad_transaction_and_cookie() {
        let txid = [5u8; 12];
        let resp = success_response(txid, Some("1.2.3.4:5".parse().unwrap()), None);
        assert!(parse_response(&resp, &[6u8; 12]).is_err());

        let mut bad_cookie = resp.clone();
        bad_cookie[4] ^= 0xff;
        assert!(parse_response(&bad_cookie, &txid).is_err());
    }

    #[test]
    fn rejects_truncated_and_empty_attrs() {
        let txid = [7u8; 12];
        assert!(parse_response(&[0u8; 19], &txid).is_err());

        let mut resp = Vec::new();
        resp.extend_from_slice(&TYPE_BINDING_SUCCESS.to_be_bytes());
        resp.extend_from_slice(&0u16.to_be_bytes());
        resp.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
        resp.extend_from_slice(&txid);
        assert!(parse_response(&resp, &txid).is_err());
    }

    #[test]
    fn nat_classification() {
        let a: SocketAddr = "1.2.3.4:1000".parse().unwrap();
        let b: SocketAddr = "1.2.3.4:2000".parse().unwrap();
        assert_eq!(classify(&[]), NatHint::Unknown);
        assert_eq!(classify(&[a]), NatHint::Unknown);
        assert_eq!(classify(&[a, a]), NatHint::EndpointIndependent);
        assert_eq!(classify(&[a, b]), NatHint::AddressDependent);
    }

    #[test]
    fn routability() {
        assert!(!is_routable("10.0.0.1".parse().unwrap()));
        assert!(!is_routable("192.168.1.1".parse().unwrap()));
        assert!(!is_routable("127.0.0.1".parse().unwrap()));
        assert!(!is_routable("203.0.113.7".parse().unwrap())); // 文档示例网段
        assert!(is_routable("8.8.8.8".parse().unwrap()));
    }
}

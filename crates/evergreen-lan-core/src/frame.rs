//! 加密隧道中承载的应用帧。
//!
//! 每个 UDP 数据报恰好包含一条 Noise 传输消息，其明文是一个 [`Frame`]。
//! 帧被刻意设计得很小：一个 IP 包帧就是单字节标签加上数据包本身。

use crate::handshake::Role;
use crate::{Error, Result};

/// 帧内允许的显示名最大长度。
pub const MAX_FRAME_NAME: usize = 48;

/// `Bye` 帧中原因字段的最大长度。
pub const MAX_BYE_LEN: usize = 96;

/// 允许处理的最大明文数据报长度。
pub const MAX_PLAINTEXT: usize = 2048;

const T_HELLO: u8 = 0x01;
const T_HELLO_ACK: u8 = 0x02;
const T_IP: u8 = 0x03;
const T_PING: u8 = 0x04;
const T_PONG: u8 = 0x05;
const T_BYE: u8 = 0x06;

/// 与对端交换的控制帧或数据帧。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    /// 握手后的第一帧：本端身份与本端使用的地址。
    Hello {
        /// 本端在虚拟子网内的地址。
        ip: [u8; 4],
        /// 本端是否为该房间的主机。
        role: Role,
        /// 在对端列表中显示的名称。
        name: String,
    },
    /// 主机确认帧，携带分配给访客的地址。
    HelloAck {
        /// 访客在虚拟子网内必须使用的地址。
        ip: [u8; 4],
        /// 主机的显示名称。
        name: String,
    },
    /// 待写入虚拟网卡的 IP 数据包。
    Ip(Vec<u8>),
    /// 存活探测。
    Ping(u64),
    /// 探测应答。
    Pong(u64),
    /// 正常关闭。
    Bye(String),
}

impl Frame {
    /// 序列化该帧。
    pub fn encode(&self) -> Result<Vec<u8>> {
        let mut out = Vec::with_capacity(32);
        match self {
            Frame::Hello { ip, role, name } => {
                let name = name.as_bytes();
                if name.len() > MAX_FRAME_NAME {
                    return Err(Error::Codec("hello name too long".into()));
                }
                out.push(T_HELLO);
                out.extend_from_slice(ip);
                out.push(match role {
                    Role::Host => 0,
                    Role::Guest => 1,
                });
                out.push(name.len() as u8);
                out.extend_from_slice(name);
            }
            Frame::HelloAck { ip, name } => {
                let name = name.as_bytes();
                if name.len() > MAX_FRAME_NAME {
                    return Err(Error::Codec("hello-ack name too long".into()));
                }
                out.push(T_HELLO_ACK);
                out.extend_from_slice(ip);
                out.push(name.len() as u8);
                out.extend_from_slice(name);
            }
            Frame::Ip(packet) => {
                if packet.len() > MAX_PLAINTEXT {
                    return Err(Error::Codec(format!(
                        "ip frame of {} bytes exceeds limit",
                        packet.len()
                    )));
                }
                out.push(T_IP);
                out.extend_from_slice(packet);
            }
            Frame::Ping(seq) => {
                out.push(T_PING);
                out.extend_from_slice(&seq.to_be_bytes());
            }
            Frame::Pong(seq) => {
                out.push(T_PONG);
                out.extend_from_slice(&seq.to_be_bytes());
            }
            Frame::Bye(reason) => {
                let reason = reason.as_bytes();
                let reason = if reason.len() > MAX_BYE_LEN {
                    &reason[..MAX_BYE_LEN]
                } else {
                    reason
                };
                out.push(T_BYE);
                out.push(reason.len() as u8);
                out.extend_from_slice(reason);
            }
        }
        Ok(out)
    }

    /// 解析由 [`Frame::encode`] 生成的帧。
    pub fn decode(buf: &[u8]) -> Result<Self> {
        let (&tag, rest) = buf
            .split_first()
            .ok_or_else(|| Error::Codec("empty frame".into()))?;
        match tag {
            T_HELLO => {
                if rest.len() < 6 {
                    return Err(Error::Codec("truncated hello".into()));
                }
                let ip = [rest[0], rest[1], rest[2], rest[3]];
                let role = match rest[4] {
                    0 => Role::Host,
                    1 => Role::Guest,
                    other => {
                        return Err(Error::Codec(format!("unknown role {other}")));
                    }
                };
                let name_len = rest[5] as usize;
                if name_len > MAX_FRAME_NAME || rest.len() < 6 + name_len {
                    return Err(Error::Codec("bad hello name length".into()));
                }
                let name = String::from_utf8(rest[6..6 + name_len].to_vec())
                    .map_err(|_| Error::Codec("hello name is not utf-8".into()))?;
                Ok(Frame::Hello { ip, role, name })
            }
            T_HELLO_ACK => {
                if rest.len() < 5 {
                    return Err(Error::Codec("truncated hello-ack".into()));
                }
                let ip = [rest[0], rest[1], rest[2], rest[3]];
                let name_len = rest[4] as usize;
                if name_len > MAX_FRAME_NAME || rest.len() < 5 + name_len {
                    return Err(Error::Codec("bad hello-ack name length".into()));
                }
                let name = String::from_utf8(rest[5..5 + name_len].to_vec())
                    .map_err(|_| Error::Codec("hello-ack name is not utf-8".into()))?;
                Ok(Frame::HelloAck { ip, name })
            }
            T_IP => {
                if rest.len() > MAX_PLAINTEXT {
                    return Err(Error::Codec("ip frame too large".into()));
                }
                Ok(Frame::Ip(rest.to_vec()))
            }
            T_PING => Ok(Frame::Ping(read_u64(rest)?)),
            T_PONG => Ok(Frame::Pong(read_u64(rest)?)),
            T_BYE => {
                if rest.is_empty() {
                    return Err(Error::Codec("truncated bye".into()));
                }
                let len = rest[0] as usize;
                if len > MAX_BYE_LEN || rest.len() < 1 + len {
                    return Err(Error::Codec("bad bye length".into()));
                }
                let reason = String::from_utf8_lossy(&rest[1..1 + len]).into_owned();
                Ok(Frame::Bye(reason))
            }
            other => Err(Error::Codec(format!("unknown frame tag {other:#04x}"))),
        }
    }
}

fn read_u64(buf: &[u8]) -> Result<u64> {
    if buf.len() < 8 {
        return Err(Error::Codec("truncated u64".into()));
    }
    let mut b = [0u8; 8];
    b.copy_from_slice(&buf[..8]);
    Ok(u64::from_be_bytes(b))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(f: Frame) {
        let bytes = f.encode().unwrap();
        let back = Frame::decode(&bytes).unwrap();
        assert_eq!(back, f);
    }

    #[test]
    fn all_frames_roundtrip() {
        roundtrip(Frame::Hello {
            ip: [10, 66, 0, 2],
            role: Role::Guest,
            name: "Alice".into(),
        });
        roundtrip(Frame::HelloAck {
            ip: [10, 66, 0, 2],
            name: "Bob".into(),
        });
        roundtrip(Frame::Ip(vec![0x45, 0, 0, 20]));
        roundtrip(Frame::Ping(7));
        roundtrip(Frame::Pong(7));
        roundtrip(Frame::Bye("leaving".into()));
    }

    #[test]
    fn rejects_unknown_and_truncated() {
        assert!(Frame::decode(&[]).is_err());
        assert!(Frame::decode(&[0xff]).is_err());
        assert!(Frame::decode(&[T_HELLO, 1, 2]).is_err());
        assert!(Frame::decode(&[T_PING, 0, 0]).is_err());
        assert!(Frame::decode(&[T_BYE]).is_err());
    }

    #[test]
    fn rejects_non_utf8_name() {
        let mut bytes = vec![T_HELLO, 10, 66, 0, 2, 1, 1];
        bytes.push(0xff);
        assert!(Frame::decode(&bytes).is_err());
    }

    #[test]
    fn rejects_oversized_name() {
        let huge = "a".repeat(MAX_FRAME_NAME + 1);
        assert!(Frame::Hello {
            ip: [0; 4],
            role: Role::Guest,
            name: huge
        }
        .encode()
        .is_err());
    }

    #[test]
    fn bye_is_truncated_not_rejected() {
        let long = "x".repeat(MAX_BYE_LEN * 2);
        let bytes = Frame::Bye(long).encode().unwrap();
        let back = Frame::decode(&bytes).unwrap();
        match back {
            Frame::Bye(reason) => assert_eq!(reason.len(), MAX_BYE_LEN),
            other => panic!("unexpected frame {other:?}"),
        }
    }
}

use std::fmt;

/// 协议核心产生的错误。
#[derive(Debug)]
pub enum Error {
    /// 邀请码无法解析或未通过校验。
    Invite(&'static str),
    /// Base64 解码失败。
    Base64(base64::DecodeError),
    /// 压缩后的载荷已损坏。
    Compression(String),
    /// 二进制载荷与预期布局不符。
    Codec(String),
    /// Noise 握手或传输失败。
    Crypto(String),
    /// 底层套接字操作失败。
    Io(std::io::Error),
    /// 对端违反了协议。
    Protocol(String),
    /// 操作未在截止时间内完成。
    Timeout,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Invite(m) => write!(f, "invalid invite code: {m}"),
            Error::Base64(e) => write!(f, "invite code is not valid base64: {e}"),
            Error::Compression(m) => write!(f, "invite payload is corrupt: {m}"),
            Error::Codec(m) => write!(f, "malformed message: {m}"),
            Error::Crypto(m) => write!(f, "crypto failure: {m}"),
            Error::Io(e) => write!(f, "io failure: {e}"),
            Error::Protocol(m) => write!(f, "protocol violation: {m}"),
            Error::Timeout => write!(f, "operation timed out"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Base64(e) => Some(e),
            Error::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<base64::DecodeError> for Error {
    fn from(e: base64::DecodeError) -> Self {
        Error::Base64(e)
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

impl From<snow::Error> for Error {
    fn from(e: snow::Error) -> Self {
        Error::Crypto(e.to_string())
    }
}

/// 在整个 crate 内通用的便捷别名。
pub type Result<T> = std::result::Result<T, Error>;

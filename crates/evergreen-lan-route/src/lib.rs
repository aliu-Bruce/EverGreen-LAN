//! 虚拟网卡的地址、路由与防火墙配置。
//!
//! 三个平台各自有一套命令行工具：Windows 用 `netsh`，macOS 用 `ifconfig`/`route`，
//! Linux 用 `ip`。本 crate 把「要执行哪些命令」与「怎么执行」分开：
//! 命令构造是纯粹的函数（可在任意平台单元测试），执行器只负责调用。
//!
//! 所有命令都是幂等的：先尝试移除旧配置再添加，因此崩溃残留不会阻止下一次启动。

use std::fmt;
use std::process::Command;

/// 一次网络配置失败。
#[derive(Debug)]
pub enum RouteError {
    /// 命令以非零状态退出。
    Command {
        /// 失败的命令。
        command: String,
        /// 失败时合并后的 stderr/stdout。
        message: String,
    },
    /// 命令完全无法启动。
    Spawn(String),
}

impl fmt::Display for RouteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RouteError::Command { command, message } => {
                write!(f, "`{command}` 执行失败：{message}")
            }
            RouteError::Spawn(err) => write!(f, "无法执行命令：{err}"),
        }
    }
}

impl std::error::Error for RouteError {}

/// 本 crate 的结果别名。
pub type Result<T> = std::result::Result<T, RouteError>;

#[cfg(target_os = "linux")]
use spec::linux as platform;
#[cfg(target_os = "macos")]
use spec::mac as platform;
/// 当前平台可用的命令构造器。
#[cfg(windows)]
use spec::win as platform;

/// 单个网卡上已应用的配置步骤，用于按相反顺序撤销。
enum Step {
    Address { ip: [u8; 4], prefix: u8 },
    Route { dest: [u8; 4], prefix: u8 },
}

/// 一块已配置好的虚拟网卡。
pub struct VirtualInterface {
    name: String,
    applied: Vec<Step>,
}

impl VirtualInterface {
    /// 配置虚拟网卡：地址、MTU，并把它启用起来。
    pub fn configure(name: &str, ip: [u8; 4], prefix: u8, mtu: u16) -> Result<Self> {
        let mut iface = Self {
            name: name.to_string(),
            applied: Vec::new(),
        };

        // 先移除残留地址以保证幂等：崩溃的实例可能留下该地址。
        for command in platform::reset_address(name, ip, prefix) {
            let _ = run(&command);
        }
        for command in platform::add_address(name, ip, prefix) {
            run(&command)?;
        }
        iface.applied.push(Step::Address { ip, prefix });

        // MTU 属于建议性设置：此处失败不应拆掉可用的会话，
        // 因为 TCP 仍会发现正确的 MSS。
        for command in platform::set_mtu(name, mtu) {
            if let Err(err) = run(&command) {
                tracing::warn!(%err, "无法设置适配器 MTU");
            }
        }

        Ok(iface)
    }

    /// 该配置所属的适配器名称。
    pub fn name(&self) -> &str {
        &self.name
    }

    /// 将目的地路由到虚拟适配器。
    ///
    /// 用于否则会发往物理网卡的组播地址，尤其是 Minecraft 的 `224.0.2.60`。
    pub fn add_route(&mut self, dest: [u8; 4], prefix: u8) -> Result<()> {
        for command in platform::reset_route(&self.name, dest, prefix) {
            let _ = run(&command);
        }
        for command in platform::add_route(&self.name, dest, prefix) {
            run(&command)?;
        }
        self.applied.push(Step::Route { dest, prefix });
        Ok(())
    }

    /// 移除所有已应用的步骤，最新的优先。
    pub fn revert(&mut self) -> Vec<RouteError> {
        let mut errors = Vec::new();
        while let Some(step) = self.applied.pop() {
            let commands = match step {
                Step::Address { ip, prefix } => platform::remove_address(&self.name, ip, prefix),
                Step::Route { dest, prefix } => platform::remove_route(&self.name, dest, prefix),
            };
            for command in commands {
                if let Err(err) = run(&command) {
                    // 残留路由只是噪音，不是中止拆卸的理由。
                    tracing::warn!(%err, "无法还原某项网络配置");
                    errors.push(err);
                }
            }
        }
        errors
    }
}

impl Drop for VirtualInterface {
    fn drop(&mut self) {
        let errors = self.revert();
        if errors.is_empty() {
            tracing::debug!(name = %self.name, "已还原虚拟网卡配置");
        }
    }
}

/// 允许入站流量到达该可执行文件。
///
/// 只有 Windows 需要这一步：缺少规则时防火墙会静默丢弃其他玩家发往
/// 虚拟适配器的报文。macOS 与 Linux 默认不拦，直接返回成功。
pub fn allow_firewall(executable: &str, rule_name: &str) -> Result<()> {
    for command in platform::reset_firewall(rule_name) {
        let _ = run(&command);
    }
    for command in platform::add_firewall(executable, rule_name) {
        run(&command)?;
    }
    Ok(())
}

/// 执行一条命令；第一条元素是可执行文件名。
fn run(args: &[String]) -> Result<()> {
    let (program, rest) = args
        .split_first()
        .ok_or_else(|| RouteError::Spawn("空命令".into()))?;
    let output = Command::new(program)
        .args(rest)
        .output()
        .map_err(|e| RouteError::Spawn(e.to_string()))?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let message = if stderr.is_empty() { stdout } else { stderr };
    Err(RouteError::Command {
        command: args.join(" "),
        message,
    })
}

/// 前缀 16 对应的 `255.255.0.0`。
pub fn mask_from_prefix(prefix: u8) -> [u8; 4] {
    let bits = prefix.min(32);
    let mask: u32 = if bits == 0 {
        0
    } else {
        u32::MAX << (32 - bits as u32)
    };
    mask.to_be_bytes()
}

fn dotted(ip: [u8; 4]) -> String {
    format!("{}.{}.{}.{}", ip[0], ip[1], ip[2], ip[3])
}

fn join(program: &str, parts: &[&str]) -> Vec<String> {
    let mut out = vec![program.to_string()];
    out.extend(parts.iter().map(|part| part.to_string()));
    out
}

/// 各平台的命令构造。
///
/// 三个模块始终参与编译，因此可以在 Windows 上单元测试 macOS 与 Linux 的命令形状。
pub mod spec {
    use super::{dotted, join, mask_from_prefix};

    /// Windows：`netsh`。
    pub mod win {
        use super::*;

        fn netsh(parts: &[&str]) -> Vec<String> {
            join("netsh", parts)
        }

        pub fn reset_address(_name: &str, ip: [u8; 4], _prefix: u8) -> Vec<Vec<String>> {
            let ip = dotted(ip);
            vec![netsh(&["interface", "ipv4", "delete", "address", &ip])]
        }

        pub fn add_address(name: &str, ip: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let mask = dotted(mask_from_prefix(prefix));
            let ip = dotted(ip);
            vec![netsh(&[
                "interface",
                "ipv4",
                "add",
                "address",
                name,
                &ip,
                &mask,
            ])]
        }

        pub fn remove_address(name: &str, ip: [u8; 4], _prefix: u8) -> Vec<Vec<String>> {
            let ip = dotted(ip);
            let _ = name;
            vec![netsh(&["interface", "ipv4", "delete", "address", &ip])]
        }

        pub fn set_mtu(name: &str, mtu: u16) -> Vec<Vec<String>> {
            let mtu = format!("mtu={mtu}");
            vec![netsh(&[
                "interface",
                "ipv4",
                "set",
                "subinterface",
                name,
                &mtu,
                "store=active",
            ])]
        }

        pub fn reset_route(name: &str, dest: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            remove_route(name, dest, prefix)
        }

        pub fn add_route(name: &str, dest: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let target = format!("{}/{}", dotted(dest), prefix);
            vec![netsh(&[
                "interface",
                "ipv4",
                "add",
                "route",
                &target,
                name,
                "metric=1",
                "store=active",
            ])]
        }

        pub fn remove_route(name: &str, dest: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let target = format!("{}/{}", dotted(dest), prefix);
            vec![netsh(&[
                "interface",
                "ipv4",
                "delete",
                "route",
                &target,
                name,
            ])]
        }

        pub fn reset_firewall(rule_name: &str) -> Vec<Vec<String>> {
            let name = format!("name={rule_name}");
            vec![netsh(&["advfirewall", "firewall", "delete", "rule", &name])]
        }

        pub fn add_firewall(executable: &str, rule_name: &str) -> Vec<Vec<String>> {
            // netsh 自行解析 `program=` 的值：路径含空格时必须加内层引号，
            // 否则它会把路径截断，创建一条指向不存在程序的规则。
            let program = format!("program=\"{executable}\"");
            let name = format!("name={rule_name}");
            vec![netsh(&[
                "advfirewall",
                "firewall",
                "add",
                "rule",
                &name,
                "dir=in",
                "action=allow",
                &program,
                "enable=yes",
                "profile=private",
            ])]
        }
    }

    /// macOS：`ifconfig` 与 `route`。
    pub mod mac {
        use super::*;

        pub fn reset_address(name: &str, _ip: [u8; 4], _prefix: u8) -> Vec<Vec<String>> {
            // utun 可能带着上次运行残留的地址，先置 down 再重新配置。
            vec![join("ifconfig", &[name, "down"])]
        }

        pub fn add_address(name: &str, ip: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let ip = dotted(ip);
            let mask = dotted(mask_from_prefix(prefix));
            // 点对点接口：本端与对端用同一地址，掩码决定子网。
            vec![join(
                "ifconfig",
                &[name, "inet", &ip, &ip, "netmask", &mask, "up"],
            )]
        }

        pub fn remove_address(name: &str, ip: [u8; 4], _prefix: u8) -> Vec<Vec<String>> {
            let ip = dotted(ip);
            vec![join("ifconfig", &[name, "inet", &ip, "-alias"])]
        }

        pub fn set_mtu(name: &str, mtu: u16) -> Vec<Vec<String>> {
            let mtu = mtu.to_string();
            vec![join("ifconfig", &[name, "mtu", &mtu])]
        }

        pub fn reset_route(_name: &str, dest: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let target = format!("{}/{}", dotted(dest), prefix);
            vec![join("route", &["-n", "delete", "-net", &target])]
        }

        pub fn add_route(name: &str, dest: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let target = format!("{}/{}", dotted(dest), prefix);
            vec![join(
                "route",
                &["-n", "add", "-net", &target, "-interface", name],
            )]
        }

        pub fn remove_route(_name: &str, dest: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let target = format!("{}/{}", dotted(dest), prefix);
            vec![join("route", &["-n", "delete", "-net", &target])]
        }

        pub fn reset_firewall(_rule_name: &str) -> Vec<Vec<String>> {
            Vec::new()
        }

        pub fn add_firewall(_executable: &str, _rule_name: &str) -> Vec<Vec<String>> {
            Vec::new()
        }
    }

    /// Linux：`ip`。
    pub mod linux {
        use super::*;

        pub fn reset_address(_name: &str, _ip: [u8; 4], _prefix: u8) -> Vec<Vec<String>> {
            // `ip addr replace` 本身幂等，不需要预清理。
            Vec::new()
        }

        pub fn add_address(name: &str, ip: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let cidr = format!("{}/{}", dotted(ip), prefix);
            vec![
                join("ip", &["addr", "replace", &cidr, "dev", name]),
                join("ip", &["link", "set", "dev", name, "up"]),
            ]
        }

        pub fn remove_address(name: &str, ip: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let cidr = format!("{}/{}", dotted(ip), prefix);
            vec![join("ip", &["addr", "del", &cidr, "dev", name])]
        }

        pub fn set_mtu(name: &str, mtu: u16) -> Vec<Vec<String>> {
            let mtu = mtu.to_string();
            vec![join("ip", &["link", "set", "dev", name, "mtu", &mtu])]
        }

        pub fn reset_route(_name: &str, dest: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let cidr = format!("{}/{}", dotted(dest), prefix);
            vec![join("ip", &["route", "del", &cidr])]
        }

        pub fn add_route(name: &str, dest: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let cidr = format!("{}/{}", dotted(dest), prefix);
            vec![join("ip", &["route", "replace", &cidr, "dev", name])]
        }

        pub fn remove_route(_name: &str, dest: [u8; 4], prefix: u8) -> Vec<Vec<String>> {
            let cidr = format!("{}/{}", dotted(dest), prefix);
            vec![join("ip", &["route", "del", &cidr])]
        }

        pub fn reset_firewall(_rule_name: &str) -> Vec<Vec<String>> {
            Vec::new()
        }

        pub fn add_firewall(_executable: &str, _rule_name: &str) -> Vec<Vec<String>> {
            Vec::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::spec::{linux, mac, win};
    use super::*;

    #[test]
    fn prefix_masks() {
        assert_eq!(mask_from_prefix(0), [0, 0, 0, 0]);
        assert_eq!(mask_from_prefix(8), [255, 0, 0, 0]);
        assert_eq!(mask_from_prefix(16), [255, 255, 0, 0]);
        assert_eq!(mask_from_prefix(24), [255, 255, 255, 0]);
        assert_eq!(mask_from_prefix(32), [255, 255, 255, 255]);
        // 越界前缀会被截断，而不是 panic。
        assert_eq!(mask_from_prefix(99), [255, 255, 255, 255]);
    }

    #[test]
    fn windows_address_command() {
        let commands = win::add_address("EverGreen LAN", [10, 66, 0, 1], 16);
        assert_eq!(commands.len(), 1);
        assert_eq!(
            commands[0],
            vec![
                "netsh",
                "interface",
                "ipv4",
                "add",
                "address",
                "EverGreen LAN",
                "10.66.0.1",
                "255.255.0.0"
            ]
            .into_iter()
            .map(String::from)
            .collect::<Vec<_>>()
        );
    }

    #[test]
    fn windows_firewall_quotes_spaced_paths() {
        let commands = win::add_firewall("C:\\Apps\\Ever Green\\a.exe", "EverGreen LAN");
        let program = commands[0]
            .iter()
            .find(|arg| arg.starts_with("program="))
            .expect("program 参数存在");
        assert_eq!(program, "program=\"C:\\Apps\\Ever Green\\a.exe\"");
    }

    #[test]
    fn macos_commands_use_ifconfig_and_route() {
        let addr = mac::add_address("utun4", [10, 66, 0, 1], 16);
        assert_eq!(addr[0][0], "ifconfig");
        assert!(addr[0].contains(&"10.66.0.1".to_string()));
        assert!(addr[0].contains(&"255.255.0.0".to_string()));
        assert!(addr[0].contains(&"up".to_string()));

        let route = mac::add_route("utun4", [224, 0, 2, 60], 32);
        assert_eq!(route[0][0], "route");
        assert!(route[0].contains(&"224.0.2.60/32".to_string()));
        assert!(route[0].contains(&"utun4".to_string()));

        // macOS 不需要防火墙规则。
        assert!(mac::add_firewall("x", "y").is_empty());
    }

    #[test]
    fn linux_commands_use_ip() {
        let addr = linux::add_address("evergreen0", [10, 66, 0, 1], 16);
        assert_eq!(addr[0][0], "ip");
        assert_eq!(addr[0][1], "addr");
        assert!(addr[0].contains(&"10.66.0.1/16".to_string()));
        assert!(addr[1].contains(&"up".to_string()));

        let route = linux::add_route("evergreen0", [224, 0, 2, 60], 32);
        assert_eq!(route[0][1], "route");
        assert!(route[0].contains(&"224.0.2.60/32".to_string()));

        let mtu = linux::set_mtu("evergreen0", 1200);
        assert!(mtu[0].contains(&"1200".to_string()));
    }

    #[test]
    fn teardown_reverses_in_order() {
        let mut iface = VirtualInterface {
            name: "EverGreen LAN".into(),
            applied: vec![
                Step::Address {
                    ip: [10, 66, 0, 1],
                    prefix: 16,
                },
                Step::Route {
                    dest: [224, 0, 2, 60],
                    prefix: 32,
                },
            ],
        };
        // 适配器不存在时执行回退不得 panic；失败会被收集，而不是向外传播。
        let _ = iface.revert();
        assert!(iface.applied.is_empty());
    }
}

# EverGreen LAN · 插件系统设计(P4 · 设计稿)

> 状态:**设计确认中,未开工**。
> 前置:P3a 可靠流层 → P3b 内置文件传输;本系统是 P4 的生态层。
> 本文回答四件事:包格式(`.eglanaddon`)、宿主-插件协议、能力与安全边界、落地阶段。

## 0. 定位:内置功能与插件是两个物种

传输、聊天、语音是**内置功能**:核心第一方代码,直接跑在数据面上,随主程序发布,
不走任何插件机制。插件系统面向**第三方**:独立进程、能力门控、崩溃隔离,
经 `.eglanaddon` 分发。两层共享的唯一底座是**可靠流层**(见 §2)。

| | 内置功能 | 插件 |
|---|---|---|
| 代码归属 | 核心本体 | 独立仓库/独立进程 |
| 信任级别 | 完全可信 | 不可信,按清单门控 |
| 数据通道 | 数据面直用 | 宿主中继的流抽象 |
| 发布节奏 | 随 EGLAN 版本 | 随时安装、卸载 |

## 1. 包格式:`.eglanaddon`

### 1.1 容器

本质是标准 ZIP(deflate,不加密,文件名带 UTF-8 标志),扩展名即身份。
安装 = 解压到 `egland.exe` 旁的 `plugins\<name>\` 目录。没有注册表、没有隐藏状态。

```
MyPlugin.eglanaddon
├── manifest.json          必需,唯一权威描述
├── README.md              必需(启用面板展示给用户)
├── LICENSE                必需
├── assets/icon.png        可选,管理页图标(≤256×256)
├── bin/                   必需,可启动产物(含随包解释器亦放此)
│   ├── windows-amd64.exe
│   ├── linux-amd64
│   └── darwin-arm64
└── src/                   可选,源码可随包分发
```

### 1.2 manifest.json

```json
{
  "format": 1,
  "name": "my-plugin",
  "display": "我的插件",
  "version": "1.0.0",
  "entry": {
    "windows-amd64": { "exe": "bin/windows-amd64.exe" },
    "linux-amd64":   { "exe": "bin/main" },
    "darwin-arm64":  { "exe": "bin/python/python.exe", "args": ["main.py"] }
  },
  "capabilities": ["room.stream.dial", "room.stream.listen", "room.events"],
  "minCore": "1.4.0"
}
```

字段规则:

| 字段 | 必需 | 说明 |
|---|---|---|
| `format` | 是 | 包格式版本,当前只接受 `1` |
| `name` | 是 | `[a-z0-9-]{2,32}`,即安装目录名与全局标识 |
| `display` | 是 | 界面显示名,≤32 字符 |
| `version` | 是 | 语义化版本,展示用 |
| `entry` | 是 | 平台三元组 → `{exe, args?}`;核心按 `runtime.GOOS-GOARCH` 取用 |
| `capabilities` | 是 | 能力声明,可为空数组;出现未知能力**拒绝装载** |
| `minCore` | 否 | 核心版本下限提示,不满足则装载时警告 |

`exe` 必须是操作系统能直接启动的文件(Windows 上是 PE)。脚本语言作者把
自包含解释器(如 python-embed)与脚本一并放进 `bin/`,`args` 指向入口脚本——
这是官方支持的形态,与原生编译产物无差别。核心不内置任何解释器(零依赖原则)。

### 1.3 校验规则(七条)

打包脚本(模板内 `scripts/compile.*`)在打包前查一遍;核心导入时**再查一遍**,
不信任打包方:

1. `manifest.json` 存在且 JSON 合法;
2. `format` 受支持;
3. 必需字段齐全(`name`/`display`/`version`/`entry`/`capabilities`);
4. `README.md` 与 `LICENSE` 存在;
5. 当前平台 `entry.exe` 在包内存在;
6. 包内无路径穿越(条目名含 `..`、绝对路径、盘符即拒);
7. 解压总量 ≤ 64 MB、条目数 ≤ 512(防解压炸弹,流式边解边计)。

### 1.4 安装与生命周期

- **导入**:UI 选 `.eglanaddon` → 核心校验 → 解压到 `plugins\<name>\` →
  呈现为**停用态**。同名重导入 = 覆盖更新(保留启用状态)。
- **启用/停用**:永远是用户显式点击;启用面板展示清单全文 + README
  (浏览器扩展模式,知情即同意)。**不做签名、不做市场**——分发渠道就是文件本身。
- **运行时机**:插件是房间作用域的(能力全是 `room.*`),因此**只在开房期间运行**:
  开房 → 拉起全部已启用插件;离房 → 先礼后兵关闭。房间中途导入的插件
  下次开房生效,UI 注明。
- **卸载**:删目录。停用中的插件才可删(运行中的先停)。

## 2. 底座:可靠流层(P3a,先于本系统交付)

房间数据面现状是「一个 UDP 报文 = 一帧 IP 包,不可靠」。文件传输、聊天、语音、
插件流全部需要**可靠有序字节流**,因此数据面在加密载荷内增加流帧
(IPv4 首字节恒为 0x4x,首字节 `< 0x40` 即流帧,向后兼容):

```
流帧 = [1B 类型][4B 流号][载荷]
类型:0x01 打开(带对端流号协商) / 0x02 数据 / 0x03 累积确认
      / 0x04 关闭 / 0x05 窗口通告
```

主机按「成员 + 流号」路由,两端核心各自把流帧桥接成本地字节流:
内置功能直接调用;插件经 §3 协议拿到同一抽象。可靠层 = 序号 + 累积确认
+ 重传 + 滑窗,进程内三人房间可完整自测。**具体参数在 P3a 实现时定稿,
本文只锁接口形状**:`Dial(peer, meta) → Stream` / `Accept() → Stream`,
`Stream` 提供 `Read/Write/Close` 与对端元信息。

## 3. 宿主-插件协议

### 3.1 通道:单 stdio,定长帧

控制与数据复用同一条 stdin/stdout(独立进程、不共享地址空间是安全边界;
stdio 是最薄的桥)。所有消息统一为:

```
[4B 大端载荷长度 N][1B 通道][N 字节载荷]
通道 0x01 控制:载荷为 UTF-8 JSON 对象(不含换行)
通道 0x02 数据:载荷 = [4B 流号][原始字节]
上限:载荷 ≤ 8 MB;控制 JSON ≤ 64 KB;数据帧建议 ≤ 256 KB
```

**stderr 是日志专用**,宿主收进每插件 100 行环形缓冲,供界面排障;
写 stdout 会破坏帧流,属插件 bug,宿主直接杀进程。

### 3.2 会话状态机

```
spawn → 握手(5s 超时) → ready ── room-up ──→ active ── room-down ──→ ready
             ↑ 失败:杀进程,标 failed                       离房:关 stdin,
             └── 崩溃:退避重启(1s→2s→4s…上限 30s,             3s 不退则杀
                 连续 5 次失败标 failed,UI 展示)
```

握手(插件先说,宿主校验):

```json
→ {"proto":1, "name":"my-plugin", "version":"1.0.0"}
← {"type":"hello-ok", "granted":["room.stream.dial","room.stream.listen","room.events"],
   "session":{"self":"10.66.7.1", "members":[{"name":"…","ip":"…"}]}}
```

`name` 与清单不符 → 拒绝。`granted` 是清单能力与本机策略的交集。

### 3.3 控制通道消息

请求应答(带 `id` 关联):

| 方向 | 消息 | 说明 |
|---|---|---|
| 插件→宿主 | `stream.dial {peer, meta?}` | 向某成员开流 → `{stream, peer}` |
| 插件→宿主 | `stream.close {stream}` | 关流;对端收到关闭帧 |
| 插件→宿主 | `members.list` | 读名册(需 `room.members`) |
| 宿主→插件 | 应答 `{type:"ok", id,…}` / `{type:"error", id, message}` | |

事件(宿主→插件,单向):

| 事件 | 载荷 | 说明 |
|---|---|---|
| `room-up` | self、members | 入房完成(重启后重发) |
| `room-down` | reason | 离房 |
| `member-join` / `member-leave` | name/ip/pub | 名册变化 |
| `stream.incoming` | stream、peer、meta | 远端开流进来,插件应 `Accept` |
| `credit` | stream、add | 数据通道配额补充(见下) |

### 3.4 流控:配额制

单条 stdio 无法按流反压,采用**配额(credit)**:每流初始窗口 1 MB,
插件写出即扣,宿主投递到可靠层后按 `credit {add}` 补回。配额耗尽还写 →
宿主关流并告警。文件级断点续传是插件自己的事(内置传输做示范实现)。

### 3.5 进程环境

- 工作目录 = 插件安装目录;环境变量追加 `EGLAN_PLUGIN_DIR`、`EGLAN_PLUGIN_NAME`;
- v1 传递完整环境(简化),插件**不持有房间密钥**——即使它直接朝主机 UDP 端口
  发包也无法通过握手,密码学即真正的能力墙;
- 关闭:宿主关 stdin(管道 EOF 是插件的退出信号),3 秒不退则强杀。

## 4. 能力模型

| 能力 | 授予 |
|---|---|
| `room.stream.dial` | 主动向成员开流 |
| `room.stream.listen` | 接收入流(`stream.incoming`) |
| `room.events` | 收房间事件流 |
| `room.members` | 主动查名册(v1 备选,默认不发) |

规则:清单声明 + 用户启用 = 授权;运行期调用未授予的能力 → `error` 并计数,
超阈值(10 次)宿主停用插件并在 UI 标红。内置功能不经过此表(它是核心本体)。

## 5. 界面与 IPC 集成

核心新增 IPC op(界面仍只与核心对话,不直连插件):

| op | 说明 |
|---|---|
| `plugins.list` | 已装插件:清单摘要、启用态、运行态、失败原因 |
| `plugin.install {path}` | 校验 + 解压,返回校验报告 |
| `plugin.set {name, enabled}` | 启用/停用 |
| `plugin.remove {name}` | 删除 |
| `plugin.log {name}` | 取 stderr 环形缓冲 |

事件:`plugin-state {name, state, error}`。UI 侧:设置页新增「插件」面板
(列表 + 导入按钮 + 启用开关 + 详情抽屉展示清单/README/日志),随 P4 落地;
**主题包不并入本系统**——它是 UI 令牌文件,导入即生效,与进程插件无关。

## 6. 语言与官方模板

- 官方模板仓库 `EverGreenLAN-Plugin-Template` 以 **Go 为默认骨架**:
  与核心同语言,协议编解码库直接复用,`scripts/compile.bat|.sh` 开箱即用;
- 文档给出 **python-embed 替代路径**(把 embed 包拖进 `bin/`,`args: ["main.py"]`);
- 模板脚本契约(七条校验的打包侧实现):查清单存在 → JSON 合法 → 必需字段 →
  README/LICENSE → 入口存在 → `go build` 出 `bin/<goos>-<goarch>` →
  ZIP 打包改名 `.eglanaddon` 输出 `dist/`。

## 7. 测试与自检

- 清单校验、帧编解码、配额流控:纯 `go test`;
- 内置测试插件:`egland -plugin-echo`(回显流数据),`-test-echo` 派生子进程
  跑全链路:装载 → 握手 → 开流 → 双向传输 → 关闭,免管理员,自检相应加项;
- 能力门控:伪造越权调用,断言拒绝与计数。

## 8. 非目标(v1 栅栏)

在线市场/下载、UI 页面插件、清单签名、插件监听网络端口、跨房间服务发现、
主题包并入插件体系、房间中途热装载。

## 9. 阶段划分

| 阶段 | 内容 | 验收 |
|---|---|---|
| P3a | 可靠流层(流帧、重传、滑窗) | `-test-echo` 三人流层用例 |
| P3b | 内置文件传输(不经插件机制) | 双机传文件、传输页实装 |
| P4 | 插件宿主 + `.eglanaddon` + 模板仓库 + UI 管理面板 | `-plugin-echo` 全链路 + 手工导入流程 |

## 10. 已确认的决定记录

1. 内置功能(传输/聊天/语音)不走插件机制;插件系统独立面向第三方;
2. `.eglanaddon` = ZIP 容器,模板含 manifest/README/LICENSE/src/assets/scripts;
3. 控制与数据共用单条 stdio,定长帧 + 通道字节;
4. `entry` 为 `{exe, args}` 对象,解释器随包形态是官方支持写法;
5. 官方模板默认 Go,Python 走文档路径;
6. 不做签名与市场,用户显式启用即同意;校验在打包侧与导入侧各执行一遍。

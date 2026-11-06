import { useCallback, useEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { api, type AppStatus, type CustomTheme, type Peer, type RoomView } from "./api";
import THEME_EXAMPLE from "./theme-example.json?raw";
import BUILTIN_SOURCE from "./builtin-themes.json";

/** 一个可应用的主题：内置或自定义，结构一致。 */
export interface ThemeDefinition {
  id: string;
  name: string;
  hint: string;
  mode: "light" | "dark";
  vars: Record<string, string>;
}

/**
 * 四个内置主题的「源文件」。
 *
 * 它们以数据形式存在（`builtin-themes.json`），而不是写死在样式表里，
 * 这样用户可以直接覆盖，也能通过「重置默认主题」从源文件恢复。
 */
const BUILTINS: ThemeDefinition[] = BUILTIN_SOURCE.themes.map((theme) => ({
  id: theme.id,
  name: theme.label,
  hint: theme.hint,
  mode: theme.mode as "light" | "dark",
  vars: { ...theme.vars },
}));

const BUILTIN_IDS = new Set(BUILTINS.map((theme) => theme.id));

/** 设置页展示的卡片；文案来自内置主题源文件。 */
const THEMES = BUILTINS.map((theme) => ({
  id: theme.id,
  label: theme.name,
  hint: theme.hint,
}));

type BuiltinTheme = string;
/** 内置主题的 id，或 `custom:<文件名>`。 */
type ThemeId = BuiltinTheme | `custom:${string}`;
type View = "home" | "room" | "settings";

/** 首次启动的默认主题。 */
const DEFAULT_THEME: ThemeId = "pine";

/** 字号倍率的硬上限；超出部分在应用时会被夹紧。 */
const MAX_TEXT_SCALE = 1.3;

/** 旧版 id 到当前 id 的映射，避免升级后主题丢失。 */
const LEGACY_THEMES: Record<string, ThemeId> = { evergreen: "pine" };

const isTheme = (value: string | null | undefined): value is ThemeId =>
  typeof value === "string" &&
  (BUILTIN_IDS.has(value) || value.startsWith("custom:"));

/** 归一化持久化的主题 id。 */
function normalizeTheme(value: string | null | undefined): ThemeId | null {
  if (typeof value !== "string") return null;
  const mapped = LEGACY_THEMES[value] ?? value;
  return isTheme(mapped) ? mapped : null;
}

/** 预览模式下的示例主题，供截图与冒烟测试使用。 */
const PREVIEW_THEMES: CustomTheme[] = [
  {
    id: "sea-salt",
    name: "海盐",
    hint: "冷蓝 · 细衬线",
    mode: "light",
    vars: {
      bg: "#eef3f6",
      "bg-deep": "#e2eaef",
      ink: "#0d1b24",
      "ink-soft": "#2f4350",
      "ink-faint": "#6f8492",
      rule: "rgba(13, 27, 36, 0.14)",
      "rule-strong": "rgba(13, 27, 36, 0.38)",
      accent: "#1f6f8b",
      "accent-ink": "#eef3f6",
      alert: "#9c3b2f",
      grain: "0.03",
    },
  },
];

/** 自定义主题的本地存储键；主题随偏好一起保存在本机，不落盘到目录。 */
const STORAGE_THEMES = "evergreen-lan.themes.v1";

/** 交给对话模型生成主题的提示词，与文档中的版本保持一致。 */
const THEME_AI_PROMPT = `为 EverGreen LAN 生成一个界面主题 JSON。请直接按下面给出的文件格式输出。

文件格式（完整示例，请严格沿用这个结构）：
{
  "schemaVersion": 1,
  "name": "海盐",
  "hint": "冷蓝 · 细衬线",
  "mode": "light",
  "vars": {
    "bg": "#eef3f6",
    "bg-deep": "#e2eaef",
    "ink": "#0d1b24",
    "ink-soft": "#2f4350",
    "ink-faint": "#6f8492",
    "rule": "rgba(13, 27, 36, 0.14)",
    "rule-strong": "rgba(13, 27, 36, 0.38)",
    "accent": "#1f6f8b",
    "accent-ink": "#eef3f6",
    "alert": "#9c3b2f",
    "grain": "0.03",
    "radius": "2px",
    "text-scale": "1",
    "display-font": "var(--font-sans)",
    "display-cjk": "var(--font-cjk-sans)",
    "display-weight": "500",
    "display-tracking": "-0.015em",
    "display-leading": "0.98"
  }
}

输出要求：
1. 只输出一个 JSON 对象，不要解释文字，不要 Markdown 代码块。
2. schemaVersion 固定为 1；name 是两到四个汉字的主题名；hint 是「风格 · 字体」形式的短句，
   不超过十个汉字；mode 取 "light" 或 "dark"。

颜色（必填 bg 与 ink）：
3. 必须是合法的 CSS 颜色值（十六进制、rgb 或 rgba）。
4. rule 与 rule-strong 用 rgba，透明度分别在 0.10–0.16 与 0.32–0.40。
5. alert 是该主题下可读的警告色。
6. 正文与背景对比度不低于 7:1，弱化文字不低于 4.5:1。

排版：
7. display-font 只能取 "var(--font-sans)"（无衬线）或 "var(--font-serif)"（衬线）；
   display-cjk 与之配套取 "var(--font-cjk-sans)" 或 "var(--font-cjk-serif)"。
8. display-weight 取 300、400、500 或 600。
9. display-tracking 在 -0.05em 到 0.02em 之间；紧凑风格取负值，松弛风格取 -0.02em 到 0。
10. display-leading 在 0.85 到 1.15 之间；紧凑风格偏小，松弛风格偏大。
11. text-scale 是界面字号倍率，取值 0.85–1.5，默认 1。

形状与质感：
12. radius 是圆角半径，带单位，取值 0px–16px；0px 代表完全直角。
13. grain 是颗粒强度，取值 0.01–0.08。
14. 整体风格克制、留白多、不要霓虹色；强调色只用于少量点缀。

风格描述：<在这里填写，例如「雨天的青灰，配一点旧铜色，衬线标题」>`;

function loadStoredThemes(): CustomTheme[] {
  try {
    const raw = window.localStorage.getItem(STORAGE_THEMES);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? (parsed as CustomTheme[]) : [];
  } catch {
    return [];
  }
}

const STORAGE_OVERRIDES = "evergreen-lan.theme-overrides.v1";

type Vars = Record<string, string>;
/** 用户对内置主题的覆盖：名称、说明与变量。 */
interface ThemeOverride {
  name: string;
  hint: string;
  vars: Vars;
}

function loadOverrides(): Record<string, ThemeOverride> {
  try {
    const raw = window.localStorage.getItem(STORAGE_OVERRIDES);
    const parsed = raw ? JSON.parse(raw) : {};
    return parsed && typeof parsed === "object" ? (parsed as Record<string, ThemeOverride>) : {};
  } catch {
    return {};
  }
}

/** 夹紧字号倍率，避免主题把界面撑破。 */
function clampScale(value: string | undefined): string {
  const parsed = Number.parseFloat(value ?? "1");
  if (!Number.isFinite(parsed)) return "1";
  return String(Math.min(MAX_TEXT_SCALE, Math.max(0.85, parsed)));
}

function useTheme(preview: boolean) {
  const applied = useRef<string[]>([]);
  const [theme, setTheme] = useState<ThemeId>(() => {
    const fromUrl = normalizeTheme(new URLSearchParams(window.location.search).get("theme"));
    if (fromUrl) return fromUrl;
    const stored = normalizeTheme(window.localStorage.getItem("egl.theme"));
    return stored ?? DEFAULT_THEME;
  });
  const [custom, setCustom] = useState<CustomTheme[]>(() =>
    preview ? PREVIEW_THEMES : loadStoredThemes(),
  );
  /** 被用户覆盖过的内置主题；键是主题 id。 */
  const [overrides, setOverrides] = useState<Record<string, ThemeOverride>>(() =>
    preview ? {} : loadOverrides(),
  );

  const persist = useCallback((list: CustomTheme[]) => {
    setCustom(list);
    window.localStorage.setItem(STORAGE_THEMES, JSON.stringify(list));
  }, []);

  const persistOverrides = useCallback((next: Record<string, ThemeOverride>) => {
    setOverrides(next);
    window.localStorage.setItem(STORAGE_OVERRIDES, JSON.stringify(next));
  }, []);

  /** 解析任意主题 id 的实际变量：自定义 > 内置覆盖 > 内置源文件。 */
  const resolve = useCallback(
    (id: string): ThemeDefinition | undefined => {
      if (id.startsWith("custom:")) {
        const found = custom.find((item) => `custom:${item.id}` === id);
        return found
          ? { id: found.id, name: found.name, hint: found.hint, mode: found.mode, vars: found.vars }
          : undefined;
      }
      const base = BUILTINS.find((item) => item.id === id);
      if (!base) return undefined;
      const patch = overrides[id];
      return patch
        ? {
            ...base,
            name: patch.name ?? base.name,
            hint: patch.hint ?? base.hint,
            vars: { ...base.vars, ...patch.vars },
          }
        : base;
    },
    [custom, overrides],
  );

  /** 保存自定义主题，或覆盖内置主题。 */
  const saveTheme = useCallback(
    (next: ThemeDefinition) => {
      if (BUILTIN_IDS.has(next.id)) {
        persistOverrides({
          ...overrides,
          [next.id]: { name: next.name, hint: next.hint, vars: next.vars },
        });
        setTheme(next.id);
        return;
      }
      persist([...custom.filter((item) => item.id !== next.id), next]);
      setTheme(`custom:${next.id}`);
    },
    [custom, overrides, persist, persistOverrides],
  );

  /** 解析并加入一个主题文件；校验失败时抛出可直接展示的中文说明。 */
  const importTheme = useCallback(
    async (file: File) => {
      const parsed = await api.parseTheme(await file.text(), file.name);
      persist([...custom.filter((item) => item.id !== parsed.id), parsed]);
      setTheme(`custom:${parsed.id}`);
      return parsed;
    },
    [custom, persist],
  );

  const removeTheme = useCallback(
    (id: string) => {
      persist(custom.filter((item) => item.id !== id));
      setTheme((current) => (current === `custom:${id}` ? DEFAULT_THEME : current));
    },
    [custom, persist],
  );

  /** 清空自定义主题与内置覆盖，回到出厂状态。 */
  const resetThemes = useCallback(() => {
    persist([]);
    persistOverrides({});
    setTheme(DEFAULT_THEME);
  }, [persist, persistOverrides]);

  useEffect(() => {
    const root = document.documentElement;
    for (const name of applied.current) {
      root.style.removeProperty(name);
    }
    applied.current = [];

    const resolved = resolve(theme);
    // 自定义主题以内置同名主题为底，保证未声明的变量也有值。
    const base = theme.startsWith("custom:") ? (resolved?.mode === "dark" ? "noir" : "paper") : theme;
    root.dataset.theme = base;
    root.style.colorScheme = resolved?.mode ?? "light";

    if (resolved) {
      const vars: Vars = { ...resolved.vars };
      if (vars.accent && vars.bg) {
        vars.accent = readableAccent(vars.accent, vars.bg, resolved.mode);
      }
      vars["text-scale"] = clampScale(vars["text-scale"]);
      for (const [key, value] of Object.entries(vars)) {
        const name = `--${key}`;
        root.style.setProperty(name, value);
        applied.current.push(name);
      }
    }

    window.localStorage.setItem("egl.theme", theme);
  }, [theme, resolve]);

  return {
    theme,
    setTheme,
    custom,
    overrides,
    resolve,
    importTheme,
    saveTheme,
    removeTheme,
    resetThemes,
  };
}

/**
 * 颜色对比度工具。
 *
 * 自定义主题由用户书写，容易出现「浅底浅字」的不可读组合；这里按 WCAG 相对亮度
 * 计算对比度，对强调色做有限次明暗调整，直到达到正文可读阈值。
 */
function parseHex(value: string): [number, number, number] | null {
  const match = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(value.trim());
  if (!match) return null;
  let hex = match[1];
  if (hex.length === 3) {
    hex = hex
      .split("")
      .map((c) => c + c)
      .join("");
  }
  return [
    Number.parseInt(hex.slice(0, 2), 16),
    Number.parseInt(hex.slice(2, 4), 16),
    Number.parseInt(hex.slice(4, 6), 16),
  ];
}

function luminance([r, g, b]: [number, number, number]): number {
  const channel = (value: number) => {
    const normalized = value / 255;
    return normalized <= 0.03928
      ? normalized / 12.92
      : ((normalized + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

function contrast(a: [number, number, number], b: [number, number, number]): number {
  const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (light + 0.05) / (dark + 0.05);
}

function shift(rgb: [number, number, number], amount: number): [number, number, number] {
  return rgb.map((value) =>
    Math.max(0, Math.min(255, Math.round(value + amount * 255))),
  ) as [number, number, number];
}

function readableAccent(accent: string, background: string, mode: "light" | "dark"): string {
  const fg = parseHex(accent);
  const bg = parseHex(background);
  if (!fg || !bg || contrast(fg, bg) >= 4.5) return accent;

  let current = fg;
  const step = mode === "dark" ? 0.08 : -0.08;
  for (let i = 0; i < 12; i += 1) {
    current = shift(current, step);
    if (contrast(current, bg) >= 4.5) break;
  }
  return `#${current.map((v) => v.toString(16).padStart(2, "0")).join("")}`;
}

/* -------------------------------------------------------------------- 顶栏 */

function Mark() {
  // 直接使用产品图标，使标题栏与任务栏中的图标完全一致。
  return <img className="mark" src="/brand/icon-128.png" alt="" aria-hidden="true" />;
}

function Bar({
  view,
  inRoom,
  onNavigate,
}: {
  view: View;
  inRoom: boolean;
  onNavigate: (view: View) => void;
}) {
  const win = api.isDesktop ? getCurrentWindow() : null;
  return (
    <header className="bar">
      <div className="brand" data-tauri-drag-region>
        <Mark />
        <span>EverGreen LAN</span>
      </div>

      {/* 只有这块空白区域负责拖动窗口：把该属性加在整个栏上，
          会吞掉指向导航按钮的点击。 */}
      <div className="drag-space" data-tauri-drag-region />

      <nav className="nav">
        {/* 没有房间时首页也是可停留的目标，因此需要独立入口；
            否则设置页会成为无法返回的单向入口。 */}
        {inRoom ? (
          <button data-on={view === "room"} onClick={() => onNavigate("room")}>
            房间
          </button>
        ) : (
          <button data-on={view === "home"} onClick={() => onNavigate("home")}>
            首页
          </button>
        )}
        <button data-on={view === "settings"} onClick={() => onNavigate("settings")}>
          设置
        </button>
      </nav>

      <div className="win">
        <button title="最小化" onClick={() => win?.minimize()}>
          –
        </button>
        <button title="最大化" onClick={() => win?.toggleMaximize()}>
          □
        </button>
        <button className="close" title="关闭" onClick={() => win?.close()}>
          ×
        </button>
      </div>
    </header>
  );
}

function Kicker({ left, right }: { left: string; right?: string }) {
  return (
    <div className="kicker">
      <span>{left}</span>
      <span className="rule-out" />
      {right && <span>{right}</span>}
    </div>
  );
}

function StatusLine({ status }: { status: AppStatus | null }) {
  const items = [
    { label: "权限", ok: status?.admin ?? null, value: status === null ? "检测中" : status.admin ? "已提权" : "普通" },
    {
      label: status?.platform === "windows" ? "Wintun" : "TUN",
      ok: status?.wintunPresent ?? null,
      value: status === null ? "检测中" : status.wintunPresent ? "就绪" : "未安装",
    },
    { label: "网卡", ok: status?.adapterUp ?? null, value: status === null ? "—" : status.adapterUp ? "已启用" : "未启用" },
    { label: "协议核心", ok: status?.coreReady ?? null, value: "正常" },
  ];

  return (
    <div className="status">
      {items.map((item) => (
        <span className="item" key={item.label}>
          <i className={item.ok ? "tick" : "tick off"} />
          {item.label} <b>{item.value}</b>
        </span>
      ))}
    </div>
  );
}

/* ---------------------------------------------------------------------- 视图 */

function Home({
  status,
  busy,
  error,
  onCreate,
  onJoin,
  onElevate,
}: {
  status: AppStatus | null;
  busy: boolean;
  error: string | null;
  onCreate: (name: string) => void;
  onJoin: (code: string) => void;
  onElevate: () => void;
}) {
  const [name, setName] = useState("我的森林");
  const [code, setCode] = useState("");

  return (
    <>
      <Kicker left="ZERO-SERVER VIRTUAL LAN" />

      <h1 className="display">
        <span className="line">
          <span>把局域网，</span>
        </span>
        <span className="line">
          <span className="alt">延伸到任何地方。</span>
        </span>
      </h1>

      <p className="lede">
        房间由你创建，流量只在你们之间直连。<strong>没有中转服务器</strong>，也没有第三方能看到你们在玩什么。
      </p>

      <div className="split">
        <div className="rows">
          <div className="row">
            <span className="num">01</span>
            <span className="tag">CREATE</span>
            <div className="field">
              <input
                value={name}
                maxLength={48}
                disabled={busy}
                onChange={(e) => setName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && name.trim()) onCreate(name.trim());
                }}
                placeholder="房间名称"
                aria-label="房间名称"
              />
              <span className="field-line" />
            </div>
            <div className="go">
              <button
                className="btn solid"
                disabled={busy || !name.trim()}
                onClick={() => onCreate(name.trim())}
              >
                创建房间 <span className="arrow">→</span>
              </button>
            </div>
          </div>

          <div className="row">
            <span className="num">02</span>
            <span className="tag">JOIN</span>
            <div className="field">
              <input
                value={code}
                disabled={busy}
                onChange={(e) => setCode(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && code.trim()) onJoin(code.trim());
                }}
                placeholder="粘贴朋友发来的邀请码 EGL1-…"
                aria-label="邀请码"
                spellCheck={false}
              />
              <span className="field-line" />
            </div>
            <div className="go">
              <button
                className="btn"
                disabled={busy || !code.trim()}
                onClick={() => onJoin(code.trim())}
              >
                加入房间 <span className="arrow">→</span>
              </button>
            </div>
          </div>
        </div>

        {error && <p className="alert">{error}</p>}

        <p className="note" style={{ marginTop: 18 }}>
          邀请码就是房间钥匙，等同于密码，不要公开分享。
        </p>

        <StatusLine status={status} />

        {status && !status.admin && (
          <p className="note" style={{ marginTop: 16 }}>
            {status.platform === "macos"
              ? "创建房间需要 root 权限，请在终端用 sudo 启动本程序。"
              : "创建房间需要管理员权限，"}
            {status.platform !== "macos" && (
              <button className="btn text" onClick={onElevate}>
                {status.platform === "linux" ? "提权重启 →" : "以管理员身份重启 →"}
              </button>
            )}
          </p>
        )}
      </div>
    </>
  );
}

function PeerRow({ peer, index }: { peer: Peer; index: number }) {
  return (
    <div className="peer">
      <span className="idx">{String(index).padStart(2, "0")}</span>
      <span className="name">
        {peer.role === "host" && <i className="host-dot" />}
        {peer.name || "未命名"}
      </span>
      <span className="addr">{peer.virtualIp}</span>
      <span className="role">{peer.role === "host" ? "HOST" : "GUEST"}</span>
      <span className="rtt">{peer.rttMs == null ? "—" : `${Math.round(peer.rttMs)} ms`}</span>
    </div>
  );
}

function Room({
  room,
  status,
  onLeave,
  onCopy,
  copied,
}: {
  room: RoomView;
  status: AppStatus | null;
  onLeave: () => void;
  onCopy: () => void;
  copied: boolean;
}) {
  const self: Peer = {
    name: "你",
    virtualIp: room.virtualIp,
    role: room.hosting ? "host" : "guest",
    endpoint: "本机",
    rttMs: null,
  };

  return (
    <>
      <Kicker
        left={room.hosting ? "HOSTING" : "JOINED"}
        right={`${String(room.peers.length + 1).padStart(2, "0")} PEERS`}
      />

      <div className="room-head">
        <div>
          <h1 className="room-title">{room.roomName}</h1>
          <div className="meta">
            <span>
              虚拟地址 <code>{room.virtualIp}</code>
            </span>
            <span>
              指纹 <code>{room.fingerprint}</code>
            </span>
          </div>
        </div>
        <button className="btn text" onClick={onLeave}>
          离开房间
        </button>
      </div>

      <section className="block">
        <span className="block-label">Invite</span>
        <div>
          <div className="block-head">
            <span className="note">把这段发给朋友，对方粘贴后即可直连</span>
            <button className="btn text" onClick={onCopy}>
              {copied ? "已复制" : "复制"}
            </button>
          </div>
          <div className="invite">{room.invite}</div>
          <p className="note" style={{ marginTop: 12 }}>
            候选地址 {room.candidates.join("  ·  ") || "—"}
          </p>
          {!room.reachable && (
            <p className="alert" style={{ marginTop: 10 }}>
              只拿到局域网地址：同一网络的朋友可以直接连，异地朋友连不上。通常是代理软件占用了出口，或 STUN
              被网络阻断。
            </p>
          )}
          {room.hosting && room.firewallOk === false && (
            <p className="alert" style={{ marginTop: 10 }}>
              未能添加 Windows 防火墙入站规则：其他玩家发往本机虚拟网卡的数据包可能被丢弃。
              详情见日志目录。
            </p>
          )}
        </div>
      </section>

      <section className="block last">
        <span className="block-label">Peers</span>
        <div>
          <div className="peers-head">
            <span>No.</span>
            <span>Name</span>
            <span>Address</span>
            <span>Role</span>
            <span style={{ textAlign: "right" }}>RTT</span>
          </div>
          <PeerRow peer={self} index={1} />
          {room.peers.map((p, i) => (
            <PeerRow key={p.virtualIp} peer={p} index={i + 2} />
          ))}
          {room.peers.length === 0 && (
            <p className="empty">还没有其他成员。把邀请码发出去，他们连上后会出现在这里。</p>
          )}
        </div>
      </section>

      <StatusLine status={status} />
    </>
  );
}

function Settings({
  theme,
  onTheme,
  status,
  room,
  builtins,
  custom,
  onImportTheme,
  onRemoveTheme,
  onEditTheme,
  onNewTheme,
  onResetThemes,
  logPath,
  onOpenLog,
}: {
  theme: ThemeId;
  onTheme: (t: ThemeId) => void;
  status: AppStatus | null;
  room: RoomView | null;
  builtins: { id: string; label: string; hint: string }[];
  custom: CustomTheme[];
  onImportTheme: (file: File) => Promise<unknown>;
  onRemoveTheme: (id: string) => void;
  onEditTheme: () => void;
  onNewTheme: () => void;
  onResetThemes: () => void;
  logPath: string | null;
  onOpenLog: () => void;
}) {
  const themeFileRef = useRef<HTMLInputElement>(null);
  const [help, setHelp] = useState<"none" | "json" | "prompt">("none");
  const [importError, setImportError] = useState<string | null>(null);

  async function importFile(file: File | undefined) {
    if (!file) return;
    setImportError(null);
    try {
      await onImportTheme(file);
      setHelp("none");
    } catch (error) {
      setImportError(error instanceof Error ? error.message : String(error));
    } finally {
      // 允许重复导入同一个文件。
      if (themeFileRef.current) themeFileRef.current.value = "";
    }
  }

  return (
    <>
      <Kicker left="PREFERENCES" />
      <h1 className="display display-sm">
        <span className="line">
          <span>设置</span>
        </span>
      </h1>
      <p className="lede">外观、网络与环境。改动会立刻生效，也会被记住。</p>

      <section className="block">
        <span className="block-label">Theme</span>
        <div>
          <div className="theme-grid">
            {builtins.map((t) => (
              <button
                key={t.id}
                className="theme-card"
                data-on={theme === t.id}
                onClick={() => onTheme(t.id)}
              >
                {/* 主题变量挂在色块上，因此卡片标签仍沿用页面自身的配色。 */}
                <span className="swatch" data-theme={t.id}>
                  <i />
                  <b />
                  <u />
                </span>
                <span className="theme-meta">
                  <strong>{t.label}</strong>
                  <em>{t.hint}</em>
                </span>
              </button>
            ))}

            {custom.map((t) => (
              <div className="theme-card theme-card-custom" data-on={theme === `custom:${t.id}`}>
                <button
                  className="theme-pick"
                  onClick={() => onTheme(`custom:${t.id}`)}
                  title={`使用「${t.name}」`}
                >
                  <span
                    className="swatch"
                    style={{
                      background: t.vars["bg"],
                      borderColor: t.vars["rule"] ?? "transparent",
                    }}
                  >
                    <i style={{ background: t.vars["ink"] }} />
                    <b style={{ background: t.vars["ink-soft"] ?? t.vars["ink"] }} />
                    <u style={{ background: t.vars["accent"] }} />
                  </span>
                  <span className="theme-meta">
                    <strong>{t.name}</strong>
                    <em>{t.hint || "自定义"}</em>
                  </span>
                </button>
                <button
                  className="theme-remove"
                  title="移除该主题"
                  aria-label={`移除主题 ${t.name}`}
                  onClick={() => onRemoveTheme(t.id)}
                >
                  ×
                </button>
              </div>
            ))}

            <button className="theme-card theme-card-add" onClick={onNewTheme}>
              <span className="theme-plus" aria-hidden="true">
                +
              </span>
              <span className="theme-meta">
                <strong>新建</strong>
                <em>从空白开始</em>
              </span>
            </button>
          </div>

          <p className="note" style={{ marginTop: 14 }}>
            内置主题也可随时按 1 – 4 切换。
          </p>

          <div className="theme-actions">
            <input
              ref={themeFileRef}
              type="file"
              accept="application/json,.json"
              hidden
              onChange={(event) => void importFile(event.target.files?.[0])}
            />
            <button className="btn text" onClick={() => themeFileRef.current?.click()}>
              导入主题文件
            </button>
            <button className="btn text" onClick={onEditTheme}>
              编辑
            </button>
            <button className="btn text" onClick={() => setHelp(help === "json" ? "none" : "json")}>
              查看格式
            </button>
            <button className="btn text" onClick={() => setHelp(help === "prompt" ? "none" : "prompt")}>
              让 AI 写一个
            </button>
            <button className="btn text" onClick={onResetThemes}>
              重置默认主题
            </button>
          </div>

          {importError && (
            <p className="theme-error" role="alert">
              {importError}
            </p>
          )}

          {help !== "none" && (
            <section className="theme-help">
              <header>
                <span>{help === "json" ? "主题文件格式" : "AI 提示词"}</span>
                <button
                  className="btn text"
                  onClick={() => {
                    const text = help === "json" ? THEME_EXAMPLE : THEME_AI_PROMPT;
                    void navigator.clipboard.writeText(text).catch(() => undefined);
                  }}
                >
                  复制
                </button>
              </header>
              <pre>{help === "json" ? THEME_EXAMPLE : THEME_AI_PROMPT}</pre>
              {help === "json" && (
                <p className="note">
                  另存为 .json 后点「导入主题文件…」；只写 bg 与 ink 也能用，其余沿用内置值。
                </p>
              )}
            </section>
          )}
        </div>
      </section>

      <section className="block">
        <span className="block-label">Network</span>
        <dl className="facts">
          <div>
            <dt>管理员权限</dt>
            <dd>{status?.admin ? "已获得" : "未获得，建房前需要提权"}</dd>
          </div>
          <div>
            <dt>{status?.platform === "windows" ? "Wintun 驱动" : "虚拟网卡后端"}</dt>
            <dd>{status?.wintunPresent ? "已就绪" : "未找到"}</dd>
          </div>
          <div>
            <dt>虚拟网卡</dt>
            <dd>{status?.adapterUp ? "运行中" : "未启用"}</dd>
          </div>
          <div>
            <dt>当前房间</dt>
            <dd>{room ? `${room.roomName} · ${room.virtualIp}` : "无"}</dd>
          </div>
          <div>
            <dt>候选地址</dt>
            <dd>{room ? room.candidates.join(" · ") || "—" : "建房后生成"}</dd>
          </div>
          <div>
            <dt>日志</dt>
            <dd>
              <button className="btn text" onClick={onOpenLog}>
                打开日志目录
              </button>
              {logPath && <p className="note path-line">{logPath}</p>}
            </dd>
          </div>
        </dl>
      </section>

      <section className="block last">
        <span className="block-label">About</span>
        <dl className="facts">
          <div>
            <dt>版本</dt>
            <dd>EverGreen LAN {status?.appVersion ?? "0.1.0"}</dd>
          </div>
          <div>
            <dt>协议</dt>
            <dd>Noise_IKpsk0 · ChaCha20-Poly1305 · X25519</dd>
          </div>
          <div>
            <dt>数据流向</dt>
            <dd>仅点对点，不经任何服务器</dd>
          </div>
          <div>
            <dt>许可</dt>
            <dd>Apache-2.0 · 字体为 SIL Open Font License</dd>
          </div>
        </dl>
      </section>

      <section className="block last">
        <span className="block-label">Support</span>
        <div>
          <button
            className="btn sponsor"
            onClick={() =>
              void api.openUrl("https://ifdian.net/a/aliu-Bruce").catch(() => undefined)
            }
          >
            赞助作者 <span className="arrow">→</span>
          </button>
          <p className="note" style={{ marginTop: 12 }}>
            打开爱发电页面，会交给系统默认浏览器。
          </p>
        </div>
      </section>

      <StatusLine status={status} />
    </>
  );
}

/* ------------------------------------------------------------------------ 应用 */

/// 创建房间前的网络环境提示。
function ProxyNotice({
  onCancel,
  onConfirm,
}: {
  onCancel: () => void;
  onConfirm: (dontShowAgain: boolean) => void;
}) {
  const [dontShow, setDontShow] = useState(false);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onCancel();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onCancel]);

  return (
    <div className="modal-backdrop" role="presentation" onClick={onCancel}>
      <div
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="proxy-notice-title"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="kicker">
          <span>NOTICE</span>
          <span className="rule-out" />
        </div>
        <h2 id="proxy-notice-title" className="modal-title">
          先检查网络环境
        </h2>
        <p className="modal-body">
          为保证最好的联机质量和游戏体验，请确保已关闭 VPN 与代理，或为
          <code>10.66.0.0/16</code> 配置好直连分流。
        </p>
        <p className="note">
          代理的 TUN 模式会抢占虚拟网段的路由，并使 NAT 打洞失效；分流配置正确时不受影响。
        </p>

        <div className="modal-actions">
          <label className="modal-check">
            <input
              type="checkbox"
              checked={dontShow}
              onChange={(event) => setDontShow(event.target.checked)}
            />
            不再提示
          </label>
          <button className="btn text" onClick={onCancel}>
            返回
          </button>
          <button className="btn solid" onClick={() => onConfirm(dontShow)}>
            继续创建 <span className="arrow">→</span>
          </button>
        </div>
      </div>
    </div>
  );
}

/* ---------------------------------------------------------------- 主题编辑器 */

/** 编辑器中可调的六个颜色；其余变量保存时按明暗自动推导。 */
const EDITOR_FIELDS = [
  { key: "bg", label: "背景" },
  { key: "bg-deep", label: "次级背景" },
  { key: "ink", label: "正文" },
  { key: "ink-soft", label: "次级文字" },
  { key: "ink-faint", label: "弱化文字" },
  { key: "accent", label: "强调色" },
] as const;

/** 把计算样式里的颜色统一成 `#rrggbb`，便于 `<input type="color">` 使用。 */
function toHexColor(value: string, fallback: string): string {
  const text = value.trim();
  if (/^#[0-9a-f]{6}$/i.test(text)) return text.toLowerCase();
  const rgb = /rgba?\(\s*(\d+)[,\s]+(\d+)[,\s]+(\d+)/i.exec(text);
  if (!rgb) return fallback;
  return `#${[rgb[1], rgb[2], rgb[3]]
    .map((part) => Number.parseInt(part, 10).toString(16).padStart(2, "0"))
    .join("")}`;
}

/** 读取当前生效主题的颜色，作为编辑器的初始值。 */
function currentThemeColors(): Record<string, string> {
  const style = getComputedStyle(document.documentElement);
  const read = (name: string, fallback: string) =>
    toHexColor(style.getPropertyValue(`--${name}`), fallback);
  return {
    bg: read("bg", "#f2efe5"),
    "bg-deep": read("bg-deep", "#e9e5d8"),
    ink: read("ink", "#17251d"),
    "ink-soft": read("ink-soft", "#3c4a3f"),
    "ink-faint": read("ink-faint", "#7b8578"),
    accent: read("accent", "#1e4d3a"),
  };
}

function withAlpha(hex: string, alpha: number): string {
  const match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
  if (!match) return `rgba(0, 0, 0, ${alpha})`;
  const [r, g, b] = [match[1], match[2], match[3]].map((part) => Number.parseInt(part, 16));
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

/** 标题字体候选：全部是 Windows/macOS 上大概率存在的字体栈。 */
const DISPLAY_FONTS: Record<string, { label: string; font: string; cjk: string }> = {
  sans: { label: "系统无衬线", font: "var(--font-sans)", cjk: "var(--font-cjk-sans)" },
  serif: { label: "衬线 / 宋体", font: "var(--font-serif)", cjk: "var(--font-cjk-serif)" },
  yahei: {
    label: "微软雅黑",
    font: '"Inter Tight", "Segoe UI", system-ui, sans-serif',
    cjk: '"Microsoft YaHei", "PingFang SC", sans-serif',
  },
  source: {
    label: "思源黑体",
    font: '"Inter Tight", system-ui, sans-serif',
    cjk: '"Source Han Sans SC", "Noto Sans SC", "Microsoft YaHei", sans-serif',
  },
  kai: {
    label: "楷体",
    font: '"Instrument Serif", Georgia, serif',
    cjk: '"KaiTi", "STKaiti", "Noto Serif SC", serif',
  },
};

/** 小字与代码使用的等宽字体；都带中文回退，避免汉字落到系统默认字形。 */
const MONO_FONTS: Record<string, { label: string; stack: string }> = {
  plex: {
    label: "IBM Plex Mono",
    stack: '"IBM Plex Mono", "Cascadia Code", Consolas, "Microsoft YaHei UI", monospace',
  },
  cascadia: {
    label: "Cascadia Mono",
    stack: '"Cascadia Code", "Cascadia Mono", Consolas, "Microsoft YaHei UI", monospace',
  },
  consolas: {
    label: "Consolas",
    stack: 'Consolas, "Courier New", "Microsoft YaHei UI", monospace',
  },
  jetbrains: {
    label: "JetBrains Mono",
    stack: '"JetBrains Mono", "Cascadia Code", Consolas, "Microsoft YaHei UI", monospace',
  },
};

/* ---------------------------------------------------------------- 确认弹窗 */

function ConfirmDialog({
  title,
  message,
  confirmLabel,
  danger,
  onCancel,
  onConfirm,
}: {
  title: string;
  message: string;
  confirmLabel: string;
  danger?: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onCancel();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onCancel]);

  return (
    <div className="modal-backdrop" role="presentation" onClick={onCancel}>
      <div
        className="modal modal-narrow"
        role="dialog"
        aria-modal="true"
        aria-labelledby="confirm-title"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="kicker">
          <span>{danger ? "CONFIRM" : "NOTICE"}</span>
          <span className="rule-out" />
        </div>
        <h2 id="confirm-title" className="modal-title">
          {title}
        </h2>
        <p className="modal-body">{message}</p>
        <div className="modal-actions">
          <button className="btn text" onClick={onCancel}>
            取消
          </button>
          <button className={danger ? "btn solid danger" : "btn solid"} onClick={onConfirm}>
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}

function ThemeEditor({
  initial,
  onCancel,
  onSave,
}: {
  initial?: CustomTheme | null;
  onCancel: () => void;
  onSave: (theme: CustomTheme) => void;
}) {
  const [tab, setTab] = useState<"visual" | "json">("visual");
  const [name, setName] = useState(initial?.name ?? "新主题");
  const [hint, setHint] = useState(initial?.hint ?? "自定义 · 无衬线");
  const [mode, setMode] = useState<"light" | "dark">(initial?.mode ?? "light");
  const [colors, setColors] = useState<Record<string, string>>(() => ({
    ...currentThemeColors(),
    ...(initial ? pickColors(initial.vars) : {}),
  }));
  const [font, setFont] = useState<keyof typeof DISPLAY_FONTS>(() =>
    initial?.vars["display-cjk"]?.includes("cjk-serif") ? "serif" : "sans",
  );
  const [mono, setMono] = useState<keyof typeof MONO_FONTS>("plex");
  const [weight, setWeight] = useState(() =>
    Number.parseInt(initial?.vars["display-weight"] ?? "500", 10) || 500,
  );
  const [radius, setRadius] = useState(() => Number.parseInt(initial?.vars["radius"] ?? "2", 10) || 0);
  const [scale, setScale] = useState(() => Number.parseFloat(initial?.vars["text-scale"] ?? "1") || 1);
  const [jsonText, setJsonText] = useState(THEME_EXAMPLE);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const gutter = useRef<HTMLPreElement>(null);

  useEffect(() => {
    setJsonText(THEME_EXAMPLE);
  }, []);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onCancel();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onCancel]);

  const setColor = (key: string, value: string) =>
    setColors((current) => ({ ...current, [key]: value }));

  /** 从表单推导完整变量：分隔线与强调文字色不需要用户手写。 */
  function buildVars(): Record<string, string> {
    const preset = DISPLAY_FONTS[font];
    return {
      ...(initial?.vars ?? {}),
      ...colors,
      "accent-ink": colors.bg,
      rule: withAlpha(colors.ink, mode === "dark" ? 0.12 : 0.14),
      "rule-strong": withAlpha(colors.ink, mode === "dark" ? 0.34 : 0.38),
      alert: mode === "dark" ? "#d98a6a" : "#9c3b2f",
      grain: mode === "dark" ? "0.035" : "0.02",
      radius: `${radius}px`,
      "text-scale": String(scale),
      "font-mono": MONO_FONTS[mono].stack,
      "display-font": preset.font,
      "display-cjk": preset.cjk,
      "display-weight": String(weight),
    };
  }

  /** 桌面端交给 Rust 校验；浏览器预览只做本地构造，供界面走查。 */
  async function toTheme(raw: string, id: string): Promise<CustomTheme> {
    if (api.isDesktop) return api.parseTheme(raw, `${id}.json`);
    const parsed = JSON.parse(raw) as Partial<CustomTheme> & {
      vars?: Record<string, string>;
    };
    return {
      id,
      name: parsed.name ?? "自建",
      hint: parsed.hint ?? "",
      mode: parsed.mode === "dark" ? "dark" : "light",
      vars: parsed.vars ?? {},
    };
  }

  async function save() {
    setError(null);
    setSaving(true);
    try {
      // 编辑已有主题时沿用原 id，保存即覆盖，不会生成副本。
      const id = initial?.id ?? `custom-${Date.now().toString(36)}`;
      const raw =
        tab === "json"
          ? jsonText
          : JSON.stringify({ schemaVersion: 1, name, hint, mode, vars: buildVars() });
      const theme = await toTheme(raw, id);
      onSave(initial ? { ...theme, id } : theme);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }

  const lineCount = Math.max(1, jsonText.split("\n").length);

  return (
    <div className="modal-backdrop" role="presentation" onClick={onCancel}>
      <div
        className="modal modal-wide"
        role="dialog"
        aria-modal="true"
        aria-labelledby="theme-editor-title"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="kicker">
          <span>{initial ? "EDIT THEME" : "NEW THEME"}</span>
          <span className="rule-out" />
        </div>
        <h2 id="theme-editor-title" className="modal-title">
          {initial ? "编辑主题" : "新建主题"}
        </h2>
        {initial && (
          <p className="note" style={{ marginBottom: 6 }}>
            保存会覆盖「{initial.name}」本身；改坏了可以点「重置默认主题」。
          </p>
        )}

        <div className="editor-tabs">
          <button data-on={tab === "visual"} onClick={() => setTab("visual")}>
            可视化
          </button>
          <button data-on={tab === "json"} onClick={() => setTab("json")}>
            JSON
          </button>
        </div>

        <div className="editor-preview" style={{ background: colors.bg, color: colors.ink }}>
          <strong
            style={{
              color: colors.ink,
              fontFamily: `${DISPLAY_FONTS[font].font}, ${DISPLAY_FONTS[font].cjk}`,
              fontWeight: Number(weight),
              borderRadius: radius,
            }}
          >
            {name || "未命名"}
          </strong>
          <span style={{ color: colors.accent }}>{hint || "自定义"}</span>
        </div>

        {tab === "visual" ? (
          <>
            <div className="editor-fields">
              <label>
                <span>名称</span>
                <input value={name} maxLength={24} onChange={(event) => setName(event.target.value)} />
              </label>
              <label>
                <span>说明</span>
                <input value={hint} maxLength={24} onChange={(event) => setHint(event.target.value)} />
              </label>
              <label>
                <span>明暗</span>
                <select
                  value={mode}
                  onChange={(event) => setMode(event.target.value as "light" | "dark")}
                >
                  <option value="light">浅色</option>
                  <option value="dark">深色</option>
                </select>
              </label>
            </div>

            <div className="editor-colors">
              {EDITOR_FIELDS.map((field) => (
                <label key={field.key}>
                  <input
                    type="color"
                    value={colors[field.key] ?? "#000000"}
                    onChange={(event) => setColor(field.key, event.target.value)}
                  />
                  <span>{field.label}</span>
                  <code>{colors[field.key]}</code>
                </label>
              ))}
            </div>

            <div className="editor-fields editor-typography">
              <label>
                <span>标题字体</span>
                <select
                  value={font}
                  onChange={(event) => setFont(event.target.value as keyof typeof DISPLAY_FONTS)}
                >
                  {Object.entries(DISPLAY_FONTS).map(([key, preset]) => (
                    <option key={key} value={key}>
                      {preset.label}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                <span>字重 {weight}</span>
                <input
                  type="range"
                  min={100}
                  max={700}
                  step={100}
                  value={weight}
                  onChange={(event) => setWeight(Number(event.target.value))}
                />
              </label>
              <label>
                <span>小字字体</span>
                <select
                  value={mono}
                  onChange={(event) => setMono(event.target.value as keyof typeof MONO_FONTS)}
                >
                  {Object.entries(MONO_FONTS).map(([key, preset]) => (
                    <option key={key} value={key}>
                      {preset.label}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                <span>圆角 {radius}px</span>
                <input
                  type="range"
                  min={0}
                  max={16}
                  step={1}
                  value={radius}
                  onChange={(event) => setRadius(Number(event.target.value))}
                />
              </label>
              <label>
                <span>字号 {Math.round(scale * 100)}%</span>
                <input
                  type="range"
                  min={0.85}
                  max={MAX_TEXT_SCALE}
                  step={0.05}
                  value={scale}
                  onChange={(event) => setScale(Number(event.target.value))}
                />
              </label>
            </div>
          </>
        ) : (
          <div className="code-editor">
            <pre className="code-gutter" ref={gutter} aria-hidden="true">
              {Array.from({ length: lineCount }, (_, index) => index + 1).join("\n")}
            </pre>
            <textarea
              className="code-area"
              spellCheck={false}
              value={jsonText}
              onChange={(event) => setJsonText(event.target.value)}
              onScroll={(event) => {
                if (gutter.current) gutter.current.scrollTop = event.currentTarget.scrollTop;
              }}
            />
          </div>
        )}

        {error && (
          <p className="theme-error" role="alert">
            {error}
          </p>
        )}

        <div className="modal-actions">
          <span className="note">
            {tab === "json" ? "粘贴完整主题 JSON，保存时校验" : "分隔线、强调文字与颗粒会按明暗自动推导"}
          </span>
          <button className="btn text" onClick={onCancel}>
            取消
          </button>
          <button className="btn solid" onClick={() => void save()} disabled={saving}>
            {saving ? "保存中" : "保存主题"}
          </button>
        </div>
      </div>
    </div>
  );
}

/** 从变量表里取出可供取色器读取的六个颜色。 */
function pickColors(vars: Record<string, string>): Record<string, string> {
  const result: Record<string, string> = {};
  for (const field of EDITOR_FIELDS) {
    const value = vars[field.key];
    if (value) result[field.key] = toHexColor(value, value);
  }
  return result;
}

export default function App() {
  const preview = new URLSearchParams(window.location.search).has("preview");
  const { theme, setTheme, custom, resolve, importTheme, saveTheme, removeTheme, resetThemes } =
    useTheme(preview);
  const [status, setStatus] = useState<AppStatus | null>(null);
  const [room, setRoom] = useState<RoomView | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [logPath, setLogPath] = useState<string | null>(null);
  /** 代理提示待确认时保存待创建的 room 名称。 */
  const [pendingName, setPendingName] = useState<string | null>(null);
  /** 编辑器的打开状态；带上 initial 表示覆盖已有主题。 */
  /** 内置主题的卡片文案；被覆盖时显示用户改过的名字。 */
  const builtinCards = BUILTINS.map((item) => {
    const resolved = resolve(item.id);
    return {
      id: item.id,
      label: resolved?.name ?? item.name,
      hint: resolved?.hint ?? item.hint,
    };
  });
  const [editing, setEditing] = useState<{ initial?: CustomTheme } | null>(null);
  const [deleting, setDeleting] = useState<CustomTheme | null>(null);
  const [resetting, setResetting] = useState(false);
  const [noticeOff, setNoticeOff] = useState(
    () => window.localStorage.getItem("evergreen-lan.proxyNotice") === "off",
  );
  const [showSettings, setShowSettings] = useState(
    () => new URLSearchParams(window.location.search).get("view") === "settings",
  );

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (target && /^(INPUT|TEXTAREA)$/.test(target.tagName)) return;
      const index = Number(event.key) - 1;
      if (index >= 0 && index < THEMES.length) setTheme(THEMES[index].id);
      if (event.key === "Escape") setShowSettings(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [setTheme]);

  useEffect(() => {
    if (preview) {
      setStatus({
        appVersion: "0.1.0",
        admin: true,
        wintunPresent: true,
        adapterUp: new URLSearchParams(window.location.search).has("room"),
        platform: "windows",
        coreReady: true,
      });
      if (new URLSearchParams(window.location.search).has("room")) {
        setRoom({
          roomName: "我的森林",
          invite:
            "EGL1-eJyrVLLJyN3Q8mT0kR5bGZ1xYwq7cHn2VdP9sKfA4uEtLmB6jXoQ3rZgC8vWyN1hS5pTaD0fIkQzMxJwRbYcVnUe2lGtHoPiK7dFsAzXvB4nMq1rTyW6kLc9jZgU3hVeA0pQoTs5mXiD8bRyFnN2wKjL",
          fingerprint: "A1B2C3",
          hosting: true,
          virtualIp: "10.66.0.1",
          candidates: ["192.168.31.69:49851", "115.171.254.194:55964"],
          reachable: true,
          firewallOk: true,
          peers: [
            { name: "Alice", virtualIp: "10.66.0.2", role: "guest", endpoint: "203.0.113.7:41234", rttMs: 23 },
            { name: "Bob", virtualIp: "10.66.0.3", role: "guest", endpoint: "198.51.100.9:51234", rttMs: 78 },
          ],
        });
      }
      return;
    }
    api.status().then(setStatus).catch((e) => setError(String(e)));
    api.roomState().then(setRoom).catch(() => undefined);
    api.logFilePath().then(setLogPath).catch(() => undefined);
  }, [preview]);

  const inRoom = room !== null;

  useEffect(() => {
    setStatus((current) => (current ? { ...current, adapterUp: inRoom } : current));
  }, [inRoom]);

  useEffect(() => {
    if (!inRoom || preview) return;
    const timer = window.setInterval(() => {
      api
        .roomState()
        .then((next) => next && setRoom(next))
        .catch(() => undefined);
    }, 1500);
    return () => window.clearInterval(timer);
  }, [inRoom, preview]);

  const run = useCallback(async (action: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await action();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, []);

  const createRoom = (name: string) =>
    run(async () => {
      setRoom(await api.createRoom(name));
      setShowSettings(false);
    });

  /** 创建房间前先确认网络环境；提示被永久关闭时直接创建。 */
  const requestCreate = (name: string) => {
    if (noticeOff) {
      void createRoom(name);
      return;
    }
    setPendingName(name);
  };

  const confirmCreate = (dontShowAgain: boolean) => {
    const name = pendingName;
    setPendingName(null);
    if (dontShowAgain) {
      window.localStorage.setItem("evergreen-lan.proxyNotice", "off");
      setNoticeOff(true);
    }
    if (name) void createRoom(name);
  };

  const joinRoom = (code: string) =>
    run(async () => {
      setRoom(await api.joinRoom(code));
      setShowSettings(false);
    });

  const leaveRoom = () =>
    run(async () => {
      await api.leaveRoom();
      setRoom(null);
      setShowSettings(false);
    });

  const copyInvite = async () => {
    if (!room) return;
    try {
      await navigator.clipboard.writeText(room.invite);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      setError("无法写入剪贴板，请手动选中邀请码复制。");
    }
  };

  const elevate = () =>
    run(async () => {
      await api.relaunchElevated();
    });

  const navigate = (next: View) => {
    setShowSettings(next === "settings");
  };

  const view: View = showSettings ? "settings" : room ? "room" : "home";

  return (
    <div className="shell">
      <Bar view={view} inRoom={inRoom} onNavigate={navigate} />
      <main className="page">
        <div className="page-inner" key={view}>
          {view === "settings" && (
            <Settings
              theme={theme}
              onTheme={setTheme}
              status={status}
              room={room}
              builtins={builtinCards}
              custom={custom}
              onImportTheme={importTheme}
              onRemoveTheme={(id) => {
                const target = custom.find((item) => item.id === id);
                if (target) setDeleting(target);
              }}
              onEditTheme={() => setEditing({ initial: resolve(theme) })}
              onNewTheme={() => setEditing({})}
              onResetThemes={() => setResetting(true)}
              logPath={logPath}
              onOpenLog={() => void api.openLogFolder().catch(() => undefined)}
            />
          )}
          {view === "room" && room && (
            <Room
              room={room}
              status={status}
              onLeave={leaveRoom}
              onCopy={copyInvite}
              copied={copied}
            />
          )}
          {view === "home" && (
            <Home
              status={status}
              busy={busy}
              error={error}
              onCreate={requestCreate}
              onJoin={joinRoom}
              onElevate={elevate}
            />
          )}
          {!api.isDesktop && !preview && (
            <p className="note" style={{ marginTop: 26 }}>
              浏览器预览：网络与虚拟网卡功能需要在桌面端运行。
            </p>
          )}
        </div>
      </main>

      {pendingName !== null && (
        <ProxyNotice onCancel={() => setPendingName(null)} onConfirm={confirmCreate} />
      )}

      {editing && (
        <ThemeEditor
          initial={editing.initial}
          onCancel={() => setEditing(null)}
          onSave={(next) => {
            saveTheme(next);
            setEditing(null);
          }}
        />
      )}

      {deleting && (
        <ConfirmDialog
          title="删除这个主题？"
          message={`「${deleting.name}」会被立即移除，无法撤销。内置的四个主题不受影响。`}
          confirmLabel="删除"
          danger
          onCancel={() => setDeleting(null)}
          onConfirm={() => {
            removeTheme(deleting.id);
            setDeleting(null);
          }}
        />
      )}

      {resetting && (
        <ConfirmDialog
          title="重置默认主题？"
          message={`所有自定义主题（当前 ${custom.length} 个）都会被删除，界面回到默认的 Pine。此操作无法撤销。`}
          confirmLabel="重置"
          danger
          onCancel={() => setResetting(false)}
          onConfirm={() => {
            resetThemes();
            setResetting(false);
          }}
        />
      )}
    </div>
  );
}

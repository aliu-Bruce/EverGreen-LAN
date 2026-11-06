// UI 冒烟测试：在 Edge 中驱动构建后的前端，验证截图无法证明的部分——
// 导航与主题选择器确实可用。
//
//   node scripts/ui-check.mjs [baseUrl]
//
// 依赖 Vite 预览服务器（`npx vite preview --port 4173`）。

import { chromium } from "playwright-core";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

const base = process.argv[2] ?? "http://localhost:4173";
const shots = join(process.cwd(), "artifacts", "ui");
mkdirSync(shots, { recursive: true });

const results = [];
const check = (name, ok, detail = "") => {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
};

const browser = await chromium.launch({ channel: "msedge", headless: true });
const page = await browser.newPage({ viewport: { width: 1120, height: 780 } });

page.on("pageerror", (err) => console.log(`page error: ${err.message}`));

// 1. 首页渲染。
await page.goto(`${base}/?theme=paper&preview=1`, { waitUntil: "networkidle" });
await page.waitForTimeout(400);
check("首页标题", (await page.locator("h1.display").innerText()).includes("把局域网"));

// 1b. 全新会话（无本地偏好）应当落在默认主题 Pine 上。
{
  const fresh = await browser.newContext({ viewport: { width: 1120, height: 780 } });
  const freshPage = await fresh.newPage();
  await freshPage.goto(`${base}/?preview=1`, { waitUntil: "networkidle" });
  await freshPage.waitForTimeout(500);
  const applied = await freshPage.locator("html").getAttribute("data-theme");
  check("首次启动默认 Pine", applied === "pine", String(applied));
  await fresh.close();
}

// 2. 导航：设置页不应成为无法返回的单向入口。
await page.getByRole("button", { name: "设置" }).click();
await page.waitForTimeout(500);
const settingsHeading = await page.locator("h1.display-sm").innerText().catch(() => "");
check("点击「设置」进入设置页", settingsHeading.trim() === "设置", settingsHeading.trim());

await page.getByRole("button", { name: "首页" }).click();
await page.waitForTimeout(500);
const backHome = await page.locator("h1.display").innerText().catch(() => "");
check("点击「首页」返回首页", backHome.includes("把局域网"), backHome.replace(/\s+/g, " ").slice(0, 12));

await page.getByRole("button", { name: "设置" }).click();
await page.waitForTimeout(400);

// 3. 设置页内的主题选择器。
const cards = page.locator(".theme-card");
const builtinCards = page.locator(".theme-card .swatch[data-theme]");
check("设置页有四张内置主题卡", (await builtinCards.count()) === 4, String(await builtinCards.count()));
check("自定义主题也会列出", (await cards.count()) >= 5, String(await cards.count()));

await page.locator(".theme-card", { hasText: "Noir" }).click();
await page.waitForTimeout(450);
check("点击 Noir 切换主题", (await page.locator("html").getAttribute("data-theme")) === "noir");
await page.screenshot({ path: join(shots, "settings-noir.png") });

// 自定义主题以内联变量覆盖内置配色。
await page.locator(".theme-card", { hasText: "海盐" }).click();
await page.waitForTimeout(450);
const customState = await page.evaluate(() => ({
  theme: document.documentElement.dataset.theme,
  bg: document.documentElement.style.getPropertyValue("--bg"),
  scheme: document.documentElement.style.colorScheme,
}));
check("自定义主题以 paper 为底并写入内联变量", customState.theme === "paper" && customState.bg === "#eef3f6", JSON.stringify(customState));
check("自定义主题声明 color-scheme", customState.scheme === "light", customState.scheme);

// 回到内置主题，便于验证持久化。
await page.keyboard.press("3");
await page.waitForTimeout(350);

// 4. 选择在刷新后保留（localStorage）。刷新会丢弃 ?theme= 覆盖值，
//    这与普通启动时的表现一致。
await page.goto(`${base}/?preview=1`, { waitUntil: "networkidle" });
await page.waitForTimeout(350);
check("刷新后主题保留", (await page.locator("html").getAttribute("data-theme")) === "noir");

// 5. 返回浅色主题，并确认界面外壳中不存在任意编号
//    （kicker 不应带有无意义的「NO. 001」）。
await page.getByRole("button", { name: "设置" }).click();
await page.waitForTimeout(400);
await page.locator(".theme-card", { hasText: "Paper" }).click();
await page.waitForTimeout(400);
await page.getByRole("button", { name: "首页" }).click();
await page.waitForTimeout(500);
check("设置页可返回首页", (await page.locator("h1.display").innerText()).includes("把局域网"));
check(
  "界面不含无意义编号",
  !(await page.locator(".kicker").first().innerText()).includes("NO."),
  await page.locator(".kicker").first().innerText(),
);
await page.screenshot({ path: join(shots, "home-paper.png") });

// 6. 键盘快捷键在输入框之外仍然生效。
await page.keyboard.press("3");
await page.waitForTimeout(350);
check("数字键切换主题", (await page.locator("html").getAttribute("data-theme")) === "noir");

// 7. 回到浅色主题，并验证创建房间前的网络环境提示。
await page.keyboard.press("1");
await page.waitForTimeout(350);
await page.locator(".row").first().getByRole("button", { name: /创建房间/ }).click();
await page.waitForTimeout(500);
const modal = page.locator(".modal");
check("创建房间先弹出代理提示", await modal.isVisible());
const modalText = (await modal.innerText()).replace(/\s+/g, " ");
check(
  "提示包含关键信息",
  modalText.includes("关闭 VPN") && modalText.includes("10.66.0.0/16"),
  modalText.slice(0, 40),
);
await page.screenshot({ path: join(shots, "proxy-notice.png") });
await modal.getByRole("button", { name: "返回" }).click();
await page.waitForTimeout(300);
check("可取消提示", (await page.locator(".modal").count()) === 0);

// 8. 设置页应当给出主题导入入口与日志位置。
await page.getByRole("button", { name: "设置" }).click();
await page.waitForTimeout(400);
const settingsText = await page.locator(".page-inner").innerText();
check("设置页有导入入口", settingsText.includes("导入主题文件"));
check("设置页有日志入口", settingsText.includes("打开日志目录"));

// 9. 格式说明直接在界面上展示，不依赖主题目录里的示例文件。
await page.getByRole("button", { name: "查看格式" }).click();
await page.waitForTimeout(400);
const help = page.locator(".theme-help");
check("可展开主题格式说明", await help.isVisible());
const helpText = await help.innerText();
check("格式说明包含字段示例", helpText.includes("schemaVersion") && helpText.includes("vars"));
await page.screenshot({ path: join(shots, "theme-help.png") });

await page.getByRole("button", { name: "让 AI 写一个" }).click();
await page.waitForTimeout(400);
const promptText = await page.locator(".theme-help").innerText();
check("可查看 AI 提示词", promptText.includes("风格描述"), promptText.slice(0, 20));

// 10. 内置主题为 Paper / Ice / Noir / Pine，Pine 是深绿。
const cardLabels = await page.locator(".theme-card strong").allInnerTexts();
check(
  "内置主题为 Paper / Ice / Noir / Pine",
  ["PAPER", "ICE", "NOIR", "PINE"].every((name) =>
    cardLabels.some((label) => label.toUpperCase() === name),
  ),
  cardLabels.join(","),
);
await page.locator(".theme-card", { hasText: "PINE" }).click();
await page.waitForTimeout(450);
check("Pine 使用深色底", await page.evaluate(() => {
  const bg = getComputedStyle(document.documentElement).getPropertyValue("--bg").trim();
  return bg.toLowerCase() === "#12281e";
}));

// 11. 新建卡片是虚线框 + 加号，点开是「新建主题」。
// 预览模式自带一张示例自定义主题，后续断言都以它的数量为基准。
const seedCount = await page.locator(".theme-card-custom").count();
check("存在新建主题的虚线卡", (await page.locator(".theme-card-add").count()) === 1);
await page.locator(".theme-card-add").click();
await page.waitForTimeout(600);
check("新建打开空白编辑器", (await page.locator(".modal-title").innerText()).includes("新建"));
check(
  "编辑器有字体与滑杆",
  (await page.locator(".editor-typography select").count()) === 2 &&
    (await page.locator('.editor-typography input[type="range"]').count()) === 3,
);
await page.locator(".editor-fields input").first().fill("新建主题");
await page.locator('input[type="range"]').nth(1).fill("8");
await page.locator('input[type="range"]').nth(2).fill("1.2");
await page.screenshot({ path: join(shots, "theme-editor.png") });
await page.getByRole("button", { name: "保存主题" }).click();
await page.waitForTimeout(700);
check("新建后多出一张自定义卡", (await page.locator(".theme-card-custom").count()) === seedCount + 1);
check(
  "圆角、字体与字号写入变量",
  await page.evaluate(() => {
    const style = document.documentElement.style;
    return (
      style.getPropertyValue("--radius") === "8px" &&
      style.getPropertyValue("--text-scale") === "1.2"
    );
  }),
);
check(
  "下划线按钮不得出现圆角",
  await page.evaluate(() => {
    const btn = document.querySelector(".btn.text");
    return btn ? getComputedStyle(btn).borderTopLeftRadius === "0px" : false;
  }),
);

// 12. 编辑当前主题会覆盖它，不产生副本。
await page.getByRole("button", { name: "编辑" }).click();
await page.waitForTimeout(500);
check("编辑打开的是已有主题", (await page.locator(".modal-title").innerText()).includes("编辑"));
await page.locator(".editor-fields input").first().fill("改过的主题");
await page.getByRole("button", { name: "保存主题" }).click();
await page.waitForTimeout(700);
check("编辑后卡片数量不变", (await page.locator(".theme-card-custom").count()) === seedCount + 1);
check(
  "覆盖的是同一个主题",
  (await page.locator(".theme-card-custom", { hasText: "改过的主题" }).count()) === 1,
);

// 13. 删除需要确认。
check(
  "删除按钮常驻可见",
  await page.evaluate(() => {
    const btn = document.querySelector(".theme-remove");
    return btn ? Number(getComputedStyle(btn).opacity) > 0.2 : false;
  }),
);
await page.locator(".theme-remove").first().click();
await page.waitForTimeout(450);
check("删除前弹出确认", await page.locator(".modal-narrow").isVisible());
await page.screenshot({ path: join(shots, "delete-confirm.png") });
await page.locator(".modal-narrow").getByRole("button", { name: "删除" }).click();
await page.waitForTimeout(600);
check("确认后主题被移除", (await page.locator(".theme-card-custom").count()) === seedCount);

// 14. JSON 分页同样可保存。
await page.locator(".theme-card-add").click();
await page.waitForTimeout(500);
await page.locator(".editor-tabs button", { hasText: "JSON" }).click();
await page.waitForTimeout(500);
const gutterLines = (await page.locator(".code-gutter").innerText()).trim().split("\n").length;
check("JSON 分页显示行号", gutterLines >= 10, String(gutterLines));
await page.screenshot({ path: join(shots, "theme-editor-json.png") });
await page.locator(".code-area").fill(
  JSON.stringify(
    {
      schemaVersion: 1,
      name: "粘贴",
      mode: "light",
      vars: { bg: "#fbf7ef", ink: "#241d16", accent: "#8a5a2b" },
    },
    null,
    2,
  ),
);
await page.getByRole("button", { name: "保存主题" }).click();
await page.waitForTimeout(700);
check("JSON 粘贴保存生效", (await page.locator(".theme-card-custom").count()) === seedCount + 1);

// 15. 内置主题也能被覆盖：编辑 Pine 后不新增卡片，名称被替换。
await page.locator(".theme-card", { hasText: "PINE" }).click();
await page.waitForTimeout(400);
await page.getByRole("button", { name: "编辑" }).click();
await page.waitForTimeout(500);
check("内置主题也能进入编辑", (await page.locator(".modal-title").innerText()).includes("编辑"));
const scaleMax = await page
  .locator('.editor-typography input[type="range"]')
  .nth(2)
  .getAttribute("max");
check("字号上限为 130%", scaleMax === "1.3", String(scaleMax));
await page.locator(".editor-fields input").first().fill("测试内置");
await page.locator('input[type="range"]').first().fill("600");
await page.getByRole("button", { name: "保存主题" }).click();
await page.waitForTimeout(700);
const builtinCount = await page
  .locator(".theme-card:not(.theme-card-custom):not(.theme-card-add)")
  .count();
check("覆盖内置主题不新增卡片", builtinCount === 4, String(builtinCount));
check(
  "覆盖后的名称出现在卡片上",
  (await page.locator(".theme-card-custom").count()) === seedCount + 1 &&
    (await page.locator(".theme-card", { hasText: "测试内置" }).count()) === 1,
);
check(
  "字重可自由调整",
  (await page.evaluate(() =>
    document.documentElement.style.getPropertyValue("--display-weight"),
  )) === "600",
);

// 16. 重置默认主题需要确认，确认后自定义主题清空、内置主题回到源文件。
await page.getByRole("button", { name: "重置默认主题" }).click();
await page.waitForTimeout(450);
check("重置前弹出确认", await page.locator(".modal-narrow").isVisible());
await page.screenshot({ path: join(shots, "reset-confirm.png") });
await page.locator(".modal-narrow").getByRole("button", { name: "重置" }).click();
await page.waitForTimeout(600);
check("重置后自定义主题清空", (await page.locator(".theme-card-custom").count()) === 0);
check("重置后回到 Pine", (await page.locator("html").getAttribute("data-theme")) === "pine");
check(
  "重置恢复内置主题原名",
  (await page.locator(".theme-card", { hasText: "PINE" }).count()) === 1 &&
    (await page.locator(".theme-card", { hasText: "测试内置" }).count()) === 0,
);

await browser.close();

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
process.exit(failed.length === 0 ? 0 : 1);

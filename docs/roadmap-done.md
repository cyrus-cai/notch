# Notch — 已完成归档

> `docs/ROADMAP.md` 的配套归档：已完成的工作从看板移到这里，让 roadmap 只保留
> 「还没做的」。两类内容：
>
> - **已实现 · 待发布** — 代码已落地、构建通过，但尚未随版本发布。发版后把对应
>   条目并入下方 **Shipped**。
> - **Shipped（已发布）** — 已完成并发布，最新在最上面。与 `WhatsNewService`
>   的 changelog 保持一致（原先这条同步约定在 roadmap.md，随 Shipped 段一并迁来）。
>
> 维持 roadmap.md 的格式：中文，条目
> `- [x] **标题** — 一句话。` 附 `(size: S/M/L)` 与 `(file: X.swift)`。

---

## 已实现 · 待发布

> 代码已落地、构建通过，等下一个版本发布。发版时把这些并入 Shipped。

- [x] **流式输出 UI 接线** — `AIService.stream()` 与 `Turn.streaming` 已就位，
  缺 UI 消费流式 chunk；逐字出现直接兑现「5× 更快」。配 80ms opacity 淡入。
  ✅ 已实现：新增 `StreamingMarkdown`，流式态只对在涨的尾块做 80ms opacity 淡入、
  逐字浮现；头部已落定块不重渲，答案落定后照旧可选可复制。
  (size: S) (file: Components.swift, NotchBody.swift)
- [x] **修 HistoryItem 解码炸弹** — `loadHistory()` 单次 `try?` 解码整列表，
  任一 item 缺 `decodeIfPresent` 就静默清空 Recent。改逐条解码、跳过失败项。
  ✅ 已实现：新增 `LossyArray`/`LossyElement`，逐条解码跳过失败项。
  (size: S) (file: NotchModel.swift)
- [x] **修 Note/Reminder 失败静默丢数据** — `submitNote/submitReminder` 失败后
  仅凭 `text.isEmpty` 决定恢复，用户已打下一条则原文无声消失。改为内联报错展示原文。
  ✅ 已实现：抽出 `reportCaptureFailure`，已有新草稿时把失败原文折进内联报错。
  (size: S) (file: NotchModel.swift)
- [x] **修 CJK 输入法候选窗口与 NSPanel 层级冲突** `R3` — 高 window level 的刘海面板
  会盖住中/日/韩输入法候选窗，中文用户打字时选词框被遮或错位，输入直接不可用。
  *已修：编辑态把面板从 `.statusBar` 降到 `.floating`（候选窗在两者之间），编辑结束/
  关闭面板还原；多个输入框用引用计数共享。仍待实机多输入法验证。*
  (size: M) (file: NotchPanel.swift, Components.swift, AppDelegate.swift)
- [x] **修 UpdaterService 回滚洞** `R2` — `swapBundle` 两步回滚都用 `try?` 吞错，
  ditto 失败可致 `/Applications/Notch.app` 被删且回滚失败＝App 物理消失。改 try+上抛。
  **CTO 力主 P1**。
  ✅ 已实现：回滚改 `try`+上抛——恢复旧 bundle 失败时抛新增的
  `UpdateError.rollbackFailed(swap:rollback:)`（带原始 swap 失败与回滚失败两个错误），
  不再吞错；恢复成功则原样上抛 swap 失败。
  (size: S) (file: UpdaterService.swift)
- [x] **修流式中途断网对话消失** `R2` — detached task 在首 chunk 后断流，catch 走
  `isOnScreen=false` 分支静默丢弃，`persistThread` 不被调用＝提问从 Recent 消失。
  弱网高频。**CTO 力主 P1**。
  ✅ 已实现：`acc` 提到 `do` 外；error catch 分两路——已有 partial 文本则照常
  `persistThread`（无论是否在屏），并给答案打 `error.interrupted` 标记；零文本失败
  才保留旧的 generic error / 丢弃逻辑。
  (size: M) (file: NotchModel.swift submit())
- [x] **ThinkingDots 到流式首字的过渡** `R3` — 思考点跳到首个 token 出现时是硬切；
  做一个点淡出、首字淡入的衔接。**依赖「流式输出 UI 接线」P1 先落地**。
  ✅ 已实现：新增 `StreamingTurnContent`，把思考点与流式答案放进同一 ZStack，首个
  token 落地时点淡出、首字淡入交叉过渡（120ms）。
  (size: S) (file: Components.swift, NotchBody.swift)

## Shipped（已发布）

### 1.0.5
- 复制的引用文本直接在 prompt 内预览，不再折叠 Recent。
- 芯片悬停展开。
- 提升 Notes 保存可靠性。

### 1.0.x（更早）
- 内置「What's New」面板。
- 双向翻译。
- 意图分类器 + 自动路由（用内联提示替代 Tab 切换模式）。
- 一行 `curl` 安装脚本 + 发布自动化。
- 落地页重做（金门大桥壁纸、Liquid Glass 打磨）。

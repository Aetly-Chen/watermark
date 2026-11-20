# Design System: 水印工坊

> 本地优先的端侧图片与视频去水印工具设计系统。所有颜色、排版、组件状态与交互规范均以 `app/lib/core/theme/app_tokens.dart` 与 `app/lib/core/theme/app_theme.dart` 为唯一事实来源。

---

## 1. 视觉主题与氛围

**温暖精准的工作台（Warm Precision Workbench）**：避免冷峻纯黑或刺眼荧光蓝等泛用型工具界面配色，以纸张质感的中性暖色调搭配克制的工艺焦橙作为视觉锚点，在保持专业工具精确感的同时提供柔和耐看的长时间编辑体验。

- **浅色模式（奶油工作台）**：以奶油白（`#F4EFE5`）作为画布与页面基座，纸白（`#FFFDF8`）承载信息卡片与操作面板，焦橙（`#C4551B`）聚焦主行动入口与激活状态，呈现温暖干净的纸面质感。
- **深色模式（暗墨工坊）**：以暗墨（`#14120E`）为页面底色，深棕炭纸（`#1D1A14`）抬升内容层级，琥珀焰（`#E2762F`）在低亮度环境下提供清晰可辨的焦点高亮，避免纯黑死板对比与灰阶塌陷。
- **媒体画布隔离**：图片与视频编辑、预览及全屏对比区域始终使用偏暗的 `media` 舞台底色（浅色 `#2A2620` / 深色 `#0B0A08`），确保图像色彩判断不受日夜间界面底色干扰。

---

## 2. 色彩系统与语义角色

UI 层严禁硬编码颜色值，必须通过 `AppTokens.of(context)` 读取语义令牌，使浅色/深色模式可随 `ThemeMode` 平滑插值过渡。

### 2.1 色彩令牌总览

| Token 名称 | 浅色模式（自然语言 / Hex） | 深色模式（自然语言 / Hex） | 语义角色与适用场景 |
| --- | --- | --- | --- |
| `cream` | 奶油白 `#F4EFE5` | 暗墨 `#14120E` | 页面脚手架（Scaffold）与 AppBar 主背景底色 |
| `paper` | 纸白 `#FFFDF8` | 深棕炭纸 `#1D1A14` | 卡片、面板、对话框（`dialogTheme`）、底栏（`AppShell`）及次级按钮表面底色 |
| `ink` | 炭黑 `#1B1A17` | 柔米白 `#F2EDE2` | 一级标题、核心正文、主图标与高对比前景 |
| `ink2` | 暖灰褐 `#5A544B` | 浅暖灰 `#B4AA9A` | 二级说明文案、未选中工具标签与次级分段文字 |
| `ink3` | 淡褐灰 `#6E6659` | 暗暖灰 `#8F8676` | 三级辅助文字、占位提示、未选中底栏项与关闭态开关滑块 |
| `line` | 浅米边线 `#E3DACA` | 暗褐边线 `#332D23` | 卡片描边、分割线、分段控件外框与未选中滑块轨道 |
| `line2` | 极浅米线 `#EFE8DA` | 极暗褐线 `#272219` | 次级细分隔线与弱轮廓边界 |
| `flame` | 焦橙 `#C4551B` | 琥珀焰 `#E2762F` | 唯一主行动按钮、主开关选中轨道、进度环、滑块激活轨道、核心分段选中态、对比手柄描边 |
| `flameTxt` | 深焦橙 `#9E4410` | 亮琥珀 `#E8935A` | 小字号强调文字与高亮图标（在浅色模式下加深以满足对比度） |
| `flameSoft` | 柔杏橙 `#F7E4D4` | 深焦糖褐 `#3A2413` | 强调色浅底：底栏选中指示胶囊、工具 Chip 选中底色、次级品牌徽章底 |
| `media` | 深暖炭 `#2A2620` | 纯黑墨 `#0B0A08` | 图片/视频编辑舞台、视频预览弹窗及全屏对比弹窗不透明暗底 |
| `danger` | 砖红 `#A3301F` | 暖珊瑚红 `#E0705C` | 校验失败、保存/修复错误横幅与危险语义 |
| `onFlame` | 纸白 `#FFFDF8` | 暗墨 `#14120E` | 叠加在 `flame` 实底之上的文字与图标颜色（主按钮、主题选中项、对比分段选中项） |
| `track` | 暖沙凹槽 `#EAE2D3` | 深凹槽黑 `#1A1712` | 分段控件凹槽底色、设置图标小底块与关闭态开关轨道 |
| `surfaceElevated` | 浮起纸白 `#FFFDF8` | 浮起暖褐 `#2E2820` | 浮起态表面与次级分段选中滑块底色（如历史筛选分段选中项，确保深色下高于 `track` 层级） |
| `hoverTint` | 焦橙 10% 暖调遮罩 `#1AC4551B` | 琥珀焰 15% 暖调遮罩 `#26E2762F` | 全局与可点击组件的悬停（Hover）、聚焦（Focus）与轻量按压反馈遮罩 |

### 2.2 静态空间度量（`AppTokens` 常量）

- **圆角**：卡片 `radiusCard = 16dp`、按钮与工具芯片 `radiusButton = 12dp`、胶囊标签 `radiusChip = 999dp`、弹窗 `20dp`（全屏对比弹窗除外，采用 `EdgeInsets.zero` 直角满屏）。
- **间距**：页边距 `gutter = 16dp`、紧凑间距 `gapS = 8dp`、常规间距 `gapM = 12dp`、区块间距 `gapL = 20dp`。

---

## 3. 排版规范

使用系统默认中英文无衬线字体栈，强调清晰字阶区分与等宽数字稳定性：

### 3.1 字体层级（`AppTheme._textTheme`）

| 层级 | 字号 | 行高 | 字重 | 字距 | 颜色令牌 | 用途 |
| --- | --- | --- | --- | --- | --- | --- |
| `displaySmall` | `28sp` | `1.25` | `w700` | `-0.4` | `ink` | 大标题展示 |
| `titleLarge` | `19sp` | `1.35` | `w600` | — | `ink` | 品牌顶栏与主区块标题 |
| `AppBar Title` | `17sp` | — | `w600` | `0.2` | `ink` | 二级页面顶栏标题 |
| `titleMedium` | `16sp` | `1.40` | `w600` | — | `ink` | 卡片标题、分组抬头 |
| `bodyLarge` | `15sp` | `1.60` | `w400` | — | `ink` | 主要说明与列表主行 |
| `labelLarge` | `14sp` | — | `w600` | — | `ink` | 按钮标签与强操作文本 |
| `bodyMedium` | `13.5sp` | `1.55` | `w400` | — | `ink2` | 辅助说明与摘要文本 |
| `bodySmall` | `12sp` | `1.50` | `w400` | — | `ink3` | 元信息、时间戳与版权小字 |

### 3.2 数字等宽对齐（`tabnum`）

所有动态变化或横向并排对比的数值（视频播放进度与总时长 `00:00`、全屏对比缩放倍率 `2.0×`、画笔尺寸与修复强度读数、处理耗时与文件体积）均启用 `FontFeature.tabularFigures()`，避免数值跳动引起控制条微颤。

---

## 4. 组件样式与交互态

所有全局与局部可点击组件均遵循「暖调反馈」原则（禁止默认冷灰悬停遮罩），并在 `Material` 上绘制 `InkWell` 以确保悬停态与水波纹位于底色之上。

### 4.1 全局主题交互与基础控件（`AppTheme`）

- **全局水波纹与悬停**：`hoverColor: t.hoverTint`、`focusColor: t.hoverTint`、`highlightColor: t.flame.withValues(alpha: 0.08)`、`splashColor: t.flame.withValues(alpha: 0.12)`。
- **IconButton / TextButton**：统一圆角 `10dp`，悬浮/聚焦叠加 `t.hoverTint`，按压叠加 `t.flame.withValues(alpha: 0.14)`；`TextButton` 默认前景色为 `t.flameTxt`。
- **Switch**：选中轨道 `t.flame` + 滑块 `t.onFlame`；未选中轨道 `t.track` + 描边 `t.line` + 滑块 `t.ink3`；暖调 `overlayColor`。
- **Slider**：细轨道 `3dp`，`activeTrackColor: t.flame`、`inactiveTrackColor: t.line`、`thumbColor: t.flame`、`overlayColor: t.hoverTint`（视频预览弹窗内压缩为 `2dp` 细条并适配暗底）。
- **SnackBar**：`SnackBarBehavior.floating` 悬浮圆角条（圆角 `12dp`，`t.ink` 底配 `t.paper` 字）。
- **Dialog**：圆角 `20dp`，`backgroundColor: t.paper`，`surfaceTintColor: Colors.transparent`。

### 4.2 底部导航栏（`AppShell`）

- 高度固定 `60dp`，顶部分隔线 `t.line`，背景 `t.paper`。
- 通过 `NavigationBarTheme` 统一定制：选中指示胶囊 `t.flameSoft`、选中标签 `t.flameTxt`（`w600` 加粗）配选中图标 `t.flameTxt`、未选中标签与图标 `t.ink3`、`overlayColor` 在悬停/聚焦时采用 `t.hoverTint`。

### 4.3 按钮与卡片（`AppButton` / `AppCard`）

- **`AppButton`**：默认高度 `48dp`，圆角 `12dp`：
  - `primary`（焦橙实底，一屏仅主操作使用）：背景 `t.flame`、文字 `t.onFlame`，`hoverColor` / `highlightColor` 为 `t.onFlame.withValues(alpha: 0.12)`、`splashColor` 为 `t.onFlame.withValues(alpha: 0.18)`。
  - `secondary`（纸面描边）：背景 `t.paper`、描边 `t.line`、文字 `t.ink`，悬停/按压均使用 `t.hoverTint`。
  - `ghost`（轻量文字操作）：透明底、文字 `t.flameTxt`，悬停/按压使用 `t.hoverTint`。
  - 禁用态整体透明度降至 `0.45`。
- **`AppCard`**：圆角 `16dp`、`t.paper` 底色 + `1px` `t.line` 描边。**仅当 `onTap != null` 时启用 `InkWell`**（`hoverColor: t.hoverTint`、`splashColor: t.flame.withValues(alpha: 0.10)`、`highlightColor: t.flame.withValues(alpha: 0.06)`），静态展示卡不承载悬停与焦点反馈。

### 4.4 工具选择芯片（`MaskToolChip`）

- 单层 `Material` + `InkWell(onTap: onTap, hoverColor: t.hoverTint)`，禁用态以整体 `Opacity(opacity: 0.42)` 表达，不外包多余 `GestureDetector` 以确保辅助检查与无障碍点击语义纯粹。
- 选中态：`t.flameSoft` 底色 + `1.2px` `t.flame` 描边 + `t.flameTxt` 图标与加粗文案；未选中态：`t.paper` 底色 + `1px` `t.line` 描边 + `t.ink2` 图标与文案。

### 4.5 分段控件（主题模式切换 & 历史筛选）

所有分段控件均采用 `AnimatedContainer`（背景色）+ `Material(type: MaterialType.transparency)` + `InkWell` 的层级结构，确保悬停层永远呈现在背景滑块之上不被遮挡：

- **主题模式分段（`我的` 页面）**：外槽 `t.track` + `1px` `t.line` 描边（圆角 `12dp`、内边距 `4dp`）。三项带图标与文案（「跟随系统 / 浅色 / 深色」），内层采用 `FittedBox(fit: BoxFit.scaleDown)` 保障 `320dp` 窄屏不溢出。选中滑块使用 `t.flame` + `t.onFlame` 文字图标 + 克制暖色阴影（`t.flame.withValues(alpha: 0.22)`），悬停使用 `t.onFlame.withValues(alpha: 0.12)`；未选中项透明底 + `t.ink2`，悬停使用 `t.hoverTint`。
- **历史筛选分段（`历史` 页面）**：外槽 `t.track` + `1px` `t.line` 描边；选中滑块使用 `t.surfaceElevated` + `t.line` 描边 + 轻阴影（解决深色模式下选中项亮度低于凹槽的问题），悬停使用 `t.hoverTint`。

### 4.6 对比分屏与全屏缩放对比弹窗（`BeforeAfterSwitch` / `FullscreenCompareDialog`）

- **编辑结果内嵌对比（`BeforeAfterSwitch`）**：
  - 纵向两段式结构（画布在上、控制栏在下），避免悬浮分段遮挡画面或与角标挤在同一垂直带。
  - 上方 `Expanded` 对比画布内边距 `6dp`，内置 `BeforeAfterView`：使用 `OverflowBox(alignment: Alignment.topRight)` 实现「修复前 / 修复后」严格 `1:1` 像素对齐裁剪；分界线手柄采用白色半透明竖线 + 纸白圆形手柄（`t.paper`）+ `1.5px` `t.flame` 描边；角落「修复前」「修复后」角标采用 `Colors.black.withValues(alpha: 0.56)` 半透明深底与纯白文字（`IgnorePointer`），保证深浅模式下在任意画面上可读。
  - 下方 `44dp` 独立紧凑控制栏：居中放置「修复前 / 对比 / 修复后」分段条（轨道 `Colors.white.withValues(alpha: 0.08)`，选中态 `t.flame` + `t.onFlame`，未选中态 `Colors.white.withValues(alpha: 0.78)`，悬停 `Colors.white.withValues(alpha: 0.14)`），右侧放置「全屏对比」入口图标（`Icons.open_in_full_rounded`）。
- **全屏缩放对比弹窗（`FullscreenCompareDialog`）**：
  - 全屏不透明 `t.media` 底色（`insetPadding: EdgeInsets.zero`）。
  - 顶部 `SafeArea` 工具栏（`52dp`）：左关闭按钮、中「修复前 / 对比 / 修复后」切换、右当前倍率标签（`1.0×` `tabnum`）与「铺宽 / 适应」切换按钮。
  - 对比主体：采用统一 `Matrix4` 同步变换 `before` 与 `after` 画面，支持双指缩放（`1.0×–6.0×`）、单指拖拽平移（严格边界钳位）、双击切换 `1×` 与 `铺宽 / 2.5×`；对高竖图（`imageAspect < viewportAspect * 0.72`）支持一键「铺宽」从顶部开始纵向滑动细看；分界线（`48dp` 热区）独立处于视口坐标系内并置于缩放手势层之上，拖动分界线只改分屏比例不触发平移，分界线外手势只改缩放/平移不碰分界线，缩放过程中手柄清晰不形变。

---

## 5. 布局与极简文案原则

1. **画布优先**：图片与视频编辑器及对比预览弹窗优先保证画面可视面积，竖屏视频预览放宽高度预算（`avail - 116dp`），横屏采用左右双栏排布避免控制条被挤出屏幕；所有页面均需在 `320×568` 窄屏下无横向溢出。
2. **去除非必要解释文字**：删除引导说明卡（「简单三步」）、显而易见的冗余状态副标（如视频预览底部的多余说明句、设置页概览卡片的「已启用」标签、历史列表底部的重复提示大卡），仅保留直达操作、明确状态反馈与必要兜底路径（如无法播放时的相册保存提示）。
3. **短文案与单一焦点**：每屏仅突出一个 `primary` 焦橙实底按钮；空状态文案简短直接（「还没有处理记录」）；格式标签等技术规格保持精炼单行展示。

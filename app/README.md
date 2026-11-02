# 水印工坊 · Flutter 工程基线

按 Flutter 官方规范搭的工程骨架：路由、状态管理、主题令牌三层已接通，8 屏的路由结构已就位，
`dart analyze` / `flutter test` / `flutter build apk --debug` 均通过（证据见文末）。

- Flutter 3.47.7 stable / Dart 3.13.5
- 目标平台：Android（第一阶段）
- 包名：`cn.shuiyin.watermark_remover`

---

## 一、选型结论

| 层 | 采用 | 版本 | 为什么是它 |
|---|---|---|---|
| 路由 | **go_router** | 18.1.0 | Flutter 官方团队维护，`flutter.dev` 文档里作为路由首选；`StatefulShellRoute` 原生支持「每个 Tab 独立导航栈」，正好是历史页/编辑页反复进出的场景 |
| 状态管理 | **Riverpod**（`flutter_riverpod` + 代码生成） | 3.4.3 / 生成器 4.0.9 | 编译期检查、不依赖 `BuildContext`、provider 可被 override 做测试替身；`AsyncValue` 天然适配「本地处理任务」这种异步状态机 |
| UI 组件 | **Material 3（Flutter 内置）+ 自建令牌层** | 随 SDK | 见下方说明 |
| 代码生成 | build_runner | 2.16.2 | Riverpod 官方推荐的 `@riverpod` 写法需要它 |
| Lint | flutter_lints | 6.0.0 | 官方基线，再在 `analysis_options.yaml` 里收紧 |

**为什么 UI 不引第三方组件库（shadcn_ui / forui / getwidget）**

原型的视觉体系是自建的奶油白 + 炭黑 + 焦橙（`--flame:#C4551B`），圆角 16 / 12。
第三方 kit 的价值在于「开箱即一套风格」，而我们恰好**不要**那套风格——
引进来会发现每个组件都要覆写颜色、圆角、阴影，最后维护的是一份「和库打架的覆盖表」。
所以这里的组件库是两层的：

1. **基础控件**：Material 3 内置（`InkWell` / `NavigationBar` / `AppBar` / `SegmentedButton` 等），零依赖、跟着 Flutter 版本演进；
2. **品牌组件**：`lib/core/widgets/` 下的 `AppCard` / `AppButton` / `FeaturePlaceholder`，页面只允许用这几个出牌。

将来真要换风格，改的是 `core/theme/app_tokens.dart` 一处 + `core/widgets/` 三个文件，页面不动。

**为什么不用 GetX / Provider / Bloc**

- GetX：隐式全局单例，`Get.put` 的依赖关系在代码里追不出来，测试替身难做，不选。
- Provider：官方入门级方案，够用但缺少 Riverpod 的组合与 family 能力，做「按 taskId 取详情」这类场景要自己包一层。
- Bloc：同样可靠，事件流更显式；但对这个项目（少量表单 + 长任务进度）样板偏多，Riverpod 的 `Notifier` + `AsyncNotifier` 更轻。

---

## 二、目录结构

```
app/
├── lib/
│   ├── main.dart                    # 只做 runApp，逻辑都在 bootstrap
│   ├── bootstrap.dart               # 全局错误钩子 + 启动
│   ├── app/
│   │   ├── app.dart                 # MaterialApp.router：主题 + 路由 + 本地化
│   │   ├── router/
│   │   │   ├── app_routes.dart      # 路径/路由名的唯一来源
│   │   │   └── app_router.dart      # GoRouter（Riverpod provider）+ 3 个 Tab 分支
│   │   └── widgets/app_shell.dart   # 底部三 Tab 外壳
│   ├── core/
│   │   ├── theme/
│   │   │   ├── app_tokens.dart      # 设计令牌（ThemeExtension），颜色只在这里改
│   │   │   ├── app_theme.dart       # ThemeData 装配（浅/深）
│   │   │   └── theme_mode_controller.dart  # @riverpod 的深浅色开关
│   │   ├── processing/              # 处理层契约：MaskPlan / WatermarkProcessor / 错误码
│   │   ├── media/                   # 通道名 + 保存到相册 + 视频探测（VideoProbe）
│   │   └── widgets/                 # 品牌组件层：AppCard / AppButton / 占位骨架
│   ├── features/
│   │   ├── home/presentation/       # 01 首页
│   │   ├── history/
│   │   │   ├── domain/              # HistoryItem / TaskStatus
│   │   │   ├── application/         # provider：数据源 / 筛选 / 派生列表
│   │   │   └── presentation/        # 07 历史 + 详情 + 列表项组件
│   │   ├── image_editor/            # 02/03 图片流程（**已打通**，见第六节）
│   │   ├── video_editor/            # 04/05/06 视频流程（探测层已通，见第七节）
│   │   └── profile/presentation/    # 08 我的
│   └── **/*.g.dart                  # 生成文件，随代码提交
├── test/app_smoke_test.dart         # 路由 + 状态 + 主题 的集成冒烟
├── test/mask_composer_test.dart     # Mask 生成的逐像素断言（纯 Dart）
├── integration_test/                # 真机：打穿通道到 Kotlin + OpenCV
├── test_driver/                     # flutter drive 的驱动入口
├── tool/quality_compare.dart        # 修复效果的数值/目视验收脚本
└── analysis_options.yaml            # lint 基线
```

分层规则（后续加代码请守住）：

- `presentation/` 只依赖 `application/` 的 provider 和 `core/` 的组件，**不直接碰数据源**；
- `domain/` 是纯 Dart，不许 import Flutter（除了 `@immutable` 这种 `foundation` 里的东西）；
- 跨 feature 复用先放 `core/`，不要在 feature 之间互相 import。

---

## 三、从零复现

```bash
# 1. 建工程（只出 Android）
flutter create --org cn.shuiyin --project-name watermark_remover --platforms android --empty app

# 2. 加依赖（让 pub 自己解析最新兼容版本，别手写版本号）
cd app
flutter pub add flutter_riverpod riverpod_annotation go_router
flutter pub add dev:riverpod_generator dev:build_runner
# flutter_localizations 直接写进 pubspec（sdk 依赖，pub add 带 sdk 不方便）

# 3. 生成 Riverpod 代码（本机必须加 --force-jit，原因见第四节坑 2）
dart run build_runner build --force-jit

# 4. 中文路径必做：android/gradle.properties 加 android.overridePathCheck=true（坑 1）
#    AndroidManifest 的 android:label 改成「水印工坊」

# 5. 静态检查 / 测试 / 出包
dart analyze          # 本机不要用 flutter analyze，坑 3
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY   # 坑 4，跑测试前
flutter test
flutter build apk --debug

# 6. 真机（两个脚本都自带前台守卫，手机在用户手里时只能这样用）
bash tool/safe_adb.sh whoami          # 只查前台，不动手机
bash tool/safe_adb.sh tap 540 1200    # 前台不是本 App 就 exit 3，一个像素都不点
bash tool/verify_device.sh            # 首页 → 历史 → 详情，三步截图，不写任何数据
```

---

## 四、本机（Windows + 中文路径 + 代理）踩到的九个坑

这些都不是代码问题，是不弄会反复浪费时间的环境问题，写下来备查。
前三条的根因是同一个：工程落在 `D:\项目\watermark`，路径里有中文。

**1. AGP 直接拒绝构建：`Your project path contains non-ASCII characters`**

```
> Your project path contains non-ASCII characters. This will most likely cause the build to fail on Windows.
  Please move your project to a different directory. Add 'android.overridePathCheck=true' to gradle.properties.
```

解决：`android/gradle.properties` 里加 `android.overridePathCheck=true`，同时显式给
`org.gradle.jvmargs` 补 `-Dfile.encoding=UTF-8`（模板默认的 `-Xmx8G` 也顺手降到 4G，本机只有 15.4 GB 内存）。
加上之后构建正常，**实测没有出现资源编译问题**。

**2. `build_runner` 编译失败**

```
E Unable to write file: d:\项目\watermark\app\.dart_tool\build\entrypoint\build.dart.aot
E Failed to compile build script.
```

build_runner 2.16 默认把 builder 脚本 AOT 编译，输出路径带中文时写不进去；
改成 `--force-jit` 直接走 JIT，91 秒生成 3 个 `.g.dart`。

**3. `flutter analyze` 的分析服务会崩**

```
FormatException: Unexpected end of input (at character 289)
...7%9B%AE/watermark/app/"}],"capabilities":...
analysis server exited with code 255
```

分析服务走 LSP，帧长度按字符算而实际按字节写，路径里的中文被百分号编码后长度对不上 → 解析崩溃。
**换 `dart analyze` 一切正常**（本工程跑出 `No issues found!`）。

**4. 沙箱代理会打断 `flutter test` 和 `flutter drive`**

```
Unable to connect to flutter_tester process: WebSocketException: Invalid WebSocket upgrade request
Exception attempting to connect to the VM Service: HttpException: Connection closed before full header was received
```

环境里 `http_proxy=http://127.0.0.1:<port>` 把 **localhost** 的 WebSocket 也代理走了。
`flutter test` 报前者，`flutter drive` 报后者 —— 后者极像「App 崩了」，其实 App 好好的，
只是宿主连不上它的 VM Service，于是 `flutter drive` 会重试 150 次然后挂住。

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost flutter test
```

**不要**用 `unset http_proxy` 一刀切：`pub get` 和 Gradle 下载镜像还要靠它。

> 排查 `flutter drive` 的替代路线（本次用的）：`flutter build apk --debug
> --target=integration_test/xxx_test.dart` → `adb install -r` → `am start`，
> 然后直接读 logcat。测试主体本来就在 `main()` 里跑，不需要驱动进程。

**5. 顺带一条测试写法**：`tester.pageBack()` 是按 tooltip `'Back'` 找按钮的，
本项目 locale 是 `zh_CN`（tooltip 变成「返回」），所以**用 `find.byType(BackButton)`**。

**6. `testWidgets` 里调 `dart:ui` 的真异步会静默挂死**

`mask_composer_test.dart` 一开始写成 `testWidgets`，跑起来一直 `did not complete`，
既不报错也不超时退出——因为它内部是 `instantiateImageCodec` / `Picture.toImage` /
`toByteData` 这些**真异步**操作，而 `testWidgets` 跑在 `FakeAsync` 里，这些 Future 永远不完成。
改法：用普通 `test()` + `TestWidgetsFlutterBinding.ensureInitialized()`（本次采用），
或在 `testWidgets` 里把整个 body 包进 `await tester.runAsync(() async { ... })`。

> 顺带记一句：这一类「测试从没真正跑过」很容易被当成通过 —— 之前 `flutter test` 报的
> `+1: All tests passed!` 其实只跑了 1 条冒烟，另外 3 条一直在挂。**数一下 `+N` 对不对得上用例数**。

**7. `adb install` 喂中文绝对路径会失败**

```
adb.exe: failed to stat /d/项目/watermark/app/build/.../app-debug.apk: No such file or directory
```

Git Bash 把 `/d/...` 转成 Windows 路径后，`adb.exe`（Windows 程序）按系统 ANSI 代码页解析，
中文目录就找不到了。**先 `cd` 到 APK 所在目录，再传相对文件名**：

```bash
cd build/app/outputs/flutter-apk && adb install -r app-debug.apk
```

另外真机 `/data` 只剩 1.0 GB，fat APK（296 MB，三个 ABI）装不上
（`INSTALL_FAILED_INSUFFICIENT_STORAGE`）。加 `--target-platform android-arm64` 降到 222 MB 才过。

**8. release 包在中文路径下必失败（debug 正常）**

```
Error: Unable to read file: D:\???\watermark\app\.dart_tool\flutter_build\<hash>\app.dill
Dart snapshot generator failed with exit code 255
Target android_aot_release_android-arm64 failed
```

debug 走内核快照、release 走 **AOT**，而 `gen_snapshot` 是原生程序、按系统 ANSI 代码页读路径 ——
`项目` 直接变成 `???`。**做了一次对照实验确认**：把同一份源码拷到 `D:\dev\wm_app` 再 build，
一次过，产出 118.7 MB。

所以出包必须走脚本（把源码快照到 ASCII 路径再编）：

```bash
bash app/tool/build_release.sh              # 产物落 D:\dev\apk\watermark-remover-release.apk
bash app/tool/build_release.sh android-arm64 android-arm
```

脚本用完会删掉暂存目录，不留第二份源码。**别在工程目录里直接 `flutter build apk --release`**。

**9. 集成测试包会顶掉正式包（2026-10-20 被当成 App bug 报上来）**

`flutter build apk --target=integration_test/xxx.dart` 产出的包**包名和正式包一模一样**
（`cn.shuiyin.watermark_remover`）。装上去之后，手机上的「水印工坊」入口就是测试用例本身。
三条症状会一起出现，看起来特别像 App 坏了：

| 症状 | 真正原因 |
|---|---|
| 点开 App 直接进「视频去水印」页 | 测试用例自己导航过去的 |
| 页面上所有按钮都点不动 | `IntegrationTestWidgetsFlutterBinding` 继承 `LiveTestWidgetsFlutterBinding`，`shouldPropagateDevicePointerEvents` 默认 **false** —— 真实触摸事件根本不进手势识别 |
| 切主题「卡顿」 | 帧是测试用 `pump()` 驱动的，界面只在测试推进时更新 |

判据（比猜快）：`adb logcat -d -s flutter:I | head`。
开头是 `00:00 +0: <用例名>`，或日志里出现 `SHOT_STAGE` 这类测试自有标记 —— 装的就是测试包。

修法：`bash /d/dev/vt/restore_app.sh`（有存档直接装回，`REBUILD=1` 强制重建）。
现在 `run_tests.sh` / `shot_toggle.sh` 都挂了 `trap ... EXIT`，跑完自动还原。

顺带两个小坑：
- `adb.exe` 是原生程序，**不认 MSYS 的 `/d/...` 路径**（`failed to stat /d/dev/...`），要传 `D:/dev/...`；
- 手机 `/data` 常年 99%，223 MB 的包直接 `adb install -r` 会失败 —— 先 `adb uninstall` 再装。

**10. 怎么确认「我改的代码真的进包了」—— 分两层，别一句话下结论**

`build_release.sh` 是**先拷源码快照再编译**，拷贝之后改的文件不会进包。所以「构建成功」
不代表「包里是新代码」。反过来的坑更贵：想验证却在错误的层上 grep，会拿到一个**极像证据的 0**。

| 改的是哪一层 | 编译到哪 | 能不能从 APK 里查 | 怎么查 |
|---|---|---|---|
| Kotlin（`android/.../media/*.kt`） | `classes.dex` | **能** | 解出 dex 直接 `grep -a '<中文字符串>'` —— dex 的字符串是明文 MUTF-8 |
| Dart（`lib/**`） | `libapp.so`（AOT 快照） | **不能** | 快照里的字符串不是以可搜形式存的；`strings -a` / `grep -a` 都搜不到，不是「没打进去」 |
| Dart（debug 包） | `kernel_blob.bin` | 能（明文） | `grep -a` 直接命中 |

```bash
# 已验证可用（2026-10-20，release 包）
cd /tmp && mkdir apkchk && cd apkchk
unzip -o -q "D:/dev/apk/watermark-remover-release.apk" "classes*.dex"
grep -a -c "打不开这个视频" classes.dex     # → 1
```

Dart 侧只能走**行为验证**（真机看界面 / 集成测试），或者比时间线（源码 mtime < 构建开始时间）。

⚠ **本机 Git Bash 没有 `strings` 命令**。`strings ... 2>/dev/null | grep -c` 会静默拿到 `0`，
看着像「包里没这段代码」，实际是「这条命令根本不存在」。**用工具前先确认它存在。**

---

## 五、三样东西是怎么接起来的

### 1. 入口：ProviderScope 必须在最外层

```dart
// main.dart
void main() => bootstrap(() => const ProviderScope(child: WatermarkApp()));
```

`ProviderScope` 包住整棵树，`ref` 才能在任意层级拿到。
`bootstrap()` 只做全局异常钩子，测试里直接 `pumpWidget(ProviderScope(child: WatermarkApp()))`，
不会重复跑启动逻辑。

### 2. 路由：GoRouter 是 provider，不是全局变量

```dart
@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) => GoRouter(
  initialLocation: AppRoutes.home,
  routes: [
    StatefulShellRoute.indexedStack(          // ← 三个 Tab，各自独立栈
      builder: (c, s, shell) => AppShell(navigationShell: shell),
      branches: [ /* 首页 / 历史 / 我的 */ ],
    ),
    GoRoute(path: AppRoutes.imageEditor, ...), // ← 全屏页，盖住 Tab 栏
    GoRoute(path: '/history/:id', ...),        // ← 带参数
  ],
);
```

- `keepAlive` 必开：路由器被回收等于整棵导航栈清零。
- 路径常量只写一次，页面里用 `context.pushNamed(AppRoutes.imageEditorName)`。
- 详情页参数从 `state.pathParameters['id']` 取出 → 喂给 `historyItemByIdProvider(id)`，
  family provider 是 Riverpod 处理「按 id 取单个」的标准写法。

### 3. 状态：三层就够，别再加一层

```
historyItemsProvider (数据源，keepAlive)
        ↓ watch
visibleHistoryProvider (派生：按筛选过滤)   ← 页面只 watch 这个
        ↑ watch
historyFilterProvider (筛选状态，Notifier)
```

页面本身无状态：`ConsumerWidget` + `ref.watch`，点击时 `ref.read(...notifier).setKind(...)`。
数据源是**真实持久化的**（见下一节），但对外仍然是 `List<HistoryItem>` —— 以后换 SQLite
只要把 `HistoryItems` 改成 `AsyncNotifier<...>`、三个页面加 `.when(...)`，依赖关系不变。

### 4. 历史记录：真数据，不是种子

2026-10-20 之前，历史页显示的是写死在 `historyItemsProvider` 里的 6 条假记录 ——
看着像功能做好了，其实是摆设。现在：

- 数据源：`<应用支持目录>/history.json`（`{"version":1,"items":[...]}`），
  `HistoryStore` 接口 + `FileHistoryStore` / `MemoryHistoryStore`
- 首次启动就是空的（`initialHistoryProvider` 默认 `const []`），
  `demoHistory` 那份假数据只留给测试和截图用
- 图片 `run()` 成功、视频 `startRepair()` 成功后各写一条：
  标题取原文件名、元信息取真实尺寸/时长/体积、`detail` 写实际用的策略
- 写入在**第一帧之前**读回（`bootstrap` 与主题并行读盘），避免先空一屏再被填满；
  写盘失败只影响「下次还能不能看到」，不会把成功的修复变成失败（不 await）
- 上限 50 条，超出丢最旧一条，文件不会无限长
- 首页「最近处理」、历史页计数、我的页「已完成 N 项」全部改成从这里派生 ——
  原来那三个数字（含「26.8 MB」「已完成 15 项」）都是写死的
- 历史页右上角是**清空记录**（原来是「管理」按钮，点了只弹「待接入本地数据库后开放」，
  而数据库早就接上了）。清空要二次确认，并且只清记录、不碰相册 —— 这句说明就写在
  确认框里，因为「删除记录 ≠ 删除相册文件」是这一页唯一容易误会的地方

⚠ 我的页「默认修复质量 · 高清」已删除：修复半径目前是固定的，没有任何档位可选，
留一行点了只弹「暂未开放」的装饰项比删掉更糟。「关于水印工坊」原来 `onTap: () {}`
（点了没反应），现在弹出版本与「本地处理」的说明。

### 4.1 缩略图与详情页

历史原来只有文字：列表里每行一个深色方块 + 图标，详情页顶部一个固定 200px 的框
**永远只有一个图标**——看起来像「图片加载失败」，比不做预览更糟。

- 缩略图存 `<应用支持目录>/thumbs/<记录id>.png`，**不是临时目录**：
  临时目录会被系统清、也会被「清理缓存」清，而缩略图是记录的一部分
- 生成走 `encodeThumbnail`（`instantiateImageCodec(targetWidth: 320)`），
  文件名用记录 id，一条一张，重跑覆盖不堆文件；失败返回 null，记录照写，只是没图
- 列表里按显示尺寸解码（`cacheWidth`），50 行一起滚时不炸内存
- 「清空记录」连带 `clearAll()` 删掉缩略图，否则记录没了图还在，成了
  「清理缓存」也看不见的孤儿（缩略图不在缓存目录）
- 详情页三处修正：类型显示中文（原来直接 `item.kind.name`，界面里冒出 `image`/`video`）、
  预览区优先显示缩略图（没有才退回图标）、按钮文案从「重新处理」改成
  「再处理一张图片 / 再处理一个视频」——**历史不存素材**，旧文案在承诺它做不到的事，
  页面上直接写清「成品已导出到相册，原素材不留副本」

### 4.2 缓存：清什么、留什么

`lib/core/storage/app_cache.dart`。临时目录里混着两类东西，处理方式必须分开：

| 类别 | 例子 | 清理时 |
|---|---|---|
| 可再生的中间产物 | `in_*.png` / `mask_*.png` / `poster_*.png` / `sample_video.mp4` | 删 |
| **保护期内的成果**（24h） | `out_*.png`（修好的图）/ `fixed_*.mp4`（修好的视频） | **留** |
| **过期的成果** | 同上，但 mtime 超过 24h | 删 |
| 第三方 SDK 的临时文件 | 子目录、陌生前缀 | 不碰（按白名单，不按黑名单） |

理由：用户修完但还没点「保存到相册」时，成果只存在于临时目录 —— 一刀清空等于把
刚做完的活删掉，而界面还写着「已释放 1.2 MB」。所以清理报告里会带
「保留 N 个未导出的成果」，删不掉的文件也如实报「N 个文件被占用」。

**为什么要给「保护」加个期限**：最初写的是永久保护，结果临时目录只增不减 ——
每修一次多一个 `out_*.png`（1~2 MB），永远清不掉，「保留 N 个未导出的成果」
这句话反而变成谎话。真正的理由是：**超过一次会话的成果根本不可达** ——
编辑页的 state 在内存里，App 一重启就没了；历史记录只存元信息，不带 `resultPath`。
所以 24 小时之后还躺在临时目录里的成果，就是没人能打开的垃圾。
判断依据是文件真实 mtime，`stat` 失败时**当作受保护**（宁可多留，不要误删）。

顺带一提，Android 自己会在空间紧张时清 cache 目录 —— 任何「成果」长期只放 cache
都是错的，保存到相册才是唯一持久化路径。

### 4.3 错误文案：`detail` 必须真的到用户眼前

`lib/core/processing/processing_error.dart`。

这里有个「做了但没用」的典型：原生侧会把失败原因写得很清楚
（「打不开这个视频：可能是封装格式系统不支持（AVI / RMVB / WMV 等）」），
但 `ProcessingException.message` 固定返回 `code.userMessage`，也就是
「文件读不出来，可能已损坏」—— **detail 一个字都没显示过**。

它比崩溃更难发现：界面有提示、没报错、代码看着也「翻译了错误码」。
丢的是「为什么失败」这一整层信息，用户除了重试没别的可做。

现在 `message` 优先返回 `detail`，通用话术只作兜底（detail 为空或空白时）。
配套的约束是**detail 必须是能和用户对话的中文短句**——内部路径、堆栈留在 `Log` 里，
`ImageProcessor` 里原来那句 `"无法解码输入图：$inputPath"` 就是反例，已改。

⚠ 这条例外条款是踩出来的：改完之后 `OutOfMemoryError` 的系统 message
（`Failed to allocate a 46080012 byte allocation with ...`）就**直接漏到了界面上** ——
以前它被「只显示通用话术」挡着，看不出问题。现在 `MediaBridge` 的 OOM 分支
原文进 `Log.e`、通道传 `null`，让 Dart 回落到「图片太大…先裁掉无关部分」。
留下的唯一例外是 `ERR_NATIVE`（未预料的异常）：那里仍传原始 message，
因为「修复引擎出错」什么都不说，反而更难定位。

另外两处一起收的：

- **首页副标题是承诺，不是装饰**：视频入口原来写着 `MP4 · MOV · MKV · AVI`，
  而 `MediaExtractor` 没有 AVI 解析器（Stagefright 不提供），选了直接失败。已去掉 AVI。
  图片的 HEIC 是真的，但要 Android 9+（`BitmapFactory` 的系统解码器支持）。
- **相册里选了不支持的容器**：`VideoProbe.openRetriever` 把
  `Failed to instantiate extractor` 翻译成「转成 MP4（H.264 + AAC）再试」，
  原始异常留在 `cause` 里给日志。Dart 侧不再用 `'$error'` 拼 `PlatformException(...)`。

### 4.4 版本号：只留一个源头

`lib/core/app_info.dart`。之前 `profile_page.dart` 里三处写死 `v0.1.0`（设置行、
底部说明、关于弹窗），而 `pubspec.yaml` 写的是 `0.1.0+1` —— **两个独立事实**。
改版本时改一处漏两处，界面会安静地报旧版本，谁也注意不到。

现在链路是单向往回读：

```
pubspec.yaml 的 version:  →  Gradle  →  AndroidManifest  →  package_info_plus  →  UI
```

- `AppInfo` 在 `bootstrap` 里读（与主题、历史并行，`_restore` 带 1500ms 超时兜底），
  第一帧就是真版本，不会先闪 `v?`
- 读不到时显示 `v?` 而不是 `0.0.0` —— **宁可露出生疏，也不编一个版本号**
- `profile_page_test` 里有一条专门注入 `2.3.4 / 77`，证明界面确实在读 provider
  而不是碰巧写对了字面量

### 5. 主题：令牌挂在 ThemeExtension 上

```dart
final t = AppTokens.of(context);          // 页面取色唯一入口
Text('水印工坊', style: TextStyle(color: t.ink));
```

`app_tokens.dart` 里 `AppTokens.light()` / `.dark()` 两份色值，直接对应原型的 `:root` 与
`[data-theme="dark"]`。`MaterialApp` 的 `theme` / `darkTheme` / `themeMode` 三者：
前两个来自 `AppTheme`，`themeMode` 来自 `themeModeControllerProvider`——
点「我的 → 深色」就是 `ref.read(provider.notifier).setMode(ThemeMode.dark)`，
整棵树连令牌一起插值过渡，没有 `setState`。

**主题记忆**：选过的模式写在 `<应用支持目录>/theme_mode.txt`（一行 `system|light|dark`）。
不为三个值引 shared_preferences；读写抽成 `ThemeModeStore` 接口
（`FileThemeModeStore` / `MemoryThemeModeStore`），单测塞内存实现，不碰真机。

读取发生在 `runApp` **之前**（`bootstrap` 先 await，再交给 `main` 的 `ProviderScope` override）——
晚一步就会先按 system 画一帧、再跳到用户选的主题，冷启动能看出闪。

⚠ **超时设太短，功能会变得像「没做」**。第一版给 300 ms，而冷启动首次
`getApplicationSupportDirectory()` 就要几百毫秒，于是每次都超时、每次都回落 system。
代码看着完全正确，现象只是「重启后主题没记住」，唯一线索是日志里那行：

```
[boot] 主题偏好读取失败，按跟随系统启动：TimeoutException after 0:00:00.300000
```

现在改成 1500 ms，并把实测耗时打出来（首次 136–400 ms）。
**凡是静默兜底的分支，日志里必须留字** —— 否则「失败」和「没实现」长得一模一样。

---

## 六、图片闭环（已打通）

链路：`image_picker` / 内置示例图 → 画布上**框选或涂抹** → `MaskComposer` 生成 1:1 的黑白 Mask
→ `MethodChannel('cn.shuiyin.watermark/media')` → Kotlin + OpenCV `Photo.inpaint`
→ 结果切回 Flutter 预览 → 写进系统相册 `Pictures/水印工坊`。

### 遮罩草稿：矩形 + 涂抹 + 橡皮（`MaskDraft`）

原型上写的是「画笔涂抹 / 橡皮擦 / 矩形 / 清除」四个工具，而实现里很长一段时间只有矩形 ——
首页那句「选素材 → **涂抹**水印 → 本机修复」等于在承诺一个不存在的功能。
2026-10-22 补齐，模型是一个 `MaskDraft`：

```dart
class MaskDraft {
  final Rect? rect;                  // 框
  final List<MaskStroke> strokes;    // 笔迹，按顺序叠加（后画的盖住先画的）
  bool get hasMask => ...;           // 「开始修复」的可用性就用这个判
}

class MaskStroke {
  final List<Offset> points;   // 归一化 0..1
  final double width;          // 归一化笔宽（相对**图宽**）
  final bool erase;            // 橡皮
}
```

四个决定，都是踩过或想过之后定的：

| 决定 | 理由 |
|---|---|
| 笔宽归一化到**图宽**而不是图高 | 像素空间里才是正圆。按图高归一化在 16:9 的图上会画成椭圆 |
| 橡皮是**画黑色**，不是 `BlendMode.clear` | `imread` 把带 alpha 的 PNG 压成 BGR，透明像素 RGB 也是 0；直接画黑就没有「alpha 语义」可猜 |
| 单点笔迹合法（`drawPoints`） | 用户点一下就该落一个圆点。否则「点一下没反应」又是一次假按钮 |
| 采样去抖：相邻点距离 < 0.002 就丢 | 手指抖动会让点数暴涨，而 Mask 是栅格化的 —— 多出来的点画不出新东西，只让 state 每帧都变 |
| 只有橡皮 → `hasMask == false` | 等于什么都没涂。这个判断放在 `MaskDraft` 里，UI 的按钮可用性和 Mask 生成的入参校验**共用同一个标准** |
| 默认工具是**矩形**，不是涂抹 | 原型上 `data-tool="rect"` 带 `on` 类。先给最粗粒度、最好理解的那个；涂抹是精修手段，不是入口 |
| 选框支持**拉四个角改大小** | 原型提示写着「也可以拉右下角改大小」。只给「重新拖一个」的话，想微调两像素必然对不准 —— 对不准就会把干净背景糊进去 |

预览与 Mask 必须同形：`_DraftPainter` 和 `MaskComposer._renderMask` 用同一套顺序规则
（先矩形，再按顺序叠笔迹）。唯一的差别是可视化上橡皮用 `saveLayer + BlendMode.clear` 真擦，
否则预览里会留一块实心色块盖住照片。

**原生侧一行都没改** —— 送过去的仍然是一张黑底白块的 PNG，引擎不需要知道它是框出来的还是涂出来的。

### 三个关键决定

**1. 坐标系只在三层之间走，绝不多加一层**

```
手势坐标（RenderBox local）
  → 图像显示矩形（BoxFit.contain 的留白要扣掉）
  → 归一化 0..1（**对外唯一格式**，MaskPlan / Keyframe 都用它）
  → 原图像素（只在画 Mask 时算一次）
```

`SelectionCanvas` 里 `toNormalized()` 把 local 坐标夹到图像矩形内再除以渲染尺寸，
所以「手指滑出图片」不会产生越界矩形；`MaskComposer` 再 `clamp(0,1)` 一次，两道闸。

**2. 输入重新编码成 PNG，而不是把原图路径交给 native**

OpenCV 的 `imread` 不理解 EXIF，而 Flutter 的 `instantiateImageCodec` 理解。
同一张竖拍照片，两边解出来的方向可能差 90° → Mask 整块错位。
做法：Flutter 解码 → 重新编码 PNG（方向已烘焙进像素）→ 交给 native。
代价是中间多一次编码，收益是**两边看到的像素绝对一致**。

**3. Mask 与原图 1:1，不缩放**

Mask 按显示尺寸存会让 native 侧必须再做一次缩放，而缩放会把 6 px 高的文字边缘糊掉，
阈值化之后一半像素丢失。所以 Mask 永远是原图分辨率、黑底白块。

### Kotlin 侧踩的两个坑（都会在真机上直接崩）

| 现象 | 根因 | 修法 |
|---|---|---|
| `Unresolved reference 'inpaint'` / `'INPAINT_TELEA'` | OpenCV 4.14 里这方法不在 `Imgproc`，搬到了 `org.opencv.photo.Photo` | `Photo.inpaint(..., Photo.INPAINT_TELEA)` |
| 运行期 `cv::Exception (-210:Unsupported format) in icvInpaint` | `Utils.bitmapToMat` 给的是 **4 通道 RGBA**，`inpaint` 只吃 8UC1/8UC3 | 前面 `COLOR_RGBA2BGR`，出来再 `COLOR_BGR2RGBA` |

第一个坑的排查方式值得记：`flutter build` 只报「找不到符号」，把 AAR 解包、
`javap` 查 `classes.jar` 里的方法签名，比猜快得多。

### 保存到相册

`GallerySaver`（Kotlin）走 MediaStore + `RELATIVE_PATH = Pictures/水印工坊` + `IS_PENDING`，
Android 10+ **零权限**；失败时 `resolver.delete(uri)` 清掉半成品，避免相册里留 0 字节记录。

Dart 侧 `GallerySaver` 单独一个服务，没有塞进 `WatermarkProcessor`：
修复是纯计算，存相册是系统副作用，两者的失败语义不同（前者该重试，后者该提示用户去查存储）。
UI 上也是分开的两个状态：`error`（修复失败）与 `saveError`（保存失败）。

### 框内细分：做了，实测没用，默认关闭

矩形 Mask 的固有缺陷是「框比水印大一圈就把干净背景一起糊掉」。试过一版细分：
框内算梯度幅值，取 `均值 + 0.8σ` 阈值（夹在 12~200），膨胀 2 次再与原框求交，
不足原框 0.5% 就退回整框。

**真机实测（`cafe.jpg`，大十倍的框）：**

| | Mask 像素 | 水印条带内改动 | 条带外改动（背景被糊掉） | 区域内粗糙度 |
|---|---|---|---|---|
| 不细分 | 28,728 | 564 | **3,356** | — |
| 细分后 | 9,996（34%） | 564 | **3,356** | 0.39× 对照带（明显涂抹） |

Mask 缩到三分之一，**画面损伤一点没减少**。原因说清楚：
判据假设「高频 = 水印」，可木纹同样高频。细分删掉的是**平坦区域**——
那些地方 inpaint 出来本来就几乎不变；真正造成涂抹的高频纹理**全被保留**。
换句话说，它在一个本来就没伤害的地方省了功夫。

目视证据：`.workbuddy/shots/bigbox-refined-crop.png` —— 水印没了，但左边那片木纹被抹平了。
粗糙度 0.39×（对照带 = 5.46 / 区域 = 2.11），是「糊」的量化特征。

所以 `refineMask` 默认 `false`，只作为实验开关留着（管道、三道保险、A/B 用例都能复用）。
真要解决，判据得换成文字特征（top-hat / 笔画宽度 / 连通域长宽比），或者直接上 LaMa ——
AI 修复对粗 Mask 的容忍度本来就高，这也是技术方案里把它排在后面的原因之一。

### 为什么把保存提前做

原本想等视频闭环一起做。但集成测试跑完，`flutter drive` **会把测试包卸载**，
`cache/` 里的产物跟着消失，`adb pull` 拿不到 —— 质量验收没法做。
产物落到 `Pictures/` 之后就能直接拉回来，顺带补上了 MVP 缺的一环。

---

## 七、视频链路 · 第一块：探测层（已打通）

探测层先于管线做掉，原因：后面所有的坐标都建立在同一个问题上 ——「**哪张帧、多大、正不正**」。
这三件事错了，逐帧修复会整体歪，而画面上只表现成「修得不准」，极难回溯。
先把这三个答案钉死，再写管线（管线见下一节）。

### `VideoProbe`（Kotlin）只做读

- `probe(path)`：编码尺寸、旋转、时长、有无音轨、文件大小；
- `extractFrame(path, out, positionMs)`：抽一帧写成 PNG，**回传这张 PNG 的真实尺寸**。

**两个尺寸必须分开**：`width/height` 是编码尺寸（帧解码出来也是这个），
`displayWidth/displayHeight` 是按旋转交换过的用户可见尺寸。
竖拍视频常见「1920×1080 + rotation=90」，混用一定框歪。

### 旋转不靠猜，靠宽高比判断

`getFrameAtTime` 是否已经替我们旋转，**不同机型行为不一致**。
所以不假设，取回帧后用「宽高比换没换过来」判断，没换就自己 `Matrix.postRotate`。
判错的代价是 Mask 整体歪 90°，比多转一次严重得多。

### 封面帧与 Mask 的坐标系

封面帧按最长边 ≤1080 缩放（再大对框选没帮助，只是白占内存），
所以**封面尺寸通常小于视频尺寸**。这正是 `MaskPlan` 坚持用归一化 0..1 的原因：
框选在封面上做，处理时按真实帧尺寸乘回去，两边不需要知道对方的分辨率。

### 实测（华为 JER-AN10，`assets/samples/sample.mp4`）

```
VITEST_META  960x540 rot=0 display=960x540 dur=5056ms audio=true bytes=1128375
VITEST_FRAME 960x540 305929B decoded=960x540 759ms
+2: All tests passed
```

样例视频是 **MDN 的 `flower.mp4`（CC0）**，1.1 MB。
设备上没有 `screenrecord`（华为裁剪掉了），本机也没有 ffmpeg —— 这是当时能找到的
最小且授权干净的方案。

⚠ **没验到的分支**：这个样例 `rotation=0`，所以旋转校正那段代码在真机上**没跑过**。
等有竖拍视频样本时再补一条用例。

---

## 八、视频链路 · 第二块：处理管线（已打通）

```
MediaExtractor 读视频轨
  → MediaCodec 解码 → Image(YUV_420_888)
  → BGR Mat → ImageProcessor.inpaintBgr（与图片路径**同一份** OpenCV 代码）
  → YUV_420_888 → MediaCodec 编码
  → MediaMuxer 封装（音轨压缩数据原样搬运）
```

第一版只做**「镜头静止 + 同一张 Mask 套所有帧」**，不碰光流追踪。
输入是**归一化选区**（0..1，相对用户看到的画面），不是像素、也不是 Mask 图。

### 这一段真正的难点不是 OpenCV，是这三件

**1. YUV 不是 RGB。** 解出来的原始帧是 `YUV_420_888`：一个亮度平面 + 两个色度平面，
每个平面各自有 `rowStride` / `pixelStride`。有的机型是 planar（I420），有的是
semi-planar（NV12，U/V 交错共用一块内存）。用 `getOutputImage()` 拿 `Image` 对象，
它把三个平面的 stride 摊给你；靠 `ByteBuffer` 自己算偏移一定会踩到某个厂商。

**2. PTS 必须原样带过去。** 解码出来的每帧带一个 `presentationTimeUs`，那是播放时间轴。
重新编码时必须原值喂给编码器，**不能**用「帧号 × 1e6/fps」自己算 —— VFR 视频会音画不同步，
慢镜头处还会累积漂移。PTS 是这条链上唯一可信的时间来源。

**3. 音轨不需要解码。** 音轨是压缩数据（AAC），从输入 MP4 逐条 sample 搬到输出 MP4 就行，
一个字节都不用碰。解码再编码只会掉质量、浪费时间，还容易踩采样率/声道数的坑。

### 三个「不猜」的决定

| 决定 | 不这么做的后果 |
|---|---|
| 画幅以**容器里记的源尺寸**为准，不信解码器 | 华为把 960×540 解成 960×544（540 不是 16 的倍数），成品会变成 960×544 |
| 旋转**不重排像素**，只写 `muxer.setOrientationHint(rotation)` | 每帧都要转 90°，白烧 CPU，还会改变画幅 |
| 编码器输入用 `getInputImage()`，不用 `getInputBuffer()` | 后者是一块布局未定义的裸内存，写进去颜色一定错 |

Mask 的坐标要逆着 rotation 转回帧坐标系（`mapMaskToFrame`）。以 rotation=90 为例：
帧上一点 `(x,y)` 转到显示坐标系是 `(H-1-y, x)`，反解就是 `x = v·W`、`y = (1-u)·H`。
四种角度都是仿射，矩形转完仍是轴对齐矩形，不用做多边形。

### 踩到的三个坑（都有具体数字）

| 现象 | 根因 | 修法 |
|---|---|---|
| `index=261120 out of bounds (limit=261120)` | 色度索引按「每个像素前进一个 `pixelStride`」写，在 NV12（`pixelStride=2`）上等于色度被按 2× 速率消费，读到行末就冲出去 | 按**色度坐标**算：`cu=x/2`、`cv=y/2`，索引 `cv·rowStride + cu·pixelStride`。planar / semi-planar 自动都对 |
| 成品 960×544，源文件 960×540 | `decoder.outputFormat` 报的是**解码尺寸**（带对齐 padding），不是画面尺寸 | 画幅取容器 track format 的 `width/height`，并夹在 `Image` 尺寸以内 |
| `sizeBytes` 报 1,304,248，实际文件 1,562,172 | `MediaMuxer` 带缓冲，没 `stop()` 就读 `File.length()`，量到的是已刷出去的部分 | 先 `stop()` + `release()` 再量；测试里加了「文件大小必须大于视频+音频字节和」的断言拦复发 |

第一条的报错数字是 `960 × 272` —— 272 正好是 544/2，这个巧合是定位的关键。

### 实测（华为 JER-AN10，`assets/samples/sample.mp4`）

```
VRTEST_IN    960x540 rot=0 dur=5056ms audio=true 1128375B
VRTEST_OUT   960x540 rot=0 frames=150 skipped=0 video=1397636B audio=161792B
             hasAudio=true mask=15824px 1562660B 5025ms 29.9fps
VRTEST_META_OUT 960x540 dur=5056ms audio=true          ← 时长一毫秒不差
VRTEST_PIXEL inside_changed=68.7% outside_mae=3.51 global_mae=4.74
+2: All tests passed!
```

三条断言各自守一个失败面：

- **容器层**：分辨率一致、时长差 <120ms、音轨还在、文件大小 > 样本字节和；
- **内容层**：框内必须有 >60% 像素发生可见变化（阈值 12，滤掉重编码噪声），
  框外 MAE 必须 <6 —— 超过 6 就不是「修得不准」，而是**整个画面颜色被改了**；
- **性能**：只打印不判定（取决于机型）。

`outside_mae=3.51` 说明 YUV 往返 + 重编码是忠实的。这个数在本项目里是**颜色正确性的指纹**：
逐像素版和快路径版各测一次，都必须是 3.51；换成 100+ 就是红蓝通道被换了。

### 性能：从 2.7 fps 到 29.9 fps（11 倍）

第一版用逐像素 Kotlin 循环做 YUV ↔ BGR，5 秒的片子要 56 秒：

```
perf 150f decode=18151ms inpaint=17383ms encode=17969ms   （各占总耗时约 1/3）
```

三段几乎等长，说明瓶颈**不在 OpenCV**，在那一帧 518k 次的「读 3 个 YUV 分量 →
定点转 RGB → 写 3 个字节」，以及反向再来一遍。debug 构建下这段循环是**解释执行**的：
方法只被调用 150 次，远不到 JIT 阈值，热点又在方法内部的循环里，OSR 也没进来 ——
证据是从第 30 帧到第 150 帧每帧耗时完全平坦（122.3 / 122.9 / 119.3 / 119.7 / 120.9 ms），
**没有预热曲线**。

改成「整块 memcpy + OpenCV SIMD」之后：

```
perf 150f decode=241ms inpaint=2925ms encode=350ms
```

| 段 | 优化前 | 优化后 | 倍数 |
|---|---|---|---|
| decode（YUV→BGR） | 18151 ms | **241 ms** | 75× |
| encode（BGR→YUV） | 17969 ms | **350 ms** | 51× |
| inpaint | 17383 ms | **2925 ms** | 6×（这段代码没动，见下） |
| **合计** | **56074 ms** | **5025 ms** | **11.2×** |

- **解码**：semi-planar 下 UV 本来就是交错的，所以不需要逐像素解交织 —— 把 Y 与 UV
  按行整块拷进一个连续缓冲拼成标准 NV12，交给 `Imgproc.cvtColor(COLOR_YUV2BGR_NV12/NV21)`。
  Kotlin 只做 memcpy。
- **编码**：OpenCV **只提供解码方向的 NV12 转换**，`COLOR_BGR2YUV_NV12` 根本不存在（写了是编译错误）。
  所以拆两步：`COLOR_BGR2YUV_I420` 得到 Y/U/V 三块，再用 `Core.merge(u, v)` 把两个单通道平面
  合成双通道矩阵 —— 内存布局天然就是 `U0 V0 U1 V1…`。
- **inpaint 那 6 倍不是这一轮改的**：代码一个字没动，我推测是上一轮测量时整机被前两段的
  满载拖进了降频（日志里 `Thermal-daemon` 一直在刷），但**没验证**，别当成结论。

25 ms/帧 的修复预算里，现在 inpaint 占 19.5 ms（78%），是下一个瓶颈。

#### inpaint 19.5 ms 拆开：**不是算法慢，是 Mask 太粗**

手机上的 `tInpaint` 只记了一个总时间，看不出钱花在哪。用同版本 OpenCV（4.14）在 PC 上
按 `ImageProcessor.inpaintBgr` 的语句逐句复现（`D:/dev/vt/inpaint_breakdown.py`），
960×540、框 173×92（与 `motion_test` 同形状）、`radius=3`：

| 步骤 | 耗时 | 占比 |
|---|---|---|
| **`Photo.inpaint` TELEA（ROI 内）** | **14.76 ms** | **85%** |
| 全帧 `findNonZero` 扫描（找 Mask 外接矩形） | 0.76 ms | 4% |
| 全帧 `clone`（1.5 MB）×1 | 0.68 ms | 4% |
| 贴回 | 0.74 ms | 4% |
| 合计 | 17.32 ms | — |

PC 17.3 ms 对手机 19.5 ms，比例一致。**clone 那些省下来最多 1.5 ms，没用。**

那为什么同一份代码在另一处只要 4 ms？因为 **TELEA 的耗时基本正比于洞的面积**：

| Mask 形状 | 洞面积 | 耗时 |
|---|---|---|
| 真实笔画（文字级） | 2 050 px | **4.32 ms** |
| 用户画的整框 | 15 916 px | **14.76 ms** |

整框是笔画的 **7.9 倍** —— 那 4.7 倍的时间修的是**本来干净的背景**。

#### 两条被实测否掉的路

在**有真值**的画面上比（`lake-clean.png` 盖一行白字，与原图算 PSNR，
`D:/dev/vt/inpaint_quality.py`）：

| 方案 | 耗时 | PSNR | 均值差 |
|---|---|---|---|
| **TELEA + 精确笔画 Mask**（理论上限，不是能拿到的方案） | 4.04 ms | **28.79 dB** | **4.08** |
| TELEA + 整框 Mask（现状） | 7.08 ms | 20.78 dB | 15.03 |
| TELEA 1.5× 降采样 | 4.07 ms | 14.53 dB | 34.18 |
| TELEA 2× 降采样 | 2.30 ms | 14.26 dB | 35.11 |
| 最近邻边界填充（O(n)） | 75.73 ms | 14.25 dB | 24.05 |
| 最近邻 + 中值 | 109.67 ms | 15.05 dB | 20.64 |
| （完全不修） | — | 7.02 dB | 73.55 |

- **降采样死路**：28.79 → 14.53 dB，均值差从 4.08 涨到 34.18，肉眼看就是一片花。
  省下 2 ms 不值这个价。
- **最近邻更死**：又慢又差。笔画的洞虽窄，但取最近边界像素会把两侧不同颜色的背景
  拖进来，锯齿感极强；而且 `distanceTransformWithLabels` 的标签表在整帧上做，比 TELEA 还贵。
- **整框比文字级差 8 dB、慢 1.75 倍** —— 这就是「矩形 Mask 糊背景」的量化证据，
  和之前在木纹上量到的 3356 像素损伤是同一个病。

#### 修复强度（radius）：界面默认 8 px 是有依据的，不是照抄原型

`radius`（TELEA 邻域半径）一直是内部参数，用户看不到。原型上写着「修复强度 · 标准 · 8 px」，
2026-10-22 把它做成滑块（2..16，默认 8）。问题在于：**历史质量数字全是 6 px 测的**
（`ProcessingRequest` 原来按 `outputQuality` 推导，standard → 6）。默认值从 6 变 8，
等于让所有人跑在一个没测过的参数上。

于是用同一套真值基准扫了一遍（`D:/dev/vt/radius_sweep.py`，`lake-clean.png` 盖白字，
PSNR 只在 mask 及 2px 邻域内算）：

| radius | 涂抹（贴合笔画）PSNR | 框选（外接矩形）PSNR |
|---|---|---|
| 2 | **28.98 dB** | 20.66 dB |
| 4 | 28.62 | 20.85 |
| **6**（历史基准） | 28.22 | 21.00 |
| **8**（界面默认） | 27.97 | 21.08 |
| 10 | 27.72 | **21.10** |
| 16 | 27.20 | 20.95 |

两个结论：

1. **两种 mask 的最优半径方向相反**。涂抹越贴笔画，半径越大越会把周围细节抹平
   （单调下降，2px 最好）；框选的洞大，半径小了扩散不出去，8～10px 才到顶。
2. **8 正好落在两条曲线的平坦区**：比涂抹最优差 1 dB，比框选最优只差 0.02 dB。
   所以默认 8 **没有代价** —— 这是扫出来的，不是「原型写了 8 就 8」。

⚠ 两条限制：一是基准图是 960×540，而真机照片动辄 4000px 宽，水印笔画也更粗，
**绝对最优值会随图放大**（radius 是像素单位，不随分辨率缩放）；二是 8px 下
`outside_mae=3.51` 那批历史数字**没有复测**，所以集成测试仍走 `ProcessingRequest` 的默认推导（6），
基准不漂。滑块上限 16 就是给大图留的余量。

顺带量到一件比调参更有价值的事：**同一张图、同一算法，「涂抹」比「框选」高 7 dB**
（28.0 vs 21.1）。这是「涂抹」这个功能价值的第一个量化证据 —— 它不是为了好玩才加的。

所以瓶颈的方向是**把 Mask 收紧到笔画**，但这条路**在深入跑过之后被否掉了** —— 过程如下。

#### 文字级 Mask：单场景看着可行，多场景扫描后否掉

第一版（`top-hat` 亮笔画 + `black-hat` 暗笔画 + 各自 Otsu + 连通域过滤）在两个场景上都很漂亮：

| 场景 | 检出 | 残留 | 耗时 |
|---|---|---|---|
| cafe.jpg（浅灰字压近黑背景） | 1458/4320 px = 33.8% | 0 | — |
| 视频帧 960×540、框 173×92 | 3353/9154 px = 36.6% | 0 | 11.18 → **4.84 ms** |

但这两个其实是同一类场景：**强对比 + 低纹理背景**。扩到 8 个场景再比
（`D:/dev/vt/mask_text_sweep.py`，指标用 recall = 真值笔画被遮住的比例，漏检才是真事故）：

| 场景 | recall | 说明 |
|---|---|---|
| 深色字压亮底 | **100%** | black-hat 有效 |
| 6px 小字 | **100%** | 但 precision 只有 35%，虚警多 |
| cafe 真实水印 | **100%** | 背景纯黑，最好情况 |
| 40px 大字 | 85% | 9×5 的核比笔画窄，大字内部被挖空 |
| 彩色红字 | 41% | 灰化把红字在蓝绿湖面上冲掉了 |
| 白字·半透明 0.5 / 0.3 | 9.3% / 12.9% | 对比不足 |
| **白字·亮底（弱对比）** | **0%** | Otsu 切出来几乎是空 mask |

**8 个场景挂 5 个。** 两个根本原因：

1. **弱对比时 Otsu 失效**。top-hat 直方图没有双峰，阈值落在噪声里，检出的 360 px 全是散的，
   一个笔画都没盖住。
2. **有纹理时 top-hat 抓的是背景，不是水印**。湖面波纹同样是「细的亮结构」，分不开。
   实测 mask 位置正确地覆盖了水印区域，但 `hit = 0` —— 722 个像素**全落在波纹上**。
   cafe 能成，纯粹因为背景纯黑、没有高频可抢。

第二版（Lab 三通道代替灰度 + 多尺度核 + 百分位兜底）**更差**：0% 的场景从 1 个变 6 个。
a/b 通道在无彩色区域恒为 128，Otsu 给不出有效切割，只会往并集里灌噪声。

#### 想用「背景复杂度」自动分诊，也不成立

思路是纹理乱就退回整框（失败安全）。实测没有相关性：

| 场景 | 框内 std | 梯度均值 | edge 密度 | recall |
|---|---|---|---|---|
| 白字·亮底 | 45.5 | 92.6 | 0.154 | **0%** |
| 深字·压亮底 | 59.9 | 136.6 | 0.158 | **100%** |
| cafe 真实 | 22.4 | 60.7 | 0.118 | 100% |

深字压亮底的纹理比白字亮底**更复杂**，recall 反而 100%。决定成败的是
**水印与背景的亮度差**，不是背景乱不乱 —— 而这个差值要在知道水印在哪之后才能算，循环依赖。

#### 结论

- **不接进 Kotlin。** 它现在的可靠性是「限定场景可用」，而漏检意味着水印留在片子里，
  比慢 15 ms 严重得多。
- 上一版梯度 `refineMask` 栽在「判据选错」，这一版栽在「把最好情况当成普遍情况」——
  同一个教训：**先造覆盖分布的场景集，再下结论**。
- 真正可行的方向按代价排：
  1. **让用户把框画紧**（交互层，零算法风险）—— 框紧则洞小，又快又不糊；
  2. **时间维度分离**：静态水印在多帧里恒定、背景在动，用时间中值/方差定位，
     前提是相机在动（`motion_pan` 那套素材正好能验）；
  3. AI 分割（LaMa）：重，但不需要假设「水印是细笔画」。

#### 快路径的三个坑（都实测踩过）

| 现象 | 根因 | 修法 |
|---|---|---|
| 编译期 `Unresolved reference 'COLOR_BGR2YUV_NV12'` | OpenCV 只有 `YUV2BGR_NV12`，反向没有 | `BGR2YUV_I420` + `Core.merge(u,v)` 交错出 NV12 的 UV 平面 |
| `ProcessingException(native_failure)`，第 1 帧就挂 | UV 区共 259200 B，但 U 平面 buffer 只有 **259199**（两个平面互为 ±1 偏移，谁也够不到对方那一头），一次 `put` 写满就越界 1 字节 | 逐行写、尾部字节从**另一个平面**的 buffer 补 |
| 真机上 `NoSuchMethodError`（本机没走到，靠读 API 发现） | `buffer.put(index, src, off, len)` 是 Java 13 才加的重载，Android 要 API 33 | 一律「先 `position` 再 `put`」，API 1 就有 |

另外两件事值得记：

- **UV 顺序（NV12 还是 NV21）Android 不告诉你**，判错的后果是「颜色错了但没有任何异常」。
  所以两处都做了**自证**：解码侧在首帧解完之后用慢速公式抽查 5 个像素比对（对不上就翻转顺序重解，
  再不行就永久退回慢路径）；编码侧在输入平面上造标记探测（铺 100 → V 平面首字节写 200 →
  看 U 平面第 2 字节是不是 200）。日志里会打 `decoder UV order probed` / `encoder UV order probed`。
- `Mat.put(0,0,byte[])` **要求数组长度与 Mat 完全一致**。用 `rawW*rawH` 的缓冲喂 `w×h` 的 Mat，
  在「解码尺寸 544 / 画面 540」这种带对齐 padding 的机型上会直接抛断言 —— 所以 `ensurePacked(w,h)`
  按可见画幅懒分配。

---

## 九、视频链路 · 第三块：镜头运动（已打通）

静态水印一张 Mask 套所有帧就够了；**镜头一动，同一张 Mask 立刻修到框外**。
这一段做的是「让 Mask 跟着画面走」。

### 为什么必须先造素材，再写代码

手上唯一的真实视频（`sample.mp4` 花瓣特写）里没有真水印，只有一块被框起来的花瓣。
拿它验「跟得准不准」只能靠肉眼 —— 那不是证据。

所以素材是**造出来的**，位移由脚本按整数像素逐帧指定：

| 素材 | 造法 | 真值 |
|---|---|---|
| `assets/samples/motion_still.mp4` | 150 帧同一块裁剪 | 位移 `(0, 0)` |
| `assets/samples/motion_pan.mp4` | 第 n 帧裁剪左上角移到 `(2n, n)` | 内容左上移 `(298, 149)` |
| `assets/samples/motion_zoom.mp4` | 第 n 帧把源缩放到 `960+144n/149` 宽再**居中裁** 960×540 | 绕中心放大 `1.15` 倍 → `scale=1.15`、`t=(-72, -40.5)` |
| `assets/samples/motion_shake.mp4` | 每帧 `p' = R(θ_i)·p + t_i`，`θ/dx/dy` = 线性漂移 + 正弦抖动 | 末帧 `angle=2.4862°`、`scale=1.0`、`t=(59.36, -39.04)` |
| `assets/samples/motion_rot90.mp4` | 同上 + 画一个红块 + 写入 90° 显示矩阵 | 标记在帧坐标 `(100,100)-(300,200)` |

真值不是「我以为」，是 **PSNR / MAE 反查**过的：在 `motion_pan.mp4` 上按 `(298,149)` 对齐
frame0 与 frame149 得 **32.9 dB**，故意错开 10px 只剩 **14.9 dB**。
`motion_still.mp4` 的 frame0 与 frame149 是 **56.9 dB**（几乎逐像素相同）。

变焦那条反查出来的曲线（把 frame149 缩回 `1/s` 贴回原尺寸，只比中心区）：

| s | 1.10 | 1.13 | **1.15** | 1.17 | 1.20 |
|---|---|---|---|---|---|
| MAE | 26.60 | 15.08 | **4.86** | 13.71 | 25.95 |

峰很尖，`1.15` 不是凑出来的。⚠ **注意方向**：`scale` 放大后再居中裁，看到的是更小的视野 =
**zoom in**，所以内容是「变大」，相似变换 `scale > 1`。第一次反查时我把对齐方向写反了
（去放大 frame149），结果 MAE 从 45 涨到 52 —— 反而更差，才意识到裁切方向搞错了。

**「绕中心缩放」的平移分量不是 0**：`p' = c + s(p-c)` → `t = c(1-s)`，
`c=(480,270)`、`s=1.15` 时 `t=(-72,-40.5)`。断言这个比断言「≈0」有力：它同时验了缩放倍数和缩放中心。

**抖动素材为什么用 Python 生成**：ffmpeg 没有通用仿射 warp —— `rotate` 只能绕中心转、
不能叠平移，`crop` 只能整数平移。手持抖动是「旋转 + 亚像素平移」的复合，滤镜链拼出来的
真值没法一眼说清。`make_shake.py` 用 PIL 的 `transform(AFFINE)` 逐帧生成，
变换固定写成 `p' = R·p + t`（绕左上角），真值就是 `(θ, dx, dy)` 本身。

⚠ 这里连续踩了两次方向错：① 先按「绕中心旋转 + 平移」推 `t` 的补偿项 `c - R·c + d`，
但生成时用的根本不是那个矩阵 → 自检 MAE 83.9；② 改成 `p' = R·p + t` 后，
自检又传了逆映射（PIL 的 `data` 是「输出 → 输入」）→ MAE 65.9。
统一成 `p' = R·p + t` 并让自检传**正向**矩阵后，MAE 降到 **8.37**（两次插值的代价）。

生成脚本在本机 `D:/dev/vt/`：`make_pan.sh`（逐帧显式裁剪）、`make_zoom.sh`（逐帧显式缩放尺寸）、
`make_shake.py`（PIL 仿射）、`make_rot.sh`（加红块 + 打旋转矩阵）、`patch_rotation.py`（写 `tkhd` 矩阵）。

### 算法：为什么是相似变换，为什么在 320 宽上算

- **相似变换（4 自由度：旋转 + 等比缩放 + 平移），不是单应。** 单应 8 个自由度里有 6 个在
  拟合噪声，素材纹理弱时会解出带切变/拉伸的矩阵，框被拉歪。代价是拍倾斜屏幕那种真透视跟不住，
  第一版选稳的那条。
- **工作分辨率 320 宽。** `goodFeaturesToTrack` 代价与像素数线性相关：960×540 是 518k 像素，
  320×180 只有 58k，耗时降到 1/9；位移是全局的，缩到 1/3 后精度损失不到 1 像素。
- **判据是内点数。** 少于 12 个内点就认为「这一帧估不准」，返回 `ok=false`，
  调用方**沿用上一帧的变换**（不清零 —— 清零等于让 Mask 突然弹回原位，画面上会看到水印跳出来）。

实现在 `MotionEstimator.kt`（约 340 行），`VideoProcessor` 里 `trackMotion=true` 时逐帧调用，
把首帧的框四角按累计变换推过去、用 `fillConvexPoly` 重画 Mask。

### 四组断言，各守一个失败面

| 断言 | 守的是 | 实测（华为 JER-AN10） |
|---|---|---|
| 自检：已知平移/旋转/缩放 warp 真实照片，让估计器还原 | 算法本身 | 位置误差 **0.04 / 0.29 / 0.14 / 0.39 px**，角误差 ≤ 0.02°，缩放误差 ≤ 0.0002 |
| 静止素材：累计位移必须仍是 0 | 光流亚像素偏置累积 | `shift=(-0.01, -0.00)`，`drift=0.00px` |
| 已知平移：方向与幅度都要对 | 只断模长会把「反了」当通过 | `shift=(-294.04, -150.99)`，真值 `(-298, -149)`，误差 4.0 / 2.0 px |
| 第 120 帧：移动后的位置必须被修，原位置不能动 | Mask 到底跟没跟 | `mae(移动后框)=27.52` / `mae(原框)=4.83` / `mae(框外)=4.12` / `mae(全帧)=4.84` |

最后一行是关键：如果 Mask 没跟着走，`mae(移动后框)` 会掉到 4 左右（那里根本没被修），
而 `mae(原框)` 会跳起来。两个数字一起看才排得掉「两边都修了」这种中间态。

### 五个坑（都有具体数字）

| 现象 | 根因 | 修法 |
|---|---|---|
| 造的 pan 素材每帧其实走了 **4.3 px**，不是 2 px | `-r 30` 作用在滤镜**之后**，`crop` 里 `n` 数的是 25fps 源帧；`fps=30` 放进滤镜链也不稳 | 干脆不用表达式：逐帧算好偏移、显式 `crop=960:540:$x:$y`，ffmpeg 只负责编码 |
| `mp4` 出来是 `yuvj420p(pc)` + `SAR 3135:3136` | JPEG 的全范围与怪 SAR 顺着色链漏进封装 | `scale=...:in_range=pc:out_range=tv` + `setsar=1` + `-pix_fmt yuv420p -color_range tv` |
| 抽帧后整帧 MAE 六十多，看着像「跟踪全错」 | `OPTION_CLOSEST_SYNC` 只给关键帧：输入每 15 帧一个、输出每 30 帧一个，4500ms 上两边给的是不同帧 | 挑**两边都精确命中**的时间点（4000ms = 第 120 帧）；并打 `mae(全帧)` 作为「对齐体检」 |
| 抽出来的「竖屏帧」是 **540×304** | `METADATA_KEY_VIDEO_WIDTH/HEIGHT` 给的是旋转后尺寸（540×960），`getScaledFrameAtTime` 把未旋转的 960×540 塞进 540×960，得到 540×304；再被 `width > height` 判成「已换过来」，跳过旋转 | 改用 `getFrameAtTime` 取原尺寸 → 判「该竖却横」→ `postRotate` → 最后统一 `createScaledBitmap` |
| 旋转测试**假通过**：`修前=21862 修后=0` 漂亮，实际 Mask 盖了 77%×73% 的画面 | 红色判据 `r>150 && g<90 && b<90` 把暗橙木色 `(156,85,16)` 也算成红 | 判据改成「红显著压过绿蓝」（`r>160 && r-max(g,b)>110`）；并加**守卫断言**：包围盒面积必须 < 6%、长宽比必须是 1:2 竖条 |

### 旋转：真机实测出来的方向约定

同一个 `tkhd` 矩阵，**ffmpeg 报 90°、Android 报 270°** —— 两边的符号约定相反。
这是实测出来的，不是推理。所以测试**不假设方向**：

1. 素材里画一个已知位置的红块；
2. 用 App 自己的 `extractFrame` 取「正向化之后」的画面（这就是用户看到的）；
3. **在画面里找出红块的实际像素位置**，把它当框选区域传进去；
4. 修完再取一帧，红块必须消失。

实测：`帧=540x960 rot=270`，红块定位到 `x 100..200, y 660..860`（100×200，占画面 3.9%），
传进去后 `修前=20000 修后=0 残留=0.0%`；产物 `probe` 仍是 `rot=270 显示=540x960`，
时长 1000ms → 1000ms。这说明 `mapMaskToFrame` 的 270° 分支和 `muxer.setOrientationHint` 都对。

### 从「对上一帧估」改成「对关键帧估」

第一版是每帧对**上一帧**估增量、再乘进累计变换。问题很直接：150 帧就是 150 次链式累积，
每帧的亚像素偏置会被乘上帧数。

现在的做法：维护一个**关键帧**（基准帧）和它自己的累计变换 `keyCumulative`，
每帧从关键帧直接算增量：

```
cumulative = compose(keyCumulative, motion(key → 现在))
```

误差只在**换关键帧的那几次**里传递，不再每帧传递一次。换关键帧有四个触发条件：

| 条件 | 阈值 | 为什么 |
|---|---|---|
| 位移太大 | `shiftPx > 45`（原图像素） | 光流跟不跟得住取决于基准帧与当前帧差了多远。工作分辨率 320 宽、LK 3 层金字塔，上限约 20px（工作分辨率）= 60px 原图，取 45px 留余量 |
| 内点太少 | `inliers < 60` | 自检里干净照片有 190~200 个内点，掉到 60 说明已经跟丢大半，再估就是拿噪声拟合 |
| 估计失败 | `ok == false` | 直接换基准重新抓特征 |
| 用得太久 | `framesSinceKey >= 60` | 兜底：镜头几乎不动但场景慢慢变了，特征点会老化 |

**内点不足时这一帧不采信**（`motionFailed++`，保持上一帧的变换）—— 只换关键帧，
不让一个勉强及格的估计污染累积。代价是特征持续不足的素材上 Mask 会完全不动（失败安全），
这种情况会体现在 `motionFailed` 计数上。

新暴露两个诊断字段：`keyframeSwitches`（换了几次）、`motionInliers`（最后一次内点数）。

### 没有真机时怎么验：PC 端等价复现

`MotionEstimator` 是纯 OpenCV，**没有一行 Android API**。所以可以在 PC 上用
**OpenCV 4.14.0**（与 `org.opencv:opencv:4.14.0` 同版本）按同样参数复现整条状态机
—— 脚本 `D:/dev/vt/replay_motion.py`。

**先证明复现是真的等价**，再用它下结论。两处独立证据：

**证据一：自检的四组精度逐位吻合**（`motionSelfTest` 用 `cafe.jpg` warp 四组已知变换）

| 用例 | 真机日志（2026-10-18） | PC 复现 |
|---|---|---|
| 平移 | 位置误差 0.04px、角误差 0.00°、inliers 197 | **0.044px / 0.001° / 197** |
| 旋转 3° | 0.29px / 0.02° | **0.291px / 0.017°** |
| 缩放 1.04 | 0.14px、缩放误差 0.0001 | **0.141px / 0.0001** |
| 复合（旋转 −2.5° + 缩放 0.97） | 0.39px / 0.02° | **0.389px / 0.024°** |

四位有效数字全对上。`cornerError` 取的是四角+中心的**最大**误差，不是平均 —— 这个也复现了。

**证据二：累计量级吻合**（旧版逐帧累加，`sample.mp4`）

| | PC 复现 | 真机日志 |
|---|---|---|
| 累计平移 | 43.98px | 43.71px |
| 直接估计 | 23.82px | 20.63px |
| drift | 39.89px | 38.50px |

差不到 1.5px。前者说明单帧估计逐位等价，后者说明多帧状态机也等价。

> ⚠ 复现脚本自己的 `compose(first, second)` 返回 `first @ second`，
> 而 Kotlin 的 `compose(first, second)` 返回 `second · first` —— **同名相反语义**。
> 两边调用点都按各自语义配对过，结果一致；但改代码时别把这两个当同一个函数。

**这也改变了真机断言的价值**：算法层已经被 PC 复现证明，真机剩下的价值是验
**Android 侧集成**（YUV 转换、解码取帧、`Mat` 生命周期）。如果真机数字和上表对不上，
先怀疑这三样，别改算法。

**判据不需要外部真值**：用估出的累计变换把末帧 warp 回第一帧，算 PSNR。
估得越准，末帧就贴得越回去。（先在三块**真值已知**的素材上验证过这个判据：
`motion_pan` 用真值变换对齐是 32.9 dB，故意错 10px 只剩 14.9 dB。）

| 素材 | 旧版逐帧累加 | 关键帧跟踪 | 提升 |
|---|---|---|---|
| `motion_pan`（纯平移） | MAE 14.70 / 20.79 dB | **MAE 1.52 / 40.05 dB** | MAE ÷9.7 |
| `motion_zoom`（1.15 倍变焦） | MAE 7.16 / 25.83 dB | **MAE 2.93 / 30.99 dB** | MAE ÷2.4 |
| `motion_shake`（旋转+平移） | MAE 10.11 / 23.36 dB | **MAE 3.85 / 30.73 dB** | MAE ÷2.6 |

累计变换对真值的误差也同步下降：

| 素材 | 旧版 | 关键帧版 |
|---|---|---|
| 静止 | 0.01px | 0.01px |
| 平移 | t 差 4.4px、角度差 0.073° | **t 差 0.38px、角度差 0.003°** |
| 变焦 | 缩放差 +0.0023 | **−0.0002** |
| 抖动 | 角度差 0.196°、t 差 5.5px | **角度差 0.028°、t 差 1.05px** |

**参数扫描**（同样用这个判据，不碰真机）：

- `MAX_KEY_SHIFT = 20` 比 `45` **更差**（pan 素材 MAE 2.48 vs 1.52）——
  换帧太频繁，等于把累积次数加回去
- `MAX_KEY_SPAN` 在 15 / 30 / 60 / 90 / 150 之间，误差差异 < 0.2px。
  保留 60 是因为它只在「镜头几乎不动」时才起作用，那正是特征点老化的场景

### ⚠ 能力边界：相似变换装不下的素材

`sample.mp4` 是 MDN 的 `flower.mp4` —— **一朵花在绽放**。画面内容本身在变形，
不存在任何全局变换能让它对齐：

| 跨度 | 相似（4 dof） | 仿射（6 dof） | 单应（8 dof） |
|---|---|---|---|
| f0–f1 | 27.91 dB | 27.98 dB | 28.81 dB |
| f0–f30 | **18.54 dB** | 18.42 dB | 16.75 dB |
| f0–f75 | **16.73 dB** | 15.32 dB | 14.83 dB |
| f0–f149 | **15.60 dB** | 13.34 dB | 11.83 dB |

**自由度越高越差** —— 多出来的自由度全在拟合花瓣的运动。而且 f0–f149 的 15.60 dB
跟「完全不对齐」的 16.25 dB 基本一样：相似变换在这段素材上等于没干活。

所以上一版那句「逐帧累加 43.71px vs 直接估 20.63px，谁准判不了」要修正为：
**在那个素材上两者都没有物理意义**，不是精度之争。它的 `direct` 估计只有 26 个内点
（干净照片 190+），也是同一件事的症状。

这条边界必须写在产品能看见的地方：`trackMotion` 的适用前提是**场景刚性 + 相机在动**。
拍延时摄影、慢动作特写、有物体大幅移动的场景，跟随会让 Mask 偏 —— 这时用户应该关掉它。
`trackMotion` 仍默认 `false`，理由不是「没验」，而是**用户得先判断自己的素材是不是这一类的**。

**试过自动判断，判据不成立。** 想用「内点数 / RANSAC 残差」在运行时分出「能跟 / 不能跟」，
用 PC 复现量了五条素材：

| 素材 | 内点中位 | 内点/跟踪点 | 残差中位 |
|---|---|---|---|
| still | 200 | 1.000 | 0.00px |
| pan | 193 | 1.000 | 0.05px |
| zoom | 195 | 1.000 | 0.11px |
| **shake（刚性，但动得大）** | 198 | 1.000 | **3.70px** |
| **sample（非刚性）** | 117 | 0.707 | 2.63px |

残差不但分不开，还**反了** —— 抖动的 3.70 高于花瓣的 2.63。因为残差衡量的是
「帧间位移大 → 光流精度下降」，不是「刚性」。内点比例倒能分（0.707 vs 1.000），
但它本质是**纹理质量**：一张纹理弱但刚性的素材会被误判成「不适合跟随」。

要真做自动分诊，得用「对齐之后画面还剩多少结构性差异」（自对齐 PSNR 这类整帧统计，
40.05/30.99/30.73 vs 16.31 dB 是分得开的），代价是额外解码一遍。
这正好落在「两趟管线」那条待办上 —— 第一趟本来就存了每帧变换，顺手就能算出
自对齐 PSNR，把「这段素材适不适合跟随」判出来。

**真机断言已跑（2026-10-19，华为 JER-AN10 / Android 12）**，八个数字与 PC 复现逐位吻合：

| 用例 | PC 复现 | 真机实测 | 判定 |
|---|---|---|---|
| 平移 | posErr 0.04px · inliers 197 | **0.04px · 197** | 同 |
| 旋转 3° | 0.29px · 角 0.02° | **0.29px · 0.02°** | 同 |
| 缩放 1.04 + 平移 | 0.14px · 缩放差 0.0001 | **0.14px · 0.0001** | 同 |
| 复合（-2.5° + 0.97 + 平移） | 0.39px · 角 0.02° | **0.39px · 0.02°** | 同 |
| `motion_still` | shift (0,0) · keyframes 2 | **(-0.00,-0.00) · 2** | 同 |
| `motion_pan` | (-298.3,-149.2) · keyframes 7 | **(-298.47,-149.25) · 7** | 同 |
| `motion_zoom` | scale 1.1498 · t (-71.7,-39.9) · keyframes 2 | **1.1497 · (-71.62,-39.80) · 2** | 同 |
| `motion_shake` | angle 2.458° · t (59.6,-40.1) · keyframes 2 | **2.472° · (59.37,-40.66) · 2** | 同 |

关键帧切换次数 2/7/2/2 两边完全一致 —— 这比像素误差更有说服力：它证明
**四个换帧判据在 Android 侧（真实解码帧、真实 `Mat` 生命周期）触发的时机和 PC 上一模一样**。

`motionRotationDeg` 的符号也在真机上验了：生成素材时 θ 取正（`p' = R(θ)·p + t`），
真机解出 **+2.472°**，同号 —— `atan2(m[3], m[0])` 在图像坐标系（y 向下）下为正即顺时针，
与生成方向一致，没有镜像。

顺带把 `motion_test` 的 Mask 跟随用例也跑了：第 120 帧
`mae(移动后框)=28.03 > mae(原框)=4.83 > mae(框外)=4.12` ——
移动后的位置被修过、原位置没被误伤、框外干净，方向对。
（注意这里 `_maeIn` 量的是**输入帧 vs 输出帧的差异**，不是对齐误差：数值大表示「改过了」，
所以 28.03 高是好事。）


### UI：只有一个开关，默认关

原型里那张「静止 / 跟随」的取舍保留了下来 —— 不让用户选「静态水印 / 动态水印」这种术语，
只问「它到底动没动」：

| 状态 | 文案 | 开关 |
|---|---|---|
| 关（默认） | **水印静止** · 选框固定不动。水印会动的话会被漏掉 | off |
| 开 | **跟随画面** · 镜头动，选框跟着走。画面本身在变形时会跟不准 | on |

转码中这个开关会**收起**（改的是下一次修复的行为，让它可点只会让人以为改了当前这次）。
`VideoEditState.trackMotion` 默认 `false`，`startRepair` 把它透传给 `VideoRepairer.repair`。

---

## 十、验证证据（本机实测，2026-10-18）

| 项 | 结果 |
|---|---|
| `dart analyze` | `No issues found!`（用 `dart analyze`，**不要用 `flutter analyze`**：它走 LSP 通道，中文路径下会把 JSON 消息截断后崩掉，`analysis server exited with code 255`） |
| `flutter test` | `+170: All tests passed!`（2026-10-27；分文件计数见下表各行）。⚠ 跑前先 `unset *_proxy`，否则 `flutter_tester` 的本地 WebSocket 会被系统代理拦掉，报 `Invalid WebSocket upgrade request` —— 现象极像 App 崩了 |
| **关键帧跟踪（真机）** | 三个集成用例全绿：`video_probe +2` / `video_repair +2` / `motion +7`（共 11 条断言）。八个运动量与 PC 复现逐位吻合，见上文对比表 |
| `flutter build apk --debug` | `build/app/outputs/flutter-apk/app-debug.apk`，**162,145,519 B ≈ 154.6 MiB**，Gradle 任务 216s |
| 真机安装 | 华为 JER-AN10（Android 12 / API 31），`adb install -r` Success |
| 真机启动 | `mCurrentFocus=cn.shuiyin.watermark_remover/.MainActivity` |
| 真机截图 | `.workbuddy/shots/01-首页.png`、`02-历史.png`、`03-我的-深色.png` |
| **真机 OpenCV 修复** | `ITEST_OK size=1200x896 elapsed=1961ms changedPixels=565` |
| **保存到相册** | `ITEST_SAVED uri=content://media/external_primary/images/media/141301`，`adb pull` 取回 1,761,301 B |
| **修复效果** | `.workbuddy/shots/crop-final.png`：水印彻底消失，无可见涂抹（改动覆盖率 19%，粗糙度 1.28×对照带） |
| **视频探测** | `VITEST_META 960x540 rot=0 dur=5056ms audio=true` / `VITEST_FRAME 960x540 305929B 759ms`，`+2: All tests passed` |
| **视频修复管线** | `VRTEST_OUT 960x540 frames=150 skipped=0 hasAudio=true 1562660B 5025ms 29.9fps`，`+2: All tests passed` |
| **视频修复质量** | `inside_changed=68.7% outside_mae=3.51 global_mae=4.74`；时长 5056ms → 5056ms 一毫秒不差 |
| **YUV 快路径** | 56074 ms → **5025 ms**（11.2×）；`outside_mae` 与逐像素版本**同为 3.51**，证明颜色等价 |
| **视频成品取证** | `frame_before.png` / `frame_after.png` 从真机 `run-as` 取出，框外无差异、框内为 Telea 涂抹 |
| **release 包** | `tool/build_release.sh` → `app-release.apk` **124,513,619 B ≈ 118.7 MB**（arm64），`adb install` Success |
| **运动估计器自检** | 已知平移/旋转/缩放的真值下位置误差 **0.04 / 0.29 / 0.14 / 0.39 px**，`+2: All tests passed` |
| **镜头运动（静止）** | `VTEST_STILL shift=(-0.01, -0.00) drift=0.00px` —— 逐帧累加不漂 |
| **镜头运动（已知平移）** | `VTEST_PAN shift=(-298.47, -149.25)`，真值 `(-298, -149)`，`scale=1.0006`，`keyframes=7` |
| **Mask 跟随（端到端）** | `mae(移动后框)=28.03 / mae(原框)=4.83 / mae(框外)=4.12 / mae(全帧)=4.86`，`+7: All tests passed` |
| **旋转 270°（真机）** | `帧=540x960 rot=270`，红块被定位到 `x100..200 y660..860`，`修前=20000 修后=0`；产物 `rot=270` 保持，`+2: All tests passed` |
| **回归** | `video_probe_test +2` / `video_repair_test +2`（`outside_mae=3.51` 不变）/ `motion_test +7` / `flutter test +10` |
| **装错包事故（2026-10-20）** | 手机上是集成测试包：点开自动进视频页、按钮全失效、切主题卡。`restore_app.sh` 装回正式包后首页正常、三个 Tab 都能点、主题能切（`prod_home.png` / `prod_history2.png` / `prod_profile2.png`） |
| **切主题帧耗时（debug）** | 首次切换一帧 `build=119.4ms raster=8.2ms`；此后三次切换无 >8 ms 慢帧。这是 JIT 首帧代价，不是每帧都慢 |
| **切主题帧耗时（release/AOT）** | 首次切换 `build=24.6ms raster=22.2ms`（掉 1 帧）；随后三次切换零慢帧 |
| **主题装配缓存** | `AppTheme.light()/dark()` 改为 `static final`，不再每次 `build` 重算两遍 `ColorScheme.fromSeed` |
| **跟随开关展开态** | 真机截图已取：开关 on、文案「镜头动，选框跟着走。画面本身在变形时会跟不准」、按钮「开始修复」 |
| **主题持久化（写到盘）** | debug 包 `run-as cat files/theme_mode.txt` → `dark`，确认写入生效；冷启动读取耗时 **136 ms** |
| **主题超时坑** | 300 ms 超时 → `[boot] …TimeoutException after 0:00:00.300000`，每次都回落 system；改 1500 ms 后读取正常 |
| **主题持久化（端到端）** | ✅ **2026-10-24 真机验完**：设「深色」→ `am force-stop` → 从桌面重启 → 仍是深色（首页底色 `#14120E`）；验完改回浅色（`#F4EFE5`）。另附一条拦路经验：**分段控件的 y 坐标别从缩略图估**，第一次点 `(840,724)` 落在控件上方 60 px，白点两次 |
| **历史记录持久化** | `history.json` 往返、坏文件容错、新记录置顶、同 id 覆盖、超 50 条丢最旧 —— 12 条单测全绿；真机「修完一张图后历史里出现」**已于 2026-10-22 验通**（保存后落盘两条，杀进程重启仍在） |
| **历史数据来源** | 首页「最近处理」、历史页「全部/图片/视频」计数、我的页「已完成 N 项」全部改由真实记录派生；新装 App 显示空态而不是假数据 |
| **缓存清理（单测）** | `app_cache_test +8`：白名单只算自己的文件、成果单独计数、`clear()` 保住 `out_*`/`fixed_*`、第三方文件不动、目录不存在不抛 |
| **缓存清理（页面）** | `profile_page_test +9`：显示真实体积（不再是 128 MB）、点击真的调 `clear()`、释放量/保留数/占用数都如实报 |
| **清空历史（页面）** | `history_page_test +5`：二次确认、点取消不写盘、确认后列表与 `history.json` 同步清空、0 条时不弹确认框 |
| **视频保存按钮** | `video_editor_page_test +4`：可点 → 保存中禁用 → 已保存禁用（防写两份）→ 失败可重试；⚠ 真机 MediaStore 写入**未验** |
| **测试总数** | `flutter test` **+170** 全绿 |
| **「跟随」的取证（2026-10-22）** | 原生一直算 `motionTracked` / `motionShiftPx` / `keyframeSwitches`，Dart 也解析进 `VideoRepairResult` 了，但**界面从来没显示过** —— 用户开了「跟随画面」，修完不知道它到底跟没跟上。加了 `motionSummary()`：`跟随 148 / 150 帧对齐 · 首末位移 96 px · 换关键帧 2 次`。两个措辞坑：`cumulativeShiftPx` 是**首帧→末帧**的模长（不是各帧之和，所以写「首末位移」）；`keyframeSwitches` 是**换了几次**（不是几个关键帧） |
| **这一行为什么只在跟踪过才显示** | 镜头静止的视频两个计数都是 0，露一行「跟随 0 帧」只会让人以为坏了。但**「全失败」必须显示** —— 0/150 帧对齐是用户最该知道的消息。条件写成 `motionTracked + motionFailed > 0` 而不是 `motionTracked > 0`，这条做过变异验证：改成后者，「跟踪全失败」那条当场红 |
| **视频页不再露内部术语** | 原来「已框选：归一化 0.400, 0.350 → 0.580, 0.520」直接给用户看。改成 `selectionLabel()` 说像素（`已框选 173 × 92`），**用 `displayWidth/Height` 而不是编码宽高** —— 竖拍 `rot=90` 时两者正好相反，用错宽高会说反。尺寸缺失/退化选区只说「已框选」，不编「0 × 0」 |
| **真机端到端（首次走通，2026-10-22）** | 示例图 → 框选 256×98 → 修复 888 ms / 767 ms → 保存 `Pictures/水印工坊/水印工坊_20261022_155903.png`（1.76 MB，`adb pull` 取回核对）→ 历史两条落盘 → 详情显示「框选修复 · 半径 8 px · 用时 0.8 s」 |
| **「今天」永不翻篇的 bug（真机抓到）** | `HistoryItem.timeLabel` 是**写入时算死的字符串**，注释却写着「隔天自然变成昨天」—— 逻辑说反了。真机 8 条记录跨 10-20～10-22，**全显示「今天」**。改成 `timeLabelAt(now)` 渲染时按 `createdAt` 现算；`timeLabel` 只留作 `createdAt == 0` 老数据的兜底 |
| **现算时间做了变异验证** | `history_page_test` / `history_detail_page_test` 各一条：`createdAt` 设在两天前、`timeLabel` 故意写「今天 10:00」，断言界面**不出现**「今天」。把 UI 改回读 `item.timeLabel` 重跑，两条当场红 —— 只改函数不改界面的话，函数层用例照样绿，这里必须验到 UI。详情页那条要先 `scrollUntilVisible('完成时间')`，否则屏外没构建、`findsNothing` 假通过 |
| **首页** | `home_page_test +7`（这一屏此前只被冒烟测试顺带看一眼）：空态文案 / `最近处理` 只取 2 条 / 入口卡副标题不含 AVI·RMVB / 两个入口真的能进对应页面 / 「全部记录」切历史 Tab / 点记录进详情 |
| **首页那条断言做过变异验证** | 把 `take(2)` 去掉重跑，用例当场红 —— 否则这条件断言可能是**假通过**（`ListView` 懒加载，屏外内容本来就没构建，`take(2)` 写没写都过）。第 3 条断言前必须先 `scrollUntilVisible`，让「它存在就一定会被构建」这个前提成立 |
| **Kotlin 改动进包取证** | 解 release 包里的 `classes.dex`，`grep -a` 到「打不开这个视频」「打不开这张图」「Android 10 以下」各 1 处 —— 证明 14:05 装到手机上的那个包确实含 Kotlin 侧改动。Dart 侧（`libapp.so`，AOT）**查不了**，只能走行为验证，见 §四.10 |
| **图片编辑页** | `image_editor_page_test +35`（这一页此前**一条 widget 测试都没有**，视频页却有 10 条）：空态 / 未标注禁用 / 遮罩像素换算（0.25×0.5 在 1200×896 上是 300×448）/ 修复中 / 有结果 / 保存中 / 已保存 / 保存失败可重试 / 修复失败可重试 / 三工具可切 / 笔宽滑块 / `maskLabel` 纯函数 4 条 / **对比分屏 5 条**（默认停在「对比」、切「前」「后」时收起分界线、拖动时画面跟着走、拖到边缘不飞出画面） |
| **对比分屏：原型有、实现漏了** | 原型结果页顶部是 `修复前 / 对比 / 修复后` **三段**（`class="on"` 在「对比」上），中间那条分界线可拖（`cmpLayer.clipPath = inset(0 0 0 <split>%)`）。实现里只有「原图 / 修复后」两态 —— 切来切去看不出差别，**得同一张画面上并排才看得清水印去没去干净**。新增 `BeforeAfterView`（收 `Widget` 而不是路径，视频结果页以后能直接复用） |
| **对比分屏（真机，2026-10-25）** | 修复 405×110 后进结果页，**默认停在「对比」**，中间一条竖线 + 圆形把手，底部左右角标「修复前 / 修复后」。拖把手到 `x=200`（原 540）→ 分界线跟着走、右侧露出修复后整片，**水印彻底消失**（放大裁图确认 `© THE COZY CORNER CAFE` 整行没了）。切「修复后」→ 只剩结果、分界线收起；切「修复前」→ 整张带水印的原图；保存 →「✓ 已存入相册」，历史页顶部出现「今天 07:40」带缩略图的新记录 |
| **两层图对得齐（数值判据）** | 肉眼在接缝处几乎必然误判（接缝常压在杯子/手的硬边缘上，「断开」本来就是这个分割该有的样子）。改用像素：找接缝列 `x=757`，按距离 d 取 `seam±d` 两列算 MAD，再和同层内相距 2d 的基准比 —— d=8/20/40/60/90 时跨接缝 MAD 是 46/52/62/63/57，同层基准 26–54。**跨接缝没有系统性偏大、也没随 d 增长** → 没有缩放或偏移（若两层缩放不同，MAD 会随距离单调拉开） |
| **角标与分段控件撞车（真机抓到，已修）** | 第一版照抄原型把角标放画面顶部（`.tag.a{left:9px}`）→ 真机上一行读成「修复前 **修复前** 对比 **修复后** 修复后」，像五个选项。根因：原型的三段在**顶部栏**里、不占画面，我们的三段浮在**画布顶部**。角标改到底部；新用例断言「角标不能与分段控件处在同一条垂直带」—— 判据不能写成 rect 相交（角标在两端、分段在正中，从不真的重叠）。变异验证：改回 `top: 9` → 当场红 |
| **`shouldReclip` 是测不到的那种坑** | 第一版用 `ClipRect(clipper: _RightSideClipper(split))`，注释写「`shouldReclip` 必须比较 split，否则图不跟着动」。变异验证：把它改成 `=> false`，**用例照样绿** —— 因为用例读的是 clipper 现算的 Rect，不是真正画出来的裁剪。改成 `Positioned + ClipRect + OverflowBox`（可见区左边界 = ClipRect 自己的位置），再用「把 `left` 写死成 0」做变异，才真正红。**断言要落在渲染路径上，不是自己重算一遍** |
| **视频结果页也有对比（2026-10-27）** | 修完视频后画布仍是**带水印的封面帧 + 选框** —— 用户刚修完就看到水印还在，很容易当成没修干净。原型视频结果页（`vSplit` / `vResLine`）本来就是同一套三段对比。做法：`BeforeAfterView` 从 `features/image_editor/presentation/widgets/` 上移到 `core/widgets/before_after_view.dart`（两页共用），修复成功后用现成的 `extractVideoFrame` 通道取**输出视频首帧**，与封面帧并排 —— 两者是同一时间点，像素级对比成立，**不需要引 `video_player`** |
| **首帧取不到不算失败** | 输出视频首帧可能读不出来（编解码器边界情况）。`resultFrame` 是 `Uint8List?`，为空时退回原来的封面帧 + 选框视图，`state.result` 仍然有效（结果卡、保存按钮、历史记录照常）。页面判据必须写成 `result != null && resultFrame != null` —— 只判 `result != null` 再 `resultFrame!` 会在真机上空指针崩溃。用例 `有结果但首帧没取到：退回封面帧，不崩也不空着` 做过变异验证：把判据改回只判 `result` → 当场红 |
| **首帧与 result 同生共死** | `copyWith` 里 `resultFrame` 跟着 `clearResult` 一起清。否则第二次修复时 `result` 已是新的、首帧还是上一次的 —— 对比图两侧来自两段不同素材，比「没有对比」更误导 |
| **竖屏装不装得下（360×800）** | 默认测试视口是 800×600（宽而矮），手机是 360×800（窄而高）。结果态底部同时挂着元信息 `Wrap` + 结果卡 + 保存按钮 + 选区提示 + 跟随开关 + 主按钮 —— 这一屏到底装不装得下，宽视口看不出来。新增用例把 `tester.view.physicalSize` 设成 1080×2400 / dpr 3，断言：两个主按钮的 rect 底部不超 800、高度不被压扁（>36）、分段控件仍是一行（高 <50）且右边界不超 360。**结果：全过 —— 视频结果页在真机比例下不溢出** |
| **fire-and-forget 的 IO 会越过测试生命周期** | 首帧抽帧第一版用 `unawaited(...)`，理由是「别挡结果卡」。代价：`tearDown` 删临时目录时文件还被占着 → `PathAccessException: 另一个程序正在使用此文件 (errno=32)`，而它报在**别的用例**名下（`成功：结果进状态` / `取消按钮：taskId 真的发给原生`），看着像业务逻辑坏了。同批日志里那条 `Cannot use the Ref of videoEditControllerProvider after it has been disposed` 才是真线索。修法：`await` + `.timeout(5s)`（抽帧卡死时宁可没有对比图），await 之后 `if (!ref.mounted) return;`。状态是先设的、再 await，结果卡照样先出来 —— **不存在「await 会挡 UI」这回事** |
| **历史缩略图：视频记录终于用「修好的那张」（2026-10-27）** | 图片页一直拿结果图做缩略图，视频页却用**修复前的封面帧**，理由写的是「省一次解码」。后果：历史列表里图片记录是干净的、视频记录还挂着水印，两条并列看着就像「视频那条没修干净」。首帧现在本来就要为对比分屏取一次，改用它等于白捡 —— `state.resultFrame ?? state.poster`（取不到才退回封面帧）。写历史的顺序也跟着从「先记录、后抽帧」改成「先抽帧、后记录」。用例 `历史缩略图用修好后的首帧` 让原生 mock 按来源回不同字节（修好首帧填 99、封面帧填 7），断言缩略图拿到的是 **99**；变异验证：改回 `state.poster` → 当场红 |
| **「涂抹 53 笔」（真机抓到）** | 一次横着涂水印，界面显示「**涂抹 53 笔**」。根因：`onPanUpdate` 每次都走 `addingStroke` 追加新段，而点列表是**同一个引用** —— 53 段笔迹指向同一份点，画面完全重叠（肉眼看不出），代价是计数全错、Mask 把同一条线重复画 53 遍。修法：`MaskDraft.replacingLastStroke()`，只在 `onPanStart` 用 `append: true` |
| **为什么这条 bug 单测抓不到** | `tester.drag` 是「按下 → 移动**一次** → 抬起」，真机是「按下 → 每帧一个移动 → 抬起」。`expect(strokes, hasLength(1))` 在单移动事件下天然绿。新用例必须 `startGesture` + 多次 `moveBy` 才能复现。**凡按事件次数累积状态的逻辑（笔迹、轨迹、防抖计数）都适用** |
| **笔迹必须存快照** | `MaskStroke.points` 若直接存 `_activePoints`（可变 List），「上一帧的 draft」和「这一帧的 draft」在 `listEquals` 下永远相等 → `_DraftPainter.shouldRepaint` 返回 false → **涂抹过程中看不到实时笔迹**。必须 `List<Offset>.of(pts)`。变异验证：改回共享引用，「同步进草稿的笔迹是快照」那条当场红 |
| **两个笔迹 bug 的真机复验（2026-10-24）** | ① **拖动中就看得见笔迹** —— 手机上没有「按住拖动过程中再截图」的现成手段，只能这么干：后台跑 `input swipe x1 y1 x2 y2 6000`（6 秒），`sleep 2.5` 后 `screencap`，此时手指还按着在移动。截图里橙色笔迹已画到一半，证明 `shouldRepaint` 真的重绘了。② 抬手后文案是「遮罩 **涂抹 1 笔**」而不是 53 笔 |
| **橡皮 / 拉角改大小（真机）** | 橡皮在已涂的笔迹中间擦一段 → 预览里那块**露出原图**（`BlendMode.clear`），文案仍是「涂抹 1 笔」（橡皮不计入笔数，与 `maskLabel` 只数 `!erase` 一致）。拉右下角 `(702,1002) → (880,1140)`，框从 366×244 变成 **488×371，左上角 (477,833) 一像素没动** —— 这就是「改大小」与「重画」的分界 |
| **拉角命中半径踩了两次** | 第一次按 `(480,836)` 拉角，结果**画了个新框**（366×244 → 268×200）。像素扫描发现框的真实右下角是 `(502,902)`，我按的点 y 偏了 66 px，正好在 22 dp（≈60 物理像素）命中半径之外。**别用眼睛从缩略图估角坐标** |
| **主题持久化（真机端到端）** | 设「深色」→ `adb shell am force-stop` → 从桌面重启 → 仍是深色（首页底色 `#14120E`）。验完**改回浅色**（`#F4EFE5`，实测 RGB 244,239,229）—— 不留自己的偏好在他手机上。README 原来那条「缺口 1」可以彻底划掉了 |
| **手势 → 草稿（真拖了一遍）** | 6 条用例用 `tester.drag` 真的在画布上划：默认矩形拖一次 = 产生选框且 `canRun` 变 true / 切涂抹后产生笔迹且**不留选框** / 切橡皮后 `erase == true` / 拉右下角改大小时**左上角不动** / 按在框中间拖 = 重拖新框 / 拖笔宽滑块真的改 `brushSize`。渲染对不对只是一半，手指划过去有没有产生东西只有拖一次才知道 |
| **改大小的判定为什么用显示坐标** | 角命中的半径是「22 逻辑像素」，必须在显示坐标里量。归一化坐标的距离会随长宽比变形 —— 横图上判定区会被压扁，用户按在角上却判不中 |
| **成果保护期** | `app_cache_test` +2：24 小时内的成果留着、3 天前的删掉、`stat` 失败按受保护处理（宁可多留不误删）。修的是「永久保护 → 临时目录只增不减，而『保留 N 个未导出的成果』在骗人」 |
| **超限时的孤儿缩略图** | `history_test` +2：加缩略图之后 `add()` 超过 50 条只丢记录、不删文件，`thumbs/` 会永久堆垃圾（「清理缓存」也看不到——它不在缓存目录）。现在被挤掉那条的缩略图一起删；没有 `thumbPath` 的老记录不调 `remove(null)` |
| **孤儿缩略图的第三条路径（同 id 覆盖）** | `history_test` +2：记录消失有三条路径 —— 清空 / 超 50 条挤掉 / **同 id 覆盖**，前两条接过、这条一直漏着。现在被覆盖的旧记录其缩略图也删；但**新旧指向同一文件时不能删**（那不是孤儿，删了就是把还在用的图删掉）。变异验证：循环改成只遍历 `dropped` → 「旧记录的缩略图要一起删」当场红 |
| **写盘失败时不留孤儿（视频侧）** | `video_edit_controller_test` +1：图片页 `_record` 的 catch 里早有「删掉刚生成的缩略图」，视频侧只打了日志 —— 又一次「同类逻辑只改一处」。变异验证：把 remove 短路掉 → 用例红（`Expected: length 1, Actual: []`） |
| **版本号单一来源** | `app_info_test +3` + `profile_page_test` 注入 `2.3.4/77`：三处引用全跟着变、读不到显示 `v?` 不编版本号 |
| **持久化链路（真机集成）** | `integration_test/persistence_test.dart` 4 条：修完 → `history.json` 落盘一条完整记录、缩略图真生成且 ≤320、清空连带删缩略图、主题写读、视频进相册（`content://media/...video...`）。⚠ **尚未在真机上跑过** —— 写的时候用户在用手机，测试包会抢前台 |
| **错误文案** | `processing_error_test +7`：有 detail 用 detail（用户才看得到「为什么」）、空白串回落通用话术、陌生 code 回落 `unknown`、detail 为空时也**不许**把系统英文漏到界面 |
| **错误文案真的到过界面吗** | 没有。`ProcessingException.message` 原来固定返回 `code.userMessage`，原生侧写的 `detail`（「打不开这个视频：可能是封装格式系统不支持…」）**一句都没显示过**。改 detail 优先后，`MediaBridge` 的 OOM 分支又在传 `e.message` → 用户会看到 `Failed to allocate a 46080012 byte allocation…`，已改为传 `null`、原文只进 `Log.e` |
| **图片页失败路径** | `image_edit_controller_test +4`：`loadSample()` 原来**没有 try**，asset 缺失就是一条 uncaught async error、界面毫无反应；`pickFromGallery()` 只捕 `PlatformException`，`readAsBytes` 失败同样静默。现在两条都给中文提示，英文只进 `debugPrint`（用例断言 `contains('示例图加载失败')` 且 `isNot(contains('Unable to load'))`） |
| **兜底 catch 也不许露英文** | 图片页 `run()` / `saveToGallery()`、视频页 `_adopt()` / `startRepair()` / `saveToGallery()` 的 `catch (error)` 原来都拼 `'…失败：$error'`。那里面是 `FileSystemException: Cannot create file, path = '/data/user/0/…/out_1.png' (OS Error: No space left on device, errno = 28)` 这种**英文 + 内部路径**。现在原文只进 `debugPrint`，界面给中文结论 + 出路。`image_picker` 的 `PlatformException.message` 同理（它是 `photo_access_denied` 这类枚举值，不是话术）。⚠ 仍有未覆盖：视频页 `_adopt()` 与 `startRepair()` 的**泛型** `catch`（要 probe 抛非 `PlatformException` 才进得去，mock 通道里做不到）、`saveToGallery()` 的泛型 catch、`pickFromGallery()` 两条分支 |
| **视频控制器（此前一条测试都没有）** | `video_edit_controller_test +12`。之前以为「进不去 `startRepair`，得先探测成功」—— **错了**：探测、修复、临时目录、示例视频**全是通道调用**，mock 掉就能跑。覆盖：探测成功 → 元数据/封面/可框选、容器不支持时原生中文原因原样上屏（且不含 `PlatformException`）、取消显示「已取消」而不是英文、OOM 给中文话术且能重试、成功时帧数/音轨来自返回、选区以**归一化坐标**下发（`left/top/right/bottom`）、取消真的把 `taskId` 发给原生且完成后归位、保存拿到 `content://` 后不再重存、写盘失败时删掉刚生成的缩略图 |
| **视频页 `pickFromGallery` 补了兜底** | 它原来**只有** `on PlatformException` 一条分支，`_adopt` 里其它失败会变成 uncaught async error：选完视频，界面毫无反应 |
| **`打开相册` 那条断言为什么要精确到分支** | 用例 mock 了 `plugins.flutter.io/image_picker` 抛 `PlatformException`。如果 mock 没生效，会落到 `on Object` 分支给「打不开这张图」—— 此时「不含 `photo_access_denied`」**照样通过**。所以断言写成 `contains('打不开相册')`（分支专属文案）。日志 `[image] 选择器失败：photo_access_denied` 证明 mock 真的命中了 |
| **容器格式的承诺** | `MediaExtractor` 没有 AVI 解析器（Stagefright 不提供）→ 首页副标题从「MP4 · MOV · AVI」改成「MP4 · MOV · MKV」，`VideoProbe` 把 `setDataSource` 的异常翻译成「转成 MP4（H.264 + AAC）再试」 |
| **历史缩略图** | `thumbnail_test +8`：大图压到 320 / 小图不放大（实测 `allowUpscaling` 默认 **true**，与直觉相反）/ 坏字节回 null / 同 id 覆盖 / 非法文件名不越界 / `clearAll` 真删；⚠ 真机列表里看到图**未验** |
| **历史详情页** | `history_detail_page_test +7`：类型显示中文、有图显示图 / 无图退图标、按钮文案不再承诺「处理原来那张」、写明历史不存素材 |
| **清空连带缩略图** | `history_page_test` 用 spy 断言「确认后确实调了 `clearAll()`」；真实删文件由 `thumbnail_test` 的普通 `test()` 覆盖 —— ⚠ `testWidgets` 是 FakeAsync，`await for (dir.list())` 不会被推进，硬断言文件消失会得到**假失败** |

### 帧耗时怎么量（Impeller 下 adb 侧全是 0）

`dumpsys gfxinfo <pkg>` 与 `dumpsys SurfaceFlinger --latency <layer>` 在本机拿到的都是
`Total frames rendered: 0` —— Impeller/Vulkan 这条路不往那两个统计口子写数据。
所以帧耗时只能由 Flutter 自己上报：`lib/core/diagnostics/frame_probe.dart`，挂在
`SchedulerBinding.addTimingsCallback` 上，只打 build 或 raster 超过 8 ms 的帧。

```bash
flutter build apk --debug --dart-define=WM_FRAME_PROBE=true    # 或 profile/release 同参数
adb logcat -c; <操作>; adb logcat -d -s flutter:I | grep FH
# [FH] slow frame #4 build=119.4ms raster=8.2ms
```

不带 `--dart-define` 时它是 `const false`，整块被摇掉，不进包。
判断体感问题的顺序也顺手定了：**先看是「点击那一帧」慢，还是「整个过渡」都慢** ——
前者是 JIT/点击特效，后者才是重建成本。
| **跟随开关（UI）** | widget test 断言「默认关、点一下变跟随、转码中收起」；真机**只截到转码中（开关按设计收起）**，开关展开态未截 —— 取证时手机被占用，没再抢 |
| **关键帧跟踪（PC 等价复现）** | 用 OpenCV 4.14.0 在 PC 上复现整条状态机（`D:/dev/vt/replay_motion.py`）。**保真度自证两条**：① 自检四组 0.044/0.291/0.141/0.389px、inliers 197 —— 与 2026-10-18 真机日志**逐位吻合**；② 旧版在 `sample.mp4` 上算出 43.98 / 23.82 / 39.89px，真机是 43.71 / 20.63 / 38.50px。收益：末帧对齐首帧的 MAE，pan 14.70→**1.52**、zoom 7.16→**2.93**、shake 10.11→**3.85** |
| **关键帧跟踪（真机）** | 2026-10-19 三个集成用例全绿：`video_probe +2` / `video_repair +2` / `motion +7`。八个运动量与 PC 复现逐位吻合（对比表见 §九），关键帧切换次数 2/7/2/2 完全一致 |
| **参数扫描** | `MAX_KEY_SHIFT=20` 比 `45` 差（pan MAE 2.48 vs 1.52）；`MAX_KEY_SPAN` 15~150 之间差异 < 0.2px，保留 60 |
| **能力边界（非刚性素材）** | `sample.mp4` 是花瓣绽放：f0–f149 相似 15.60 dB / 仿射 13.34 / 单应 11.83，**自由度越高越差**；且 15.60 ≈ 完全不对齐的 16.25 dB |
| **变焦素材** | `motion_zoom.mp4`（1.18 MB）真值 `scale=1.15`、`t=(-72,-40.5)`，PSNR/MAE 反查峰 MAE 4.86；真机 `scale=1.1497 t=(-71.62,-39.80)` |
| **抖动素材** | `motion_shake.mp4`（981 KB）真值 `angle=2.4862° / scale=1.0 / t=(59.36,-39.04)`；生成脚本自检 MAE=8.37；真机 `2.472° / 1.0001 / (59.37,-40.66)` |

冒烟测试刻意覆盖三条集成链路，任何一条依赖升级把它改坏都会立刻红：
`StatefulShellRoute`（切 Tab 不丢状态）、family provider（详情页按 id 取数）、
`themeMode`（Riverpod → MaterialApp）。

### ⚠ `assets/cafe-clean.png` 不是可信的基准图

本来想拿它算 PSNR/MAE，测出来的数却反常（修复后比修复前更差）。查下去发现两件事：

1. **它自己就带着同一行水印** —— 逐行最大亮度在 y884~889 处与原图几乎逐值相同（115/111/122/87）。
2. **它与原图的差异区根本不在文字上** —— 差异像素（>16）落在 `x[1002,1175] y[823,881]`，
   而 `y832~878` 那段是「原图偏暗、参考图偏亮」的一片区域，跟水印无关。

所以拿它当 ground truth 只会得出错误结论。真正的做法是**先定位水印**：
`cafe.jpg` 里那行 `© THE COZY CORNER CAFE` 亮像素（>90）实测只有 **6 px 高**，
落在 `x[1043,1189] y[884,889]`。

`tool/quality_compare.dart` 因此有两套口径：有可信基准图时算 MAE/PSNR；
没有时（`--reference none`）算**改动覆盖率**和**粗糙度比**（框内水平梯度 ÷ 框上方同尺寸对照带）——
涂抹过头的特征就是梯度显著低于四周，这个指标不需要基准图也能抓住。

### 已知缺口（没做，不是坏）

1. ~~**主题持久化的端到端没验完**~~ —— **2026-10-24 真机验完**：设深色 →
   `am force-stop` → 重启仍是深色。写盘走 `<应用支持目录>/theme_mode.txt`
   （枚举名，读回超时 1500 ms），见 §十「主题持久化（写到盘）」。本条已关闭。
2. **真机上的点击自动化不稳定**：本机 `adb` server 每条命令都会重起，注入的 `input tap`
   偶尔丢失（不是 App 的问题，日志里没有崩溃）。所以行为验证一律走 `integration_test`，
   **截图只做观感取证**，不当断言。
   另外 `input` 落在**前台那个 App** 上，而两条命令之间前台会变（10-22 两次点进了
   用户正在用的应用）。手写「先查前台再点」挡不住，改成用 `tool/safe_adb.sh`：

   ```bash
   bash tool/safe_adb.sh whoami              # 只查前台
   bash tool/safe_adb.sh tap 540 1200        # 前台不是本 App 就 exit 3，不点
   bash tool/safe_adb.sh swipe 400 900 400 400 300
   bash tool/safe_adb.sh launch              # 只允许从桌面启动
   ```

   查前台、判断、执行在**同一次进程调用**里完成，中间不再有「查完到点击之间前台被换掉」
   的窗口；执行完立刻回读前台，跑到别处会打警告并以 exit 5 结束。
3. **性能抖动**：同一段 5 秒片子，YUV 快路径后测到过 5025ms（29.9fps），
   后来同一条测试跑到过 14885ms（10.1fps），而 `outside_mae` 一直是 3.51 ——
   内容没变，速度变了。推测是整机降频（未验证）。**别拿单次数字当基线。**
4. **相似变换的适用边界没有被产品化**（见第九节「能力边界」）：`trackMotion` 的成立前提是
   **场景刚性 + 相机在动**。花瓣绽放这种非刚性素材上，相似/仿射/单应全都对不齐
   （15.60 / 13.34 / 11.83 dB，自由度越高越差）。所以 `trackMotion` 默认 `false` 不只是
   「没验」，更是**得让用户先判断自己拍的是哪一类**。
5. **关键帧跟踪已改完、PC 复现已验，但没真机验**：现在是「对关键帧估、四种条件触发换帧」，
   `dart analyze` / `flutter test +10` / `flutter build apk` 都过，PC 端等价复现也证明了
   收益与阈值（见第九节），**Android 侧的四组断言还没跑**。与原型里「选框四角实心/空心」
   的关键帧设计（关键帧 vs 追踪帧的视觉区分）也还没接。
6. **Android 10 以下的保存路径没做运行时授权**：`GallerySaver` 的 `EXTERNAL_CONTENT_URI` 分支
   需要 `WRITE_EXTERNAL_STORAGE` 的运行时授权（manifest 里连声明都没有），第一阶段只保证 Q+。
   现在 `copyInto` 会把 `SecurityException` 翻译成「这台手机是 Android 10 以下，保存到相册
   需要存储权限，当前版本还没支持」—— 用户至少知道是系统版本的问题，不是 App 坏了。
   ⚠ 那条分支**从没在 Android 10 以下真机验证过**（手头设备是 Android 12 / API 31）。
7. **修复算法是 OpenCV `INPAINT_TELEA` 单一档**：细文字效果够用，成片渐变背景会出现可见涂抹；
   技术方案里的 LaMa / 时序中值还没接。
8. **矩形框大了仍会把干净背景一起糊掉** —— 矩形 Mask 的固有缺陷，见 `crop-compare.png`。
   2026-10-22 起可以改用「涂抹」贴着水印形状走（`MaskDraft`），这是这条缺陷的正解；
   矩形保留作为粗粒度快捷方式。涂抹已验证：**10-22 真机涂掉右下角水印，815 ms，周围木纹无痕**；
   **10-24 真机验了橡皮挖除与拉四角改大小**。PC 侧真值基准也给过量化结论：
   涂抹 2px 半径 PSNR **28.98 dB**，框选最优只有 21.1 dB，差近 8 dB。
   试过两版自动细分都不行：梯度版（实测无效，第六节）、
   文字级 top-hat 版（8 个场景挂 5 个，第七节）。`refineMask` 默认关闭。
   这个缺口目前**没有便宜的解法**：要么让用户画紧一点，要么上 LaMa。

2026-10-22 把原型里 145 条中文文案全抽出来逐条对照，又清出三条「原型有、实现没有」：

9. **自动识别水印**：原型图片页有「识别到 2 处水印」+ 候选列表（图形徽标 / 文字署名 /
   置信 96% / 源图坐标）+ 勾选后一起修。**实现里一点都没有** —— 全靠手动画框。
   这是模型级工程（要检测器 + 置信度），不是界面补丁，所以本轮不做。
   在补上之前，界面不能出现「自动识别」之类的字眼（现在也没有）。
10. **视频只能整片处理**：原型有「起始 00:08 / 选区 22s / 结束 00:30」的时间轴选区，
    实现是整片逐帧修。参数里有 `maskPixels` 但没做时间范围。补这个要改
    `VideoRepairer` 的入参和 native 的帧范围，属于独立需求。
11. **我的页少两个开关**：原型有「同时保留原文件」「自动保存处理记录」，
    实现没有 —— 和当初删掉「默认修复质量」同一个理由：**不留点了没反应的装饰项**。
    没有就不显示，比显示一个假开关好。
12. **视频修完只能看「首帧对比」，不能播放**：~~原来只有数字 + 「保存到相册」~~，
    **2026-10-27 补上了**原型结果区那套 `修复前 / 对比 / 修复后` 三段
    （`core/widgets/before_after_view.dart`，图片页与视频页共用），对比图是
    **输出视频的首帧**——走现成的 `extractVideoFrame` 通道，和封面帧是同一时间点，
    所以像素级对比成立，不用引播放器。
    但这只是**一帧**：整段的运动效果、开「跟随画面」后水印有没有抖，仍然看不到。
    原型那个「预览」按钮还是没做，补它要引 `video_player`（当前 `pubspec.yaml` 里
    没有播放器依赖），是一次新依赖 + 原生构建，不是文案补丁。

---

## 十一、下一步

图片闭环、视频管线、镜头运动、旋转分支都已通，且在真机上有可复现的断言。按优先级：

1. ~~**真机验关键帧跟踪 + 三块运动素材**~~ —— **2026-10-19 已完成**，见 §九。
2. **三块运动素材已齐**（平移 / 变焦 / 抖动），覆盖了相似变换的三个自由度。
   缺的是「真透视」（拍倾斜屏幕），那是单应才能解决的 —— 属于能力边界，不是缺口。
   而且实测表明**单应在内容变形的素材上更差**，别为了「更通用」盲目升级到 8 自由度。
3. **inpaint 19.5 ms/帧**：已确认瓶颈是 **Mask 太粗**（整框是真实笔画的 7.9 倍），
   不是 TELEA 本身慢。降采样、最近邻、文字级检测三条路都已实测否掉
   （文字级在 8 个场景里挂 5 个，原因见 §七）。
   下一步按代价排序：**① 交互层让用户把框画紧**（零算法风险，框紧则洞小）；
   ② 视频用时间中值/方差分离静态水印（要求相机在动）；③ AI 分割。
   **不要再把「自动收紧 Mask」当成便宜的优化** —— 已经连否两版判据了。
4. **进度分段：要做就得改成两趟，别做假进度。**
   `ProcessingStage` 已经定义了 `analyzing / tracking / repairing / encoding / finalizing`，
   注释也写了「视频必须分开报，否则长任务看起来像卡死」（技术方案 §5.6）——
   这是产品要求，不是我加的。
   但现在的管线是**单趟流式**：解码一帧 → 推 Mask → inpaint → 编码，紧接着下一帧。
   `tracking` 与 `repairing` 在同一帧里先后发生，`encoding` 和它们交错。
   按固定比例切出来的四段只能是假的 —— 「正在追踪水印轨迹」的时候可能已经修到第 80 帧了。
   **假进度比没有进度更糟**：它让人误以为能按阶段估算剩余时间。

   诚实的做法是拆成两趟：第一趟只解码 + 灰度 + 跑一遍运动估计，把每帧的 2×3 变换存下来
   （150 帧 ≈ 7 KB）；第二趟拿着表直接修 + 编码。这样四段进度是真的，
   顺带还解耦了「跟踪必须在 inpaint 之前」这个隐式约束。
   成本是多解码一遍：实测 150 帧 `decode 241ms`，占 5025ms 的约 5%，可以接受。
   现在先只有真实帧进度（`逐帧修复 N / 约 M 帧`），不自欺。
5. **Mask 细分**：两条便宜的判据都已否掉（梯度版、top-hat 文字级）。
   剩下能走的是 LaMa，或者从时间维度入手（多帧中静态水印恒定、背景在动）。
   **别再重复造第三版「自动收紧」**，除非先造一套覆盖分布的测试集。
6. **验证前置条件**：真机跑集成测试前手机必须**解锁且没人在用**。锁屏状态下 Flutter 拿不到 vsync，
   `dumpsys gfxinfo` 会显示 `Total frames rendered: 0`，测试从头就挂住，且
   `screencap` 也被拦（拉回来是 0 字节）。手机在别人手里时更糟：注入的 `input tap`
   会落到前台那个 App 上（2026-10-18 实测把起点阅读器翻了 4 页）。

---

## 十二、修复质量：残留「鬼影」与「一块糊」的成因（v0.1.1）

用户反馈两条：图片修完选中区域残留马赛克、视频修完画面像被破坏。两件事**同源**，
根因都不在填充算法本身，而在**掩膜**与**边界合成**。

### 12.1 掩膜贴边 → TELEA 把水印抹进洞里

TELEA 是扩散型填充，以「洞的边界」为颜色来源往里推。边界只要沾到水印的抗锯齿、
或者 JPEG/H.264 的块噪声，笔画颜色就会被抹进洞里，形成一层**鬼影**。
在 `cafe.jpg`（真水印 = 底部 7px 高的细笔画）上实测，修后该区纹理 std 与原图 3.04 对比：

| 掩膜余量 | 修后字区 std | 接缝梯度 / 内部 |
|---|---|---|
| 2px（用户常见的「贴边拖」） | 15.57（鬼影最重） | 3.33x |
| 6px | 9.67（仍有鬼影） | 5.22x |
| 12~14px | **1.43（干净）** | **1.66x** |

→ 污染半径约 **10~14px**（JPEG 振铃 + 抗锯齿），H.264 宏块更大，视频按 16px 起步。
真机成品里也抓到过同款：`水印工坊_20261022_155903.png` 右下角留着「CAFE」的半个 `E`，
因为掩膜下边界切在字中间。

### 12.2 没有羽化 → 硬接缝

原来 `restored.copyTo(outRoi)` 直接把修复结果盖上去，掩膜边界是一条硬过渡。
实测接缝梯度是洞内部的 3.33 倍，人眼一看就是「贴了个补丁」。

### 12.3 视频「画面被破坏」= 洞太大，不是时序问题

把 10-28 那份成品（`水印工坊_20261028_032230.mp4`）与原素材逐帧比对：

- 真实掩膜 **353×365 @ (335,118)**，占 960×540 画面的 **24.9%**
- 用同算法同掩膜复现 → 与成品全图 **MAE 3.32**、掩膜外 1.57（纯编码噪声），模型可信
- 成品掩膜内帧间变化 **1.21** vs 同高参照条 **1.84 = 0.66x** → **填充区是稳的，不闪**
- 掩膜外 MAE 1.57 → **没有红蓝互换、没有整幅损坏**

所以「被破坏」的真实观感是：**矩形大洞上 TELEA 只沿四条对角线扩散，填出一个巨大的
X / 风筝形灰斑**。这块外扩救不了（实测擦除面积 24%→29%、接缝 1.17→1.24、填充纹理 53.46→53.28
基本没变），只能靠「别框这么大」或换纹理合成。

> 教训记一笔：一开始拿测试常量里的小掩膜（172×91）去测时序，测出 1.47x 就断言「逐帧闪烁」
> 并推荐 EMA。真实掩膜是它的 8 倍面积，且填充分明是稳的。**掩膜必须从成品反推**
> （原素材 vs 成品逐帧差，阈值 60 取 bbox），不能拿测试常量当现场。

### 12.4 v0.1.1 改了什么

| 文件 | 改动 |
|---|---|
| `ImageProcessor.kt` | `inpaintBgr` 增加 `growPx` / `featherPx`（默认 0 = 原行为）；新增 `dilateMask`、`blendSeam`；图片调用点 `grow = radius*2` 夹在 8–16、`feather = 3` |
| `VideoProcessor.kt` | 调用点 `growPx = 16`、`featherPx = 3`；`BIG_MASK_RATIO = 0.12` 打警告；结果 map 带 `maskRatio` |
| `video_repairer.dart` | 默认 `radius 4 → 6`；`VideoRepairResult.maskRatio` + `maskRatioTooBig` |
| `video_editor_page.dart` | 选区占比 > 12% 时结果页说明「这块只能填成一片平滑色块」 |

参数是量出来的，不是拍的：**r8/grow16 反而不如 r6/grow12**（字区 std 2.56 vs 1.05，
洞越大 TELEA 抽到的边界变化越多）。

### 12.5 验证

| 判据 | 改前 | 改后 |
|---|---|---|
| 接缝梯度 / 内部（PC 复现） | 3.33x | **1.01x** |
| 字区残留 std（原图 3.04） | 15.57 | **1.05** |
| 真机成品 `itest_cafe.png` | — | 接缝 **1.11x**、字区 std **0.96** |
| 视频集成测试 `outside_mae` | 3.51 | **3.81**（外扩 16px 让框外一圈被改，远低于 6 的阈值） |
| 视频集成测试 `inside_changed` | — | **91.2%** |

`outside_mae` 涨的那 0.3 是外扩的正常代价。**`maskPixels` 仍报外扩前的原始选区**
（外扩在 `inpaintBgr` 内部完成，`maskMat` 本身不动），所以「maskPixels 必须等于选区面积 ±5%」
那条断言继续成立 —— 别哪天把外扩结果写回 maskPixels。

### 12.6 还用不了的路（含一条实测否定）

- 大洞（>12% 画面）本质上没有信息可填。**试过两种「更聪明」的方案，都比现状差**：
  在真实掩膜 353×365 上，接缝梯度/内部 —— Telea r6 **1.40**、多尺度 1/4 **2.49**、
  多尺度 1/8 **3.29**、纹理搬运（SSD 选平移）**2.51**；纹理搬运视觉上是「贴进来半片花瓣」。
  原因是洞里是独一无二的主体，任何平移/缩放都找不到参照。
  → **不要再往这个方向投入**，只有 LaMa/MAT 这类学习型方法能真的复原主体。
- 细掩膜曾试 top-hat + Otsu 抠笔画，在 cafe 上命中真实水印 **0/10299 = 0.0%**，
  覆盖率 12% 全是噪点。要做必须换判据（局部背景色差 + 连通域长宽比）。


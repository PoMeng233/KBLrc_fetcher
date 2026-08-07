# KB歌词搜索（lyrics_fetcher）

多源歌词搜索下载工具，基于 **Flutter (Material 3)** 的 Windows 桌面应用。

支持歌词源：`lrclib`、`lyricsovh`、`kugou`（酷狗）、`kuwo`（酷我）、`netease`（网易云）、`qq`（QQ 音乐）

> 旧版 Python (customtkinter) 实现已归档到 [`legacy/`](legacy/)，历史版本见 git tag `v3.0.0-python`。

---

## 功能

- **多源并发搜索**：6 个歌词源同时搜索，结果流式出现，超时自动跳过
- **两种搜索方式**：
  - 手动输入歌曲名/歌手/专辑/时长
  - 选择音频文件 → 自动读取元数据（标题/歌手/专辑/时长）并搜索
- **批量处理**：选择文件夹或拖入多个文件，自动为每首歌保存最佳歌词（带进度与取消）
- **拖拽支持**：把音频文件或文件夹直接拖入窗口
- **歌词预览**：时间轴配色高亮、一键切换 自动/时间轴/纯文本、元数据/去时间戳/去翻译
- **智能保存**：
  - 原子写入（临时文件 + 重命名），UTF-8 BOM 编码
  - 冲突处理：覆盖 / 自动重命名（追加序号）/ 跳过
  - 输出目录：默认保存到歌曲所在目录，也可指定
  - 文件名格式：同名文件（`song.lrc`）或 `歌名 - 歌手.lrc`
- **Material 3**：浅色/深色/跟随系统主题、紧凑模式、卡片入场动画、骨架屏加载
- **设置持久化**：自动保存设置；首次运行自动导入旧版 `legacy/gui_settings.json`

---

## 环境要求

- Flutter 3.44+（含 Windows 桌面支持）
- Visual Studio 2022 Build Tools，需包含：
  - **使用 C++ 的桌面开发** 工作负载
  - **Windows 11 SDK** 组件（缺失时 `flutter build windows` 会报
    `Unable to find suitable Visual Studio toolchain`；可用 VS Installer 执行
    `setup.exe modify --installPath "<VS安装路径>" --add Microsoft.VisualStudio.Component.Windows11SDK.26100 --quiet --norestart` 补装）

## 运行（开发模式）

> ⚠️ 本项目路径 `G:\カラオケ\...` 含非 ASCII 字符，Flutter 的 Windows 构建链
> （cmd → MSBuild）会把路径转成 GBK 导致乱码报错（`锟斤拷` / 自定义生成退出码 255）。
> 已建立目录联接 `G:\kblrc_build` → 本项目，**所有构建/运行请走联接路径**：

```powershell
D:\flutter\flutter\bin\flutter run -d windows   # 在 G:\kblrc_build 下执行
```

## 构建发布版

```powershell
cd G:\kblrc_build
D:\flutter\flutter\bin\flutter build windows --release
# 产物在 build\windows\x64\runner\Release\（lyrics_fetcher.exe + data\app.so）
```

快速启动验证：`powershell -ExecutionPolicy Bypass -File tools\smoke_run.ps1`
（启动 6 秒无崩溃则输出 `RUNNING_OK`）

## 测试

```powershell
D:\flutter\flutter\bin\flutter test
```

## 目录结构

```
lib/
  core/                    # 与 UI 无关的核心逻辑
    models.dart            # 数据模型（查询/候选/选项/结果）
    lyrics_utils.dart      # 文本处理：清洗、评分、LRC 渲染、文件名
    lyrics_fetcher.dart    # 搜索协调器（并发、超时、流式回报）
    save_service.dart      # 保存服务（原子写入、冲突策略）
    settings.dart          # 设置加载/保存/迁移
    providers/             # 6 个歌词源实现 + HTTP 基础设施
  ui/
    app.dart               # MaterialApp + Material 3 主题
    search_page.dart       # 主界面（搜索/批量/拖拽/保存流程）
    widgets/               # 结果卡片、预览、设置面板等组件
test/
  core_test.dart           # 核心逻辑单元测试
  app_smoke_test.dart      # 应用启动冒烟测试
legacy/                    # 旧版 Python 实现（仅归档参考）
```

## 注意

所有代码使用 AI 生成，请以实际行为为准。

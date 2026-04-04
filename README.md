# Lyrics Fetcher

一个可本地运行的歌词抓取工具，支持：

- 图形界面（GUI）
- 命令行（CLI）
- 单文件处理
- 文件夹批量处理
- 手动输入歌曲名/歌手搜索
- 读取音频标签与文件名
- 保存为 `.lrc`
- 保存带时间轴歌词
- 保存不带时间轴歌词
- 可打包为 Windows 可执行文件发布

当前内置歌词源：

- LRCLIB
- Lyrics.ovh
- 酷狗音乐
- 酷我音乐
- 网易云音乐
- QQ 音乐

---

## 目录结构

```text
lrc/
├─ lyrics_fetcher.py          # 核心逻辑 + CLI
├─ lyrics_fetcher_gui.py      # GUI 图形界面
├─ fetch_lyrics.bat           # 启动 GUI
├─ fetch_lyrics_cli.bat       # 启动 CLI
├─ build_release.bat          # 打包发布脚本
├─ requirements.txt           # 依赖列表
└─ README.md                  # 使用说明
```

---

## 功能特性

### 1. 输入方式
支持以下三种输入方式：

- **单文件**
  - 选择一个音频文件，自动读取标签或文件名
- **文件夹批量**
  - 扫描文件夹中的音频文件并批量抓取歌词
- **手动输入**
  - 手动填写歌曲名、歌手、专辑、时长进行搜索

### 2. 歌词源选择与结果对比
现在 GUI 支持：

- 以可视化方式勾选歌词源，而不是手动输入逗号分隔字符串
- 搜索后展示来自不同歌词源的候选结果
- 按来源筛选结果
- 预览不同来源返回的歌词内容
- 手动选择某一条结果再保存

适合以下场景：

- 对比国内源与国外源的歌词质量
- 优先选择带时间轴歌词
- 某个来源匹配不准时，手动切换到其他来源结果

### 3. 歌词保存模式
支持以下模式：

- **自动优先时间轴**
  - 优先保存同步歌词
- **只保存时间轴歌词**
  - 只接受带时间戳的歌词
- **只保存无时间轴歌词**
  - 保存纯文本歌词

### 4. 时间戳处理
支持：

- 保留原始时间戳
- 去掉时间戳后再保存

这意味着你可以生成：

- 标准同步 `.lrc`
- 不带时间轴的纯文本 `.lrc`

### 5. 输出命名
支持：

- **跟随音频文件名**
- **歌曲名 - 歌手**

### 6. 批量处理能力
支持：

- 递归处理子目录
- 覆盖已有歌词
- 仅搜索不保存（预览模式）

---

## 环境要求

- Windows
- Python 3.10 或更高版本推荐
- 可联网访问歌词源

---

## 安装

在 `lrc` 目录中打开终端，执行：

```bash
pip install -r requirements.txt
```

如果你的系统有多个 Python 版本，建议使用：

```bash
py -3 -m pip install -r requirements.txt
```

---

## 依赖说明

`requirements.txt` 中主要依赖包括：

- `requests`
- `mutagen`
- `pyinstaller`

说明：

- `requests`：用于请求歌词接口
- `mutagen`：用于读取音频标签
- `pyinstaller`：用于打包发布

---

# GUI 使用说明

## 启动 GUI

双击：

```text
fetch_lyrics.bat
```

或在终端中执行：

```bash
py lyrics_fetcher_gui.py
```

---

## GUI 界面功能

### 输入方式
可以选择：

- **单文件**
- **文件夹批量**
- **手动输入**

### 歌词源
GUI 中已改为可视化多选，默认可选来源包括：

```text
lrclib,lyricsovh,kugou,kuwo,netease,qq
```

你可以：

- 全选全部来源
- 清空来源
- 一键切换为“仅国内源”
- 一键切换为“仅公开源”

搜索完成后，界面会展示不同来源返回的候选结果，你可以手动点选想保存的那一条。

### 歌词模式
可选：

- **自动优先时间轴**
- **只保存时间轴歌词**
- **只保存无时间轴歌词**

### 保存选项
可选：

- **去掉时间戳后保存**
- **写入元数据头**
- **覆盖已存在 LRC**
- **只搜索不保存**
- **文件夹模式递归子目录**

### 输出设置
可配置：

- 命名格式
  - 跟随音频文件名
  - 歌曲名 - 歌手
- 输出目录
  - 留空时默认保存到歌曲所在目录
  - 手动输入模式下留空则保存到程序当前目录

### 搜索结果与预览区域
新版 GUI 采用更现代的三栏式工作区布局，整体风格更接近圆角卡片和 Material You 式界面：

- 左侧：搜索参数、歌词源选择、保存选项
- 中间：不同歌词源返回的搜索结果列表
- 右侧：当前选中结果的歌词预览、来源信息和保存操作

你可以在结果区看到：

- 歌曲名
- 歌手
- 专辑
- 来源
- 是否有时间轴
- 是否有纯文本歌词
- 是否有翻译歌词
- 匹配分数

右侧预览区支持：

- 原始/最佳预览
- 去时间戳预览
- 翻译歌词预览
- 直接保存当前选中结果
- 复制歌词
- 打开输出目录

### 批量日志区域
批量处理页中保留运行日志，包括：

- 正在搜索的歌曲
- 当前歌词源返回结果数
- 自动选中的歌词来源
- 保存路径
- 错误信息
- 最终处理总结

---

## GUI 使用示例

### 示例 1：给单首歌抓歌词并手动挑选来源
1. 打开 GUI
2. 在“单曲搜索”页中选择“读取音频文件”或“手动输入”
3. 勾选多个歌词源
4. 点击“搜索歌词”
5. 在中间结果列表中对比不同来源
6. 选中满意的一条
7. 点击“保存选中结果”

### 示例 2：批量生成不带时间轴歌词
1. 打开 GUI
2. 切换到“批量处理”页
3. 选择音乐目录
4. 勾选“去掉时间戳后保存”
5. 或直接选择“仅纯文本歌词”
6. 点击“开始批量处理”

### 示例 3：手动输入搜索并对比国内外来源
1. 打开 GUI
2. 保持“手动输入”模式
3. 输入歌曲名和歌手
4. 同时勾选 `LRCLIB`、`Lyrics.ovh`、`网易云`、`QQ 音乐` 等来源
5. 点击“搜索歌词”
6. 对比不同来源结果后再保存

---

# CLI 使用说明

## 启动 CLI

双击：

```text
fetch_lyrics_cli.bat
```

或直接执行：

```bash
py lyrics_fetcher.py [参数]
```

---

## CLI 基本参数

### 输入参数

- `--file`
  - 指定单个音频文件
- `--dir`
  - 指定音乐目录批量处理
- `--title`
  - 手动输入歌曲名
- `--artist`
  - 手动输入歌手
- `--album`
  - 手动输入专辑
- `--duration`
  - 手动输入时长（秒）

### 歌词源参数

- `--providers`
  - 指定歌词源列表，例如：
  ```text
  lrclib,lyricsovh,kugou,kuwo,netease,qq
  ```

### 输出参数

- `--name-format`
  - `file`
  - `title-artist`
- `--out-dir`
  - 指定输出目录
- `--overwrite`
  - 覆盖已存在文件

### 模式参数

- `--lyric-mode auto`
  - 自动优先时间轴
- `--lyric-mode synced`
  - 仅保存带时间轴歌词
- `--lyric-mode plain`
  - 仅保存无时间轴歌词
- `--strip-timestamps`
  - 保存前去掉时间戳
- `--unsynced-only`
  - 等价于：
  ```text
  --lyric-mode plain --strip-timestamps
  ```
- `--dry-run`
  - 只搜索不保存
- `--non-recursive`
  - 文件夹模式下不递归子目录
- `--no-metadata`
  - 不写入 `[ti] [ar] [al] [by]`

### 其他参数

- `--version`
  - 显示版本信息

---

## CLI 示例

### 1. 单文件抓歌词
```bash
py lyrics_fetcher.py --file "D:\Music\Aimer - Brave Shine.flac"
```

### 2. 批量抓歌词
```bash
py lyrics_fetcher.py --dir "D:\Music"
```

### 3. 批量处理且不递归
```bash
py lyrics_fetcher.py --dir "D:\Music" --non-recursive
```

### 4. 手动输入歌曲名和歌手
```bash
py lyrics_fetcher.py --title "Brave Shine" --artist "Aimer"
```

### 5. 保存为“歌曲名 - 歌手.lrc”
```bash
py lyrics_fetcher.py --file "D:\Music\Aimer - Brave Shine.flac" --name-format title-artist
```

### 6. 保存不带时间轴歌词
```bash
py lyrics_fetcher.py --file "D:\Music\Aimer - Brave Shine.flac" --lyric-mode plain
```

### 7. 去掉时间戳后保存
```bash
py lyrics_fetcher.py --file "D:\Music\Aimer - Brave Shine.flac" --strip-timestamps
```

### 8. 强制生成无时间轴歌词
```bash
py lyrics_fetcher.py --file "D:\Music\Aimer - Brave Shine.flac" --unsynced-only
```

### 9. 不写入头信息
```bash
py lyrics_fetcher.py --file "D:\Music\Aimer - Brave Shine.flac" --no-metadata
```

### 10. 只预览搜索结果，不保存
```bash
py lyrics_fetcher.py --title "Brave Shine" --artist "Aimer" --dry-run
```

---

# 不带时间轴歌词说明

这个项目支持两种“无时间轴歌词”生成方式。

## 方式 1：直接保存纯文本歌词
使用：

```bash
--lyric-mode plain
```

适合本身有纯文本歌词源的情况。

## 方式 2：从同步歌词中去掉时间戳
使用：

```bash
--strip-timestamps
```

适合歌词源只提供带时间轴歌词，但你想保存成纯文本 `.lrc` 的情况。

## 推荐组合
如果你明确只要不带时间轴歌词，推荐：

```bash
--unsynced-only
```

GUI 中则可以：

- 选择“只保存无时间轴歌词”
- 或勾选“去掉时间戳后保存”

---

# 输出文件说明

## 默认保存位置
- 单文件模式：保存到音频文件所在目录
- 文件夹模式：默认保存到每首歌所在目录
- 手动输入模式：如果未指定输出目录，则保存到当前程序目录

## 编码
输出文件采用：

```text
UTF-8 with BOM
```

这样对大部分 Windows 播放器兼容性较好。

---

# 支持的音频格式

当前支持检测这些音频扩展名：

- `.mp3`
- `.flac`
- `.m4a`
- `.aac`
- `.ogg`
- `.opus`
- `.wav`
- `.wma`
- `.ape`
- `.mp4`

---

# 命名规则

## 跟随音频文件名
例如：

```text
Aimer - Brave Shine.flac
```

输出：

```text
Aimer - Brave Shine.lrc
```

## 歌曲名 - 歌手
例如：

```text
Brave Shine - Aimer.lrc
```

---

# 打包发布

这个项目已经包含 Windows 打包脚本：

```text
build_release.bat
```

## 打包前准备
确保已经安装依赖：

```bash
py -3 -m pip install -r requirements.txt
```

## 执行打包
双击：

```text
build_release.bat
```

或在终端执行：

```bash
build_release.bat
```

## 打包脚本会做什么
它会自动：

1. 检查 Python 环境
2. 安装/更新依赖
3. 安装/更新 `PyInstaller`
4. 清理旧构建文件
5. 构建 GUI 单文件 EXE
6. 生成发布目录
7. 复制：
   - `LyricsFetcher.exe`
   - `README.md`
   - 启动脚本
8. 生成 ZIP 压缩包

## 打包后产物
通常会生成：

```text
dist\LyricsFetcher.exe
release\LyricsFetcher\
release\LyricsFetcher.zip
```

---

# 发布建议

如果你要发布给别人使用，建议把以下文件一起提供：

- `LyricsFetcher.exe`
- `README.md`
- `run_gui.bat`
- `fetch_lyrics.bat`

---

# 新版 GUI 说明

## 新界面特点

新版 GUI 做了较大幅度升级，重点包括：

- 更现代化的圆角卡片式界面
- 更清晰的三栏布局
- 更直观的歌词源多选
- 更适合人工挑选歌词结果的交互流程
- 保留批量模式，同时增强单曲搜索体验

## 单曲搜索页

单曲搜索页适合：

- 只处理一首歌
- 对比多个歌词源
- 手动确认某条搜索结果再保存
- 预览时间轴歌词、纯文本歌词和翻译歌词

## 批量处理页

批量处理页适合：

- 一次处理整个音乐文件夹
- 沿用你在单曲搜索页中配置好的歌词源
- 自动选择最优候选并批量保存
- 查看完整批处理日志

## 新增歌词源说明

### 国外来源
- `LRCLIB`
  - 公开歌词库
  - 对英文、日文等国际歌曲支持较好
  - 可返回带时间轴歌词和纯文本歌词
- `Lyrics.ovh`
  - 适合作为公开国际来源补充
  - 主要返回纯文本歌词

### 国内来源
- `酷狗音乐`
  - 常见中文歌曲时间轴歌词来源
- `酷我音乐`
  - 新增的国内歌词源
  - 可作为酷狗、网易云、QQ 之外的补充来源
- `网易云音乐`
  - 常见中文、日文歌曲歌词来源
- `QQ 音乐`
  - 对流行歌曲与部分翻译歌词支持较好

## 兼容性说明

由于不同歌词源接口稳定性会随时间变化，实际可用性可能受以下因素影响：

- 网络环境
- 地区限制
- 平台接口调整
- 某首歌曲本身是否存在时间轴歌词

因此建议在 GUI 中同时勾选多个来源，以获得更高的成功率和更好的可选结果。

如果你要发布给别人使用，建议把以下文件一起提供：

- `LyricsFetcher.exe`
- `README.md`
- `run_gui.bat`
- `fetch_lyrics.bat`
- `fetch_lyrics_cli.bat`

如果是源码发布，建议保留整个 `lrc` 目录。

---

# 已知限制

1. 部分歌词源属于非官方公开接口，后续如果平台修改接口，可能需要更新代码
2. 某些歌曲可能没有时间轴歌词，只能拿到纯文本歌词
3. 某些冷门歌曲在不同平台匹配结果可能不一致
4. 网络环境会影响搜索成功率
5. 批量处理时，如果目标文件已存在且未启用覆盖，会跳过保存

---

# 常见问题

## 1. 为什么搜不到歌词？
可能原因：

- 歌曲名或歌手名识别不准确
- 标签信息错误
- 文件名格式不规范
- 当前歌词源没有该歌曲
- 网络请求失败

建议：

- 改用手动输入模式
- 补充歌手名、专辑名、时长
- 调整歌词源顺序

## 2. 为什么生成的是纯文本，不是同步歌词？
可能是因为：

- 当前来源没有时间轴歌词
- 你启用了：
  - `--lyric-mode plain`
  - `--strip-timestamps`
  - `--unsynced-only`

## 3. 为什么文件没有保存？
请检查：

- 是否启用了 `--dry-run`
- 是否文件已存在且未开启覆盖
- 输出目录是否可写
- 是否有权限问题

## 4. GUI 打不开怎么办？
请先确认：

- 已安装 Python
- 已安装依赖
- 终端中运行 `py lyrics_fetcher_gui.py` 是否报错

如果你是运行打包后的 EXE，则检查：

- 是否被杀毒软件拦截
- 是否缺少打包依赖
- 是否构建成功

---

# 开发说明

## 核心脚本
`lyrics_fetcher.py` 负责：

- 搜索多个歌词源
- 评分和选择最佳结果
- 读取音频标签
- 批量扫描目录
- 渲染并保存 `.lrc`
- 提供 CLI 能力

## GUI 脚本
`lyrics_fetcher_gui.py` 负责：

- 图形界面
- 参数收集
- 后台线程执行任务
- 日志显示
- 调用核心脚本 API

---

# 许可证与使用提示

请仅将本项目用于个人学习、研究和本地整理歌词用途。  
不同歌词平台有各自的版权与服务条款，使用时请自行遵守相关规定。

---

# 快速开始

## GUI
```bash
pip install -r requirements.txt
py lyrics_fetcher_gui.py
```

## CLI
```bash
pip install -r requirements.txt
py lyrics_fetcher.py --file "D:\Music\example.flac"
```

## 批量生成无时间轴歌词
```bash
py lyrics_fetcher.py --dir "D:\Music" --unsynced-only
```

---

# 更新建议

未来可以继续扩展：

- 更多歌词源
- 歌词预览窗口
- 手动选择候选结果
- 自动去除翻译行
- 自动检测日文/中文歌词
- 导出日志文件
- 多线程批量下载优化

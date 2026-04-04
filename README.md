# Lyrics Fetcher

一个简洁的多源歌词搜索工具（GUI + CLI）。

支持歌词源：`lrclib`、`lyricsovh`、`kugou`、`kuwo`、`netease`、`qq`

---

## 1) 安装

在项目目录执行：

```/dev/null/path.sh#L1-1
pip install -r requirements.txt
```

---

## 2) 启动 GUI（推荐）

Windows：

```/dev/null/path.bat#L1-1
fetch_lyrics.bat
```

或直接：

```/dev/null/path.sh#L1-1
python lyrics_fetcher_gui.py
```

---

## 3) GUI 快速使用

1. 选择歌词源（左侧复选框）
2. 输入歌曲名/歌手，或点击 **“浏览歌曲文件并搜索”**
3. 点击 **“搜索歌词”**
4. 在右侧结果卡片中：
   - 单击：选中结果
   - 双击：打开歌词预览
5. 点击 **“保存选中结果”** 导出 `.lrc`

> 支持拖拽音频文件到窗口：拖入时会显示居中提示“拖入到此处搜索歌词”，放下后自动识别并搜索。

---

## 4) CLI 用法（可选）

```/dev/null/path.sh#L1-1
python lyrics_fetcher.py --help
```

示例：

```/dev/null/path.sh#L1-1
python lyrics_fetcher.py --title "夜に駆ける" --artist "YOASOBI"
```

---

## 5) 常见问题

- **拖拽无效**：先确认已安装依赖；仍不可用时可使用“浏览歌曲文件并搜索”按钮。
- **没有结果**：尝试勾选更多歌词源，或补充歌手信息提高匹配率。
- **无法保存**：检查输出目录权限，或切换到可写目录。

---

## 6) 依赖

- `requests`
- `mutagen`
- `customtkinter`
- `tkinterdnd2`

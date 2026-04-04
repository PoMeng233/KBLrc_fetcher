# KB歌词搜索（KBlrc_fetcher）

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

> 支持拖拽音频文件到窗口

---

## 4) CLI 用法（可选）

```/dev/null/path.sh#L1-1
python lyrics_fetcher.py --help
```

示例：

```/dev/null/path.sh#L1-1
python lyrics_fetcher.py --title "夜に駆ける" --artist "YOASOBI"
```



## 5) 依赖

- `requests`
- `mutagen`
- `customtkinter`
- `tkinterdnd2`

## 注意：所有代码使用AI生成

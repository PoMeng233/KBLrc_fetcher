#!/usr/bin/env python3
from __future__ import annotations

import os
import queue
import threading
import traceback
from pathlib import Path
from tkinter import filedialog, messagebox
from typing import Optional

import customtkinter as ctk

import lyrics_fetcher as core


class LyricsFetcherGUI(ctk.CTk):
    def __init__(self) -> None:
        super().__init__()

        ctk.set_appearance_mode("system")
        ctk.set_default_color_theme("blue")

        self.title("Lyrics Fetcher")
        self.geometry("1460x920")
        self.minsize(1220, 760)

        self.log_queue: queue.Queue[str] = queue.Queue()
        self.ui_queue: queue.Queue[tuple[str, object]] = queue.Queue()
        self.search_thread: Optional[threading.Thread] = None
        self.batch_thread: Optional[threading.Thread] = None

        self.current_query: Optional[core.TrackQuery] = None
        self.current_bundle = None
        self.current_candidates: list[core.LyricsCandidate] = []
        self.filtered_candidates: list[core.LyricsCandidate] = []
        self.selected_candidate: Optional[core.LyricsCandidate] = None
        self.result_cards: list[ctk.CTkFrame] = []

        self._init_vars()
        self._build_ui()

        self.after(120, self._drain_queues)

    def _init_vars(self) -> None:
        self.input_mode_var = ctk.StringVar(value="手动输入")

        self.single_file_var = ctk.StringVar()
        self.batch_dir_var = ctk.StringVar()

        self.title_var = ctk.StringVar()
        self.artist_var = ctk.StringVar()
        self.album_var = ctk.StringVar()
        self.duration_var = ctk.StringVar()

        self.out_dir_var = ctk.StringVar()

        self.name_format_var = ctk.StringVar(value="file")
        self.lyric_mode_var = ctk.StringVar(value="auto")
        self.include_metadata_var = ctk.BooleanVar(value=True)
        self.strip_timestamps_var = ctk.BooleanVar(value=False)
        self.overwrite_var = ctk.BooleanVar(value=False)
        self.recursive_var = ctk.BooleanVar(value=True)
        self.dry_run_var = ctk.BooleanVar(value=False)

        self.source_filter_var = ctk.StringVar(value="all")

        self.provider_vars: dict[str, ctk.BooleanVar] = {}
        for provider in self._provider_order():
            self.provider_vars[provider] = ctk.BooleanVar(value=True)

        self.search_status_var = ctk.StringVar(value="准备就绪")
        self.preview_title_var = ctk.StringVar(value="未选择结果")
        self.preview_meta_var = ctk.StringVar(value="请先执行搜索")
        self.preview_source_var = ctk.StringVar(value="来源：-")
        self.preview_stats_var = ctk.StringVar(value="时间轴：-   纯文本：-   翻译：-")
        self.batch_status_var = ctk.StringVar(value="等待批量任务")
        self.result_summary_var = ctk.StringVar(value="还没有搜索结果")

    def _provider_order(self) -> list[str]:
        preferred = [
            "lrclib",
            "lyricsovh",
            "kugou",
            "kuwo",
            "netease",
            "qq",
        ]
        if hasattr(core, "PROVIDER_FUNCS"):
            existing = list(core.PROVIDER_FUNCS.keys())
            merged = []
            for item in preferred + existing:
                if item not in merged:
                    merged.append(item)
            return merged
        return preferred

    def _provider_label(self, provider: str) -> str:
        labels = {
            "lrclib": "LRCLIB",
            "lyricsovh": "Lyrics.ovh",
            "kugou": "酷狗",
            "kuwo": "酷我",
            "netease": "网易云",
            "qq": "QQ 音乐",
        }
        return labels.get(provider, provider)

    def _build_ui(self) -> None:
        self.configure(fg_color=("#f5f7fb", "#0e1621"))

        self.grid_rowconfigure(1, weight=1)
        self.grid_columnconfigure(0, weight=1)

        self._build_top_bar()
        self._build_main_tabs()
        self._build_status_bar()

    def _build_top_bar(self) -> None:
        top = ctk.CTkFrame(
            self,
            corner_radius=0,
            fg_color=("#eaf0ff", "#111a27"),
            height=88,
        )
        top.grid(row=0, column=0, sticky="ew")
        top.grid_columnconfigure(0, weight=1)

        title_wrap = ctk.CTkFrame(top, fg_color="transparent")
        title_wrap.grid(row=0, column=0, sticky="w", padx=24, pady=18)

        ctk.CTkLabel(
            title_wrap,
            text="Lyrics Fetcher",
            font=ctk.CTkFont(size=30, weight="bold"),
        ).pack(anchor="w")

        ctk.CTkLabel(
            title_wrap,
            text="现代化歌词搜索、来源选择、结果预览与批量处理",
            text_color=("#5b6475", "#98a7be"),
            font=ctk.CTkFont(size=14),
        ).pack(anchor="w", pady=(4, 0))

    def _build_main_tabs(self) -> None:
        tabs = ctk.CTkTabview(
            self,
            corner_radius=22,
            segmented_button_selected_color=("#2f6df6", "#4d87ff"),
            segmented_button_selected_hover_color=("#245be0", "#5b95ff"),
        )
        tabs.grid(row=1, column=0, sticky="nsew", padx=18, pady=(16, 10))

        tabs.add("单曲搜索")
        tabs.add("批量处理")

        self.search_tab = tabs.tab("单曲搜索")
        self.batch_tab = tabs.tab("批量处理")

        self._build_search_tab()
        self._build_batch_tab()

    def _build_search_tab(self) -> None:
        tab = self.search_tab
        tab.grid_rowconfigure(0, weight=1)
        tab.grid_columnconfigure(0, weight=0, minsize=360)
        tab.grid_columnconfigure(1, weight=1, minsize=430)
        tab.grid_columnconfigure(2, weight=1, minsize=420)

        self._build_search_left_panel(tab)
        self._build_results_panel(tab)
        self._build_preview_panel(tab)

    def _build_search_left_panel(self, parent) -> None:
        panel = ctk.CTkFrame(parent, corner_radius=24)
        panel.grid(row=0, column=0, sticky="nsew", padx=(10, 10), pady=10)

        panel.grid_rowconfigure(6, weight=1)
        panel.grid_columnconfigure(0, weight=1)

        hero = ctk.CTkFrame(panel, corner_radius=22, fg_color=("#dde8ff", "#162235"))
        hero.grid(row=0, column=0, sticky="ew", padx=16, pady=(16, 12))
        hero.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            hero,
            text="搜索参数",
            font=ctk.CTkFont(size=22, weight="bold"),
        ).grid(row=0, column=0, sticky="w", padx=18, pady=(16, 4))

        ctk.CTkLabel(
            hero,
            text="支持手动输入、单文件读取标签，以及多歌词源并行搜索",
            text_color=("#546179", "#aab8cb"),
            justify="left",
            wraplength=300,
        ).grid(row=1, column=0, sticky="w", padx=18, pady=(0, 16))

        mode_frame = self._section(panel, "输入方式")
        mode_frame.grid(row=1, column=0, sticky="ew", padx=16, pady=(0, 12))
        self._build_mode_selector(mode_frame)

        query_frame = self._section(panel, "查询内容")
        query_frame.grid(row=2, column=0, sticky="ew", padx=16, pady=(0, 12))
        self._build_query_inputs(query_frame)

        provider_frame = self._section(panel, "歌词源")
        provider_frame.grid(row=3, column=0, sticky="ew", padx=16, pady=(0, 12))
        self._build_provider_selector(provider_frame)

        options_frame = self._section(panel, "保存与歌词选项")
        options_frame.grid(row=4, column=0, sticky="ew", padx=16, pady=(0, 12))
        self._build_save_options(options_frame)

        action_frame = ctk.CTkFrame(panel, fg_color="transparent")
        action_frame.grid(row=5, column=0, sticky="ew", padx=16, pady=(0, 12))
        action_frame.grid_columnconfigure(0, weight=1)
        action_frame.grid_columnconfigure(1, weight=1)

        self.search_button = ctk.CTkButton(
            action_frame,
            text="搜索歌词",
            height=46,
            corner_radius=16,
            command=self._start_search,
        )
        self.search_button.grid(row=0, column=0, sticky="ew", padx=(0, 6))

        ctk.CTkButton(
            action_frame,
            text="清空结果",
            height=46,
            corner_radius=16,
            fg_color=("#e7ebf4", "#1b2738"),
            text_color=("#1e2a3b", "#edf3ff"),
            hover_color=("#dbe2ef", "#223145"),
            command=self._clear_search_results,
        ).grid(row=0, column=1, sticky="ew", padx=(6, 0))

        tip_frame = ctk.CTkFrame(
            panel, corner_radius=18, fg_color=("#f3f6fb", "#121d2b")
        )
        tip_frame.grid(row=6, column=0, sticky="nsew", padx=16, pady=(0, 16))
        tip_frame.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            tip_frame,
            text="使用建议",
            font=ctk.CTkFont(size=16, weight="bold"),
        ).grid(row=0, column=0, sticky="w", padx=14, pady=(12, 4))

        tips = [
            "优先勾选多个来源，这样便于对比不同歌词源结果。",
            "手动输入模式最适合做单曲精确搜索。",
            "如果你要纯文本歌词，可选择“仅纯文本”或勾选“去掉时间戳”。",
            "搜索完成后在中间选择一条结果，右侧可直接预览并保存。",
        ]
        for idx, tip in enumerate(tips, start=1):
            ctk.CTkLabel(
                tip_frame,
                text=f"• {tip}",
                justify="left",
                anchor="w",
                wraplength=305,
                text_color=("#5f6c80", "#9dafc7"),
            ).grid(row=idx, column=0, sticky="w", padx=14, pady=2)

    def _build_mode_selector(self, parent) -> None:
        wrap = ctk.CTkFrame(parent, fg_color="transparent")
        wrap.pack(fill="x")

        ctk.CTkSegmentedButton(
            wrap,
            values=["手动输入", "读取音频文件"],
            variable=self.input_mode_var,
            command=lambda _: self._update_input_mode(),
            corner_radius=14,
            height=34,
        ).pack(fill="x", pady=(0, 12))

        self.file_row = ctk.CTkFrame(wrap, fg_color="transparent")
        self.file_row.pack(fill="x", pady=(0, 10))
        self.file_entry = ctk.CTkEntry(
            self.file_row,
            textvariable=self.single_file_var,
            height=40,
            corner_radius=14,
            placeholder_text="选择音频文件以读取标签",
        )
        self.file_entry.pack(side="left", fill="x", expand=True, padx=(0, 8))
        ctk.CTkButton(
            self.file_row,
            text="浏览",
            width=84,
            height=40,
            corner_radius=14,
            command=self._browse_single_file,
        ).pack(side="left")

    def _build_query_inputs(self, parent) -> None:
        self.query_wrap = ctk.CTkFrame(parent, fg_color="transparent")
        self.query_wrap.pack(fill="x")

        self.title_entry = self._labeled_entry(
            self.query_wrap, "歌曲名", self.title_var
        )
        self.artist_entry = self._labeled_entry(
            self.query_wrap, "歌手", self.artist_var
        )
        self.album_entry = self._labeled_entry(self.query_wrap, "专辑", self.album_var)
        self.duration_entry = self._labeled_entry(
            self.query_wrap,
            "时长（秒）",
            self.duration_var,
        )

        self._update_input_mode()

    def _build_provider_selector(self, parent) -> None:
        top = ctk.CTkFrame(parent, fg_color="transparent")
        top.pack(fill="x", pady=(0, 10))

        ctk.CTkButton(
            top,
            text="全选",
            width=76,
            height=34,
            corner_radius=12,
            fg_color=("#e6ecfb", "#22324a"),
            text_color=("#1d2b3b", "#edf3ff"),
            hover_color=("#d8e1f7", "#2a3c56"),
            command=self._select_all_providers,
        ).pack(side="left", padx=(0, 8))

        ctk.CTkButton(
            top,
            text="清空",
            width=76,
            height=34,
            corner_radius=12,
            fg_color=("#e6ecfb", "#22324a"),
            text_color=("#1d2b3b", "#edf3ff"),
            hover_color=("#d8e1f7", "#2a3c56"),
            command=self._clear_all_providers,
        ).pack(side="left", padx=(0, 8))

        ctk.CTkButton(
            top,
            text="仅国内源",
            width=94,
            height=34,
            corner_radius=12,
            fg_color=("#e6ecfb", "#22324a"),
            text_color=("#1d2b3b", "#edf3ff"),
            hover_color=("#d8e1f7", "#2a3c56"),
            command=lambda: self._apply_provider_preset(
                {"kugou", "kuwo", "netease", "qq"}
            ),
        ).pack(side="left", padx=(0, 8))

        ctk.CTkButton(
            top,
            text="仅公开源",
            width=94,
            height=34,
            corner_radius=12,
            fg_color=("#e6ecfb", "#22324a"),
            text_color=("#1d2b3b", "#edf3ff"),
            hover_color=("#d8e1f7", "#2a3c56"),
            command=lambda: self._apply_provider_preset({"lrclib", "lyricsovh"}),
        ).pack(side="left")

        grid = ctk.CTkFrame(parent, fg_color="transparent")
        grid.pack(fill="x")

        providers = self._provider_order()
        for idx, provider in enumerate(providers):
            row = idx // 2
            col = idx % 2
            cb = ctk.CTkCheckBox(
                grid,
                text=self._provider_label(provider),
                variable=self.provider_vars[provider],
                corner_radius=8,
            )
            cb.grid(row=row, column=col, sticky="w", padx=(0, 22), pady=6)

    def _build_save_options(self, parent) -> None:
        self._labeled_option_menu(
            parent,
            "歌词模式",
            self.lyric_mode_var,
            ["auto", "synced", "plain"],
            label_map={
                "auto": "自动优先时间轴",
                "synced": "仅时间轴歌词",
                "plain": "仅纯文本歌词",
            },
        )

        self._labeled_option_menu(
            parent,
            "命名格式",
            self.name_format_var,
            ["file", "title-artist"],
            label_map={
                "file": "跟随音频文件名",
                "title-artist": "歌曲名 - 歌手",
            },
        )

        out_wrap = ctk.CTkFrame(parent, fg_color="transparent")
        out_wrap.pack(fill="x", pady=(10, 6))
        ctk.CTkLabel(
            out_wrap,
            text="输出目录",
            font=ctk.CTkFont(size=13, weight="bold"),
        ).pack(anchor="w", pady=(0, 6))

        row = ctk.CTkFrame(out_wrap, fg_color="transparent")
        row.pack(fill="x")
        ctk.CTkEntry(
            row,
            textvariable=self.out_dir_var,
            height=38,
            corner_radius=12,
            placeholder_text="留空则使用默认保存位置",
        ).pack(side="left", fill="x", expand=True, padx=(0, 8))
        ctk.CTkButton(
            row,
            text="浏览",
            width=82,
            height=38,
            corner_radius=12,
            command=self._browse_out_dir,
        ).pack(side="left")

        flags = ctk.CTkFrame(parent, fg_color="transparent")
        flags.pack(fill="x", pady=(10, 0))

        ctk.CTkCheckBox(
            flags,
            text="写入元数据头",
            variable=self.include_metadata_var,
        ).grid(row=0, column=0, sticky="w", padx=(0, 16), pady=5)

        ctk.CTkCheckBox(
            flags,
            text="去掉时间戳后保存",
            variable=self.strip_timestamps_var,
        ).grid(row=0, column=1, sticky="w", padx=(0, 16), pady=5)

        ctk.CTkCheckBox(
            flags,
            text="覆盖已存在 LRC",
            variable=self.overwrite_var,
        ).grid(row=1, column=0, sticky="w", padx=(0, 16), pady=5)

        ctk.CTkCheckBox(
            flags,
            text="仅搜索不保存（批量）",
            variable=self.dry_run_var,
        ).grid(row=1, column=1, sticky="w", padx=(0, 16), pady=5)

    def _build_results_panel(self, parent) -> None:
        panel = ctk.CTkFrame(parent, corner_radius=24)
        panel.grid(row=0, column=1, sticky="nsew", padx=(0, 10), pady=10)
        panel.grid_rowconfigure(2, weight=1)
        panel.grid_columnconfigure(0, weight=1)

        header = ctk.CTkFrame(panel, fg_color="transparent")
        header.grid(row=0, column=0, sticky="ew", padx=16, pady=(16, 8))
        header.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            header,
            text="搜索结果",
            font=ctk.CTkFont(size=24, weight="bold"),
        ).grid(row=0, column=0, sticky="w")

        ctk.CTkLabel(
            header,
            textvariable=self.result_summary_var,
            text_color=("#607089", "#a7b8cf"),
        ).grid(row=1, column=0, sticky="w", pady=(4, 0))

        filter_bar = ctk.CTkFrame(
            panel, corner_radius=18, fg_color=("#f3f6fb", "#121d2b")
        )
        filter_bar.grid(row=1, column=0, sticky="ew", padx=16, pady=(0, 8))
        filter_bar.grid_columnconfigure(1, weight=1)

        ctk.CTkLabel(
            filter_bar,
            text="来源筛选",
            font=ctk.CTkFont(size=14, weight="bold"),
        ).grid(row=0, column=0, sticky="w", padx=14, pady=12)

        self.source_filter_menu = ctk.CTkOptionMenu(
            filter_bar,
            variable=self.source_filter_var,
            values=["all"],
            height=36,
            corner_radius=12,
            command=lambda _: self._refresh_result_cards(),
        )
        self.source_filter_menu.grid(row=0, column=1, sticky="e", padx=14, pady=12)

        self.results_scroll = ctk.CTkScrollableFrame(
            panel,
            corner_radius=18,
            fg_color=("#f8faff", "#0f1824"),
        )
        self.results_scroll.grid(row=2, column=0, sticky="nsew", padx=16, pady=(0, 16))
        self.results_scroll.grid_columnconfigure(0, weight=1)

        self._show_empty_result_state("执行搜索后，这里会展示来自不同歌词源的结果。")

    def _build_preview_panel(self, parent) -> None:
        panel = ctk.CTkFrame(parent, corner_radius=24)
        panel.grid(row=0, column=2, sticky="nsew", padx=(0, 10), pady=10)
        panel.grid_rowconfigure(3, weight=1)
        panel.grid_columnconfigure(0, weight=1)

        hero = ctk.CTkFrame(panel, corner_radius=22, fg_color=("#dde8ff", "#162235"))
        hero.grid(row=0, column=0, sticky="ew", padx=16, pady=(16, 10))
        hero.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            hero,
            textvariable=self.preview_title_var,
            font=ctk.CTkFont(size=22, weight="bold"),
        ).grid(row=0, column=0, sticky="w", padx=18, pady=(14, 4))

        ctk.CTkLabel(
            hero,
            textvariable=self.preview_meta_var,
            justify="left",
            anchor="w",
            text_color=("#556178", "#aab8cb"),
        ).grid(row=1, column=0, sticky="w", padx=18, pady=2)

        ctk.CTkLabel(
            hero,
            textvariable=self.preview_source_var,
            justify="left",
            anchor="w",
        ).grid(row=2, column=0, sticky="w", padx=18, pady=2)

        ctk.CTkLabel(
            hero,
            textvariable=self.preview_stats_var,
            justify="left",
            anchor="w",
            text_color=("#556178", "#aab8cb"),
        ).grid(row=3, column=0, sticky="w", padx=18, pady=(2, 14))

        action_bar = ctk.CTkFrame(panel, fg_color="transparent")
        action_bar.grid(row=1, column=0, sticky="ew", padx=16, pady=(0, 10))
        action_bar.grid_columnconfigure((0, 1, 2), weight=1)

        self.save_button = ctk.CTkButton(
            action_bar,
            text="保存选中结果",
            height=42,
            corner_radius=15,
            command=self._save_selected_candidate,
            state="disabled",
        )
        self.save_button.grid(row=0, column=0, sticky="ew", padx=(0, 6))

        ctk.CTkButton(
            action_bar,
            text="复制歌词",
            height=42,
            corner_radius=15,
            fg_color=("#e7ebf4", "#1b2738"),
            text_color=("#1e2a3b", "#edf3ff"),
            hover_color=("#dbe2ef", "#223145"),
            command=self._copy_preview_lyrics,
        ).grid(row=0, column=1, sticky="ew", padx=6)

        ctk.CTkButton(
            action_bar,
            text="打开输出目录",
            height=42,
            corner_radius=15,
            fg_color=("#e7ebf4", "#1b2738"),
            text_color=("#1e2a3b", "#edf3ff"),
            hover_color=("#dbe2ef", "#223145"),
            command=self._open_output_dir,
        ).grid(row=0, column=2, sticky="ew", padx=(6, 0))

        preview_modes = ctk.CTkFrame(
            panel, corner_radius=18, fg_color=("#f3f6fb", "#121d2b")
        )
        preview_modes.grid(row=2, column=0, sticky="ew", padx=16, pady=(0, 10))
        preview_modes.grid_columnconfigure((0, 1, 2), weight=1)

        ctk.CTkButton(
            preview_modes,
            text="原始/最佳预览",
            height=36,
            corner_radius=12,
            command=lambda: self._refresh_preview_text(mode="default"),
        ).grid(row=0, column=0, sticky="ew", padx=(10, 6), pady=10)

        ctk.CTkButton(
            preview_modes,
            text="去时间戳预览",
            height=36,
            corner_radius=12,
            command=lambda: self._refresh_preview_text(mode="plain"),
        ).grid(row=0, column=1, sticky="ew", padx=6, pady=10)

        ctk.CTkButton(
            preview_modes,
            text="翻译歌词",
            height=36,
            corner_radius=12,
            command=lambda: self._refresh_preview_text(mode="translated"),
        ).grid(row=0, column=2, sticky="ew", padx=(6, 10), pady=10)

        self.preview_text = ctk.CTkTextbox(
            panel,
            corner_radius=18,
            wrap="word",
            font=ctk.CTkFont(family="Microsoft YaHei UI", size=14),
        )
        self.preview_text.grid(row=3, column=0, sticky="nsew", padx=16, pady=(0, 16))
        self.preview_text.insert(
            "1.0",
            "搜索并选择一条歌词结果后，这里会显示歌词预览。\n\n你可以在这里对比不同来源的内容，再决定保存哪一条。",
        )
        self.preview_text.configure(state="disabled")

    def _build_batch_tab(self) -> None:
        tab = self.batch_tab
        tab.grid_rowconfigure(1, weight=1)
        tab.grid_columnconfigure(0, weight=0, minsize=400)
        tab.grid_columnconfigure(1, weight=1)

        top_card = ctk.CTkFrame(tab, corner_radius=24)
        top_card.grid(
            row=0, column=0, columnspan=2, sticky="ew", padx=10, pady=(10, 10)
        )
        top_card.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            top_card,
            text="批量处理",
            font=ctk.CTkFont(size=26, weight="bold"),
        ).grid(row=0, column=0, sticky="w", padx=18, pady=(16, 4))

        ctk.CTkLabel(
            top_card,
            text="批量模式会沿用上方来源选择和保存选项；适合为整批音频自动匹配并保存歌词。",
            text_color=("#61728b", "#a7b8cf"),
            wraplength=1200,
            justify="left",
        ).grid(row=1, column=0, sticky="w", padx=18, pady=(0, 14))

        left = ctk.CTkFrame(tab, corner_radius=24)
        left.grid(row=1, column=0, sticky="nsew", padx=(10, 10), pady=(0, 10))
        left.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            left,
            text="批量来源目录",
            font=ctk.CTkFont(size=18, weight="bold"),
        ).grid(row=0, column=0, sticky="w", padx=16, pady=(16, 8))

        row = ctk.CTkFrame(left, fg_color="transparent")
        row.grid(row=1, column=0, sticky="ew", padx=16, pady=(0, 10))
        row.grid_columnconfigure(0, weight=1)

        ctk.CTkEntry(
            row,
            textvariable=self.batch_dir_var,
            height=42,
            corner_radius=14,
            placeholder_text="选择音乐目录",
        ).grid(row=0, column=0, sticky="ew", padx=(0, 8))

        ctk.CTkButton(
            row,
            text="浏览",
            width=84,
            height=42,
            corner_radius=14,
            command=self._browse_batch_dir,
        ).grid(row=0, column=1)

        settings = ctk.CTkFrame(left, corner_radius=18, fg_color=("#f3f6fb", "#121d2b"))
        settings.grid(row=2, column=0, sticky="ew", padx=16, pady=(0, 10))

        ctk.CTkCheckBox(
            settings,
            text="递归处理子目录",
            variable=self.recursive_var,
        ).grid(row=0, column=0, sticky="w", padx=14, pady=(12, 6))

        ctk.CTkCheckBox(
            settings,
            text="仅搜索不保存",
            variable=self.dry_run_var,
        ).grid(row=0, column=1, sticky="w", padx=14, pady=(12, 6))

        ctk.CTkCheckBox(
            settings,
            text="覆盖已存在 LRC",
            variable=self.overwrite_var,
        ).grid(row=1, column=0, sticky="w", padx=14, pady=(0, 12))

        ctk.CTkCheckBox(
            settings,
            text="去掉时间戳后保存",
            variable=self.strip_timestamps_var,
        ).grid(row=1, column=1, sticky="w", padx=14, pady=(0, 12))

        batch_actions = ctk.CTkFrame(left, fg_color="transparent")
        batch_actions.grid(row=3, column=0, sticky="ew", padx=16, pady=(0, 12))
        batch_actions.grid_columnconfigure((0, 1), weight=1)

        self.batch_button = ctk.CTkButton(
            batch_actions,
            text="开始批量处理",
            height=46,
            corner_radius=16,
            command=self._start_batch,
        )
        self.batch_button.grid(row=0, column=0, sticky="ew", padx=(0, 6))

        ctk.CTkButton(
            batch_actions,
            text="清空日志",
            height=46,
            corner_radius=16,
            fg_color=("#e7ebf4", "#1b2738"),
            text_color=("#1e2a3b", "#edf3ff"),
            hover_color=("#dbe2ef", "#223145"),
            command=self._clear_batch_log,
        ).grid(row=0, column=1, sticky="ew", padx=(6, 0))

        ctk.CTkLabel(
            left,
            textvariable=self.batch_status_var,
            text_color=("#61728b", "#a7b8cf"),
        ).grid(row=4, column=0, sticky="w", padx=16, pady=(0, 14))

        right = ctk.CTkFrame(tab, corner_radius=24)
        right.grid(row=1, column=1, sticky="nsew", padx=(0, 10), pady=(0, 10))
        right.grid_rowconfigure(1, weight=1)
        right.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            right,
            text="运行日志",
            font=ctk.CTkFont(size=20, weight="bold"),
        ).grid(row=0, column=0, sticky="w", padx=16, pady=(16, 8))

        self.batch_log_text = ctk.CTkTextbox(
            right,
            corner_radius=18,
            wrap="word",
            font=ctk.CTkFont(family="Consolas", size=13),
        )
        self.batch_log_text.grid(row=1, column=0, sticky="nsew", padx=16, pady=(0, 16))
        self.batch_log_text.insert(
            "1.0",
            "批量处理日志会显示在这里。\n\n提示：批量模式沿用“单曲搜索”页中选择的歌词源与保存选项。",
        )
        self.batch_log_text.configure(state="disabled")

    def _build_status_bar(self) -> None:
        bar = ctk.CTkFrame(
            self, corner_radius=0, fg_color=("#edf2fb", "#101926"), height=42
        )
        bar.grid(row=2, column=0, sticky="ew")
        bar.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            bar,
            textvariable=self.search_status_var,
            text_color=("#5e6e86", "#9cb0ca"),
        ).grid(row=0, column=0, sticky="w", padx=18, pady=10)

    def _section(self, parent, title: str):
        frame = ctk.CTkFrame(parent, corner_radius=20, fg_color=("#f8faff", "#111b28"))
        frame.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            frame,
            text=title,
            font=ctk.CTkFont(size=17, weight="bold"),
        ).pack(anchor="w", padx=14, pady=(12, 10))
        return frame

    def _labeled_entry(self, parent, label: str, variable) -> ctk.CTkEntry:
        wrap = ctk.CTkFrame(parent, fg_color="transparent")
        wrap.pack(fill="x", pady=(0, 10))
        ctk.CTkLabel(
            wrap,
            text=label,
            font=ctk.CTkFont(size=13, weight="bold"),
        ).pack(anchor="w", pady=(0, 6))
        entry = ctk.CTkEntry(
            wrap,
            textvariable=variable,
            height=38,
            corner_radius=12,
        )
        entry.pack(fill="x")
        return entry

    def _labeled_option_menu(
        self,
        parent,
        label: str,
        variable,
        values: list[str],
        label_map: Optional[dict[str, str]] = None,
    ) -> None:
        wrap = ctk.CTkFrame(parent, fg_color="transparent")
        wrap.pack(fill="x", pady=(0, 10))
        ctk.CTkLabel(
            wrap,
            text=label,
            font=ctk.CTkFont(size=13, weight="bold"),
        ).pack(anchor="w", pady=(0, 6))

        shown_values = [label_map.get(v, v) if label_map else v for v in values]
        reverse_map = (
            {label_map.get(v, v): v for v in values}
            if label_map
            else {v: v for v in values}
        )

        current = shown_values[0]
        for shown, raw in reverse_map.items():
            if raw == variable.get():
                current = shown
                break

        display_var = ctk.StringVar(value=current)

        def on_change(choice: str):
            variable.set(reverse_map[choice])

        menu = ctk.CTkOptionMenu(
            wrap,
            values=shown_values,
            variable=display_var,
            command=on_change,
            height=38,
            corner_radius=12,
        )
        menu.pack(fill="x")

    def _update_input_mode(self) -> None:
        mode = self.input_mode_var.get()
        if mode == "读取音频文件":
            self.file_row.pack(fill="x", pady=(0, 10))
            self.file_entry.configure(state="normal")
            for entry in [
                self.title_entry,
                self.artist_entry,
                self.album_entry,
                self.duration_entry,
            ]:
                entry.configure(state="disabled")
        else:
            self.file_row.pack_forget()
            self.file_entry.configure(state="disabled")
            for entry in [
                self.title_entry,
                self.artist_entry,
                self.album_entry,
                self.duration_entry,
            ]:
                entry.configure(state="normal")

    def _browse_single_file(self) -> None:
        path = filedialog.askopenfilename(
            title="选择音频文件",
            filetypes=[
                (
                    "音频文件",
                    "*.mp3 *.flac *.m4a *.aac *.ogg *.opus *.wav *.wma *.ape *.mp4",
                ),
                ("所有文件", "*.*"),
            ],
        )
        if path:
            self.single_file_var.set(path)

    def _browse_batch_dir(self) -> None:
        path = filedialog.askdirectory(title="选择音乐目录")
        if path:
            self.batch_dir_var.set(path)

    def _browse_out_dir(self) -> None:
        path = filedialog.askdirectory(title="选择输出目录")
        if path:
            self.out_dir_var.set(path)

    def _select_all_providers(self) -> None:
        for var in self.provider_vars.values():
            var.set(True)

    def _clear_all_providers(self) -> None:
        for var in self.provider_vars.values():
            var.set(False)

    def _apply_provider_preset(self, enabled: set[str]) -> None:
        for name, var in self.provider_vars.items():
            var.set(name in enabled)

    def _selected_providers(self) -> list[str]:
        return [name for name, var in self.provider_vars.items() if bool(var.get())]

    def _collect_search_query(self) -> core.TrackQuery:
        mode = self.input_mode_var.get()
        if mode == "读取音频文件":
            raw = self.single_file_var.get().strip()
            if not raw:
                raise ValueError("请选择一个音频文件。")
            path = Path(raw).expanduser().resolve()
            if not path.exists():
                raise ValueError(f"文件不存在：{path}")
            return core.read_audio_metadata(path)

        title = self.title_var.get().strip()
        if not title:
            raise ValueError("请填写歌曲名。")

        duration = None
        duration_text = self.duration_var.get().strip()
        if duration_text:
            try:
                duration = int(duration_text)
            except ValueError as exc:
                raise ValueError("时长必须是整数秒。") from exc

        return core.build_manual_query(
            title=title,
            artist=self.artist_var.get().strip(),
            album=self.album_var.get().strip(),
            duration=duration,
        )

    def _collect_save_options(self) -> core.SaveOptions:
        out_dir_text = self.out_dir_var.get().strip()
        out_dir = Path(out_dir_text).expanduser().resolve() if out_dir_text else None

        return core.SaveOptions(
            output_mode=self.name_format_var.get(),
            overwrite=bool(self.overwrite_var.get()),
            out_dir=out_dir,
            lyric_mode=self.lyric_mode_var.get(),
            include_metadata=bool(self.include_metadata_var.get()),
            strip_timestamps=bool(self.strip_timestamps_var.get()),
        )

    def _start_search(self) -> None:
        if self.search_thread and self.search_thread.is_alive():
            messagebox.showinfo("提示", "当前已有搜索任务在运行。")
            return

        try:
            query = self._collect_search_query()
            providers = self._selected_providers()
            if not providers:
                raise ValueError("请至少选择一个歌词源。")
        except ValueError as exc:
            messagebox.showwarning("参数错误", str(exc))
            return

        self.current_query = query
        self._set_search_busy(True)
        self.search_status_var.set(f"正在搜索：{query.title} / {query.artist}")
        self.result_summary_var.set("正在聚合不同歌词源结果...")
        self._show_empty_result_state("正在搜索，请稍候...")

        prefer_synced = (
            self.lyric_mode_var.get() != "plain" and not self.strip_timestamps_var.get()
        )

        self.search_thread = threading.Thread(
            target=self._run_search_worker,
            args=(query, providers, prefer_synced),
            daemon=True,
        )
        self.search_thread.start()

    def _run_search_worker(
        self,
        query: core.TrackQuery,
        providers: list[str],
        prefer_synced: bool,
    ) -> None:
        try:
            if hasattr(core, "search_candidates_by_source"):
                bundle = core.search_candidates_by_source(
                    query,
                    providers,
                    prefer_synced=prefer_synced,
                    logger=self._log_from_worker,
                )
            else:
                candidates = core.collect_candidates(
                    query, providers, logger=self._log_from_worker
                )
                best = None
                if candidates:
                    best = candidates[0]
                bundle = {
                    "query": query,
                    "providers": providers,
                    "all_candidates": candidates,
                    "best_candidate": best,
                    "grouped_candidates": {},
                }

            self.ui_queue.put(("search_result", bundle))
        except Exception as exc:
            self.ui_queue.put(("search_error", str(exc)))
            self.ui_queue.put(("search_traceback", traceback.format_exc()))
        finally:
            self.ui_queue.put(("search_done", None))

    def _start_batch(self) -> None:
        if self.batch_thread and self.batch_thread.is_alive():
            messagebox.showinfo("提示", "当前已有批量任务在运行。")
            return

        folder_text = self.batch_dir_var.get().strip()
        providers = self._selected_providers()
        if not folder_text:
            messagebox.showwarning("参数错误", "请选择一个音乐目录。")
            return
        if not providers:
            messagebox.showwarning("参数错误", "请至少选择一个歌词源。")
            return

        folder = Path(folder_text).expanduser().resolve()
        if not folder.exists():
            messagebox.showwarning("参数错误", f"目录不存在：\n{folder}")
            return

        self._set_batch_busy(True)
        self.batch_status_var.set("正在批量处理...")
        self._append_batch_log("=== 开始批量处理 ===")
        self._append_batch_log(f"[INFO] 目录: {folder}")
        self._append_batch_log(f"[INFO] 来源: {', '.join(providers)}")

        save_options = self._collect_save_options()
        recursive = bool(self.recursive_var.get())
        dry_run = bool(self.dry_run_var.get())

        self.batch_thread = threading.Thread(
            target=self._run_batch_worker,
            args=(folder, providers, save_options, recursive, dry_run),
            daemon=True,
        )
        self.batch_thread.start()

    def _run_batch_worker(
        self,
        folder: Path,
        providers: list[str],
        save_options: core.SaveOptions,
        recursive: bool,
        dry_run: bool,
    ) -> None:
        failed = 0
        try:
            files = core.find_audio_files(folder, recursive=recursive)
            if not files:
                self.log_queue.put("[ERROR] 没有找到支持的音频文件。")
                return

            self.log_queue.put(f"[INFO] 共找到 {len(files)} 个音频文件。")

            for index, file_path in enumerate(files, start=1):
                self.log_queue.put(
                    f"\n=== [{index}/{len(files)}] 处理: {file_path.name} ==="
                )
                query = core.read_audio_metadata(file_path)
                self.log_queue.put(f"[INFO] 搜索: {query.title} / {query.artist}")

                if dry_run:
                    best, candidates = core.choose_best_candidate(
                        query,
                        providers,
                        prefer_synced=(
                            save_options.lyric_mode != "plain"
                            and not save_options.strip_timestamps
                        ),
                        logger=self._log_from_worker,
                    )
                    if not best:
                        failed += 1
                        self.log_queue.put(
                            f"[FAIL] 未找到歌词: {query.title} - {query.artist}"
                        )
                        continue

                    self.log_queue.put(
                        f"[OK] 预览来源: {best.source} | {best.title} - {best.artist} | "
                        f"synced={best.has_synced} | candidates={len(candidates)}"
                    )
                    continue

                result = core.process_query(
                    query,
                    providers,
                    save_options,
                    logger=self._log_from_worker,
                )
                if result.success:
                    if result.output_path:
                        self.log_queue.put(f"[SAVE] {result.output_path}")
                    else:
                        self.log_queue.put(f"[OK] {result.message}")
                else:
                    failed += 1
                    self.log_queue.put(f"[FAIL] {result.message}")
        except Exception:
            self.log_queue.put("[FATAL] 批量任务发生未处理异常：")
            self.log_queue.put(traceback.format_exc())
            failed += 1
        finally:
            if failed:
                self.log_queue.put(f"\n[SUMMARY] 完成，但有 {failed} 项失败。")
            else:
                self.log_queue.put("\n[SUMMARY] 全部完成。")
            self.ui_queue.put(("batch_done", None))

    def _on_search_result(self, bundle) -> None:
        self.current_bundle = bundle

        if isinstance(bundle, dict):
            candidates = list(bundle.get("all_candidates") or [])
            best = bundle.get("best_candidate")
            grouped = bundle.get("grouped_candidates") or {}
        else:
            candidates = list(getattr(bundle, "all_candidates", []) or [])
            best = getattr(bundle, "best_candidate", None)
            grouped = getattr(bundle, "grouped_candidates", {}) or {}

        self.current_candidates = candidates

        values = ["all"]
        providers_from_results = (
            list(grouped) if grouped else sorted({c.source for c in candidates})
        )
        for provider in providers_from_results:
            if provider not in values:
                values.append(provider)

        self.source_filter_menu.configure(values=values)
        self.source_filter_var.set("all")

        count = len(candidates)
        if count == 0:
            self.result_summary_var.set("没有找到歌词结果")
            self._show_empty_result_state(
                "没有找到匹配的歌词结果。你可以尝试切换关键词或来源。"
            )
            self._clear_preview()
            self.search_status_var.set("搜索完成：未找到结果")
            return

        source_count = len({c.source for c in candidates})
        synced_count = len([c for c in candidates if c.has_synced])

        self.result_summary_var.set(
            f"共 {count} 条结果，来自 {source_count} 个来源，其中 {synced_count} 条带时间轴"
        )
        self.search_status_var.set("搜索完成，已展示不同歌词源结果")
        self._refresh_result_cards()

        if best:
            self._select_candidate(best)
        else:
            self._clear_preview()

    def _refresh_result_cards(self) -> None:
        for child in self.results_scroll.winfo_children():
            child.destroy()
        self.result_cards.clear()

        source_filter = self.source_filter_var.get()
        if source_filter == "all":
            items = list(self.current_candidates)
        else:
            items = [
                item for item in self.current_candidates if item.source == source_filter
            ]

        self.filtered_candidates = items

        if not items:
            self._show_empty_result_state("当前筛选条件下没有结果。")
            return

        for idx, cand in enumerate(items):
            selected = self.selected_candidate is cand
            card = self._build_result_card(self.results_scroll, cand, idx, selected)
            card.grid(row=idx, column=0, sticky="ew", pady=(0, 10))
            self.result_cards.append(card)

    def _build_result_card(
        self, parent, cand: core.LyricsCandidate, idx: int, selected: bool
    ):
        fg = ("#dbe7ff", "#17304e") if selected else ("#ffffff", "#111b28")
        border = ("#7ea5ff", "#4a7fff") if selected else ("#dde4f1", "#203045")

        card = ctk.CTkFrame(
            parent,
            corner_radius=18,
            fg_color=fg,
            border_width=1,
            border_color=border,
        )
        card.grid_columnconfigure(0, weight=1)

        title = cand.title or "未知标题"
        artist = cand.artist or "未知歌手"
        album = cand.album or "未知专辑"
        duration = f"{cand.duration}s" if cand.duration else "-"
        badges = []
        if cand.has_synced:
            badges.append("时间轴")
        if cand.has_plain:
            badges.append("纯文本")
        if (cand.translated_lyrics or "").strip():
            badges.append("翻译")
        badge_text = " · ".join(badges) if badges else "歌词"

        top = ctk.CTkFrame(card, fg_color="transparent")
        top.grid(row=0, column=0, sticky="ew", padx=14, pady=(12, 6))
        top.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            top,
            text=f"{title}",
            font=ctk.CTkFont(size=17, weight="bold"),
            anchor="w",
        ).grid(row=0, column=0, sticky="w")

        ctk.CTkLabel(
            top,
            text=self._provider_label(cand.source),
            corner_radius=12,
            fg_color=("#e6efff", "#22385a"),
            text_color=("#2b4f96", "#d7e6ff"),
            padx=10,
            pady=5,
        ).grid(row=0, column=1, sticky="e")

        ctk.CTkLabel(
            card,
            text=f"{artist}  ·  {album}",
            text_color=("#546179", "#aab8cb"),
            anchor="w",
        ).grid(row=1, column=0, sticky="w", padx=14)

        ctk.CTkLabel(
            card,
            text=f"{badge_text}  ·  时长 {duration}  ·  分数 {cand.score:.1f}",
            text_color=("#62748d", "#9fb2cd"),
            anchor="w",
        ).grid(row=2, column=0, sticky="w", padx=14, pady=(4, 8))

        preview = self._candidate_preview_excerpt(cand)
        ctk.CTkLabel(
            card,
            text=preview,
            justify="left",
            anchor="w",
            wraplength=440,
            text_color=("#2a3547", "#d8e4f8"),
        ).grid(row=3, column=0, sticky="ew", padx=14, pady=(0, 10))

        actions = ctk.CTkFrame(card, fg_color="transparent")
        actions.grid(row=4, column=0, sticky="ew", padx=14, pady=(0, 12))
        actions.grid_columnconfigure((0, 1), weight=1)

        ctk.CTkButton(
            actions,
            text="预览",
            height=34,
            corner_radius=12,
            command=lambda c=cand: self._select_candidate(c),
        ).grid(row=0, column=0, sticky="ew", padx=(0, 6))

        ctk.CTkButton(
            actions,
            text="立即保存",
            height=34,
            corner_radius=12,
            fg_color=("#e7ebf4", "#1b2738"),
            text_color=("#1e2a3b", "#edf3ff"),
            hover_color=("#dbe2ef", "#223145"),
            command=lambda c=cand: self._quick_save_candidate(c),
        ).grid(row=0, column=1, sticky="ew", padx=(6, 0))

        self._bind_card_click(card, lambda e, c=cand: self._select_candidate(c))
        return card

    def _bind_card_click(self, widget, callback) -> None:
        widget.bind("<Button-1>", callback)
        for child in widget.winfo_children():
            try:
                child.bind("<Button-1>", callback)
            except Exception:
                pass
            self._bind_descendants(child, callback)

    def _bind_descendants(self, widget, callback) -> None:
        for child in widget.winfo_children():
            try:
                child.bind("<Button-1>", callback)
            except Exception:
                pass
            self._bind_descendants(child, callback)

    def _candidate_preview_excerpt(self, cand: core.LyricsCandidate) -> str:
        text = (
            cand.synced_lyrics.strip()
            or cand.plain_lyrics.strip()
            or cand.translated_lyrics.strip()
        )
        if not text:
            return "没有可预览的歌词内容"
        text = core.remove_lrc_timestamps(text)
        text = " ".join(line.strip() for line in text.splitlines()[:3] if line.strip())
        text = text.strip()
        if len(text) > 120:
            text = text[:120].rstrip() + "..."
        return text or "没有可预览的歌词内容"

    def _show_empty_result_state(self, text: str) -> None:
        for child in self.results_scroll.winfo_children():
            child.destroy()

        card = ctk.CTkFrame(
            self.results_scroll, corner_radius=18, fg_color=("#f3f6fb", "#121d2b")
        )
        card.grid(row=0, column=0, sticky="ew", pady=(0, 10))
        ctk.CTkLabel(
            card,
            text=text,
            wraplength=420,
            justify="center",
            text_color=("#607089", "#a7b8cf"),
        ).pack(fill="both", expand=True, padx=20, pady=30)

    def _select_candidate(self, candidate: core.LyricsCandidate) -> None:
        self.selected_candidate = candidate
        self.save_button.configure(state="normal")
        self._refresh_result_cards()
        self._update_preview_meta(candidate)
        self._refresh_preview_text(mode="default")

    def _update_preview_meta(self, cand: core.LyricsCandidate) -> None:
        self.preview_title_var.set(cand.title or "未命名歌曲")
        self.preview_meta_var.set(
            f"{cand.artist or '未知歌手'}\n专辑：{cand.album or '未知专辑'}"
        )
        self.preview_source_var.set(
            f"来源：{self._provider_label(cand.source)}   分数：{cand.score:.1f}"
        )
        self.preview_stats_var.set(
            f"时间轴：{'有' if cand.has_synced else '无'}   "
            f"纯文本：{'有' if cand.has_plain else '无'}   "
            f"翻译：{'有' if (cand.translated_lyrics or '').strip() else '无'}"
        )

    def _refresh_preview_text(self, mode: str = "default") -> None:
        cand = self.selected_candidate
        if not cand:
            self._set_preview_text("请先选择一条搜索结果。")
            return

        if mode == "translated":
            text = (cand.translated_lyrics or "").strip() or "该结果没有翻译歌词。"
        elif mode == "plain":
            text = core.remove_lrc_timestamps(
                cand.synced_lyrics or cand.plain_lyrics or ""
            ).strip()
            if not text:
                text = "该结果没有可用的纯文本预览。"
        else:
            save_options = self._collect_save_options()
            try:
                text = core.render_lrc(
                    cand,
                    lyric_mode=save_options.lyric_mode,
                    include_metadata=save_options.include_metadata,
                    strip_timestamps=save_options.strip_timestamps,
                ).strip()
            except Exception:
                text = (
                    cand.synced_lyrics.strip()
                    or cand.plain_lyrics.strip()
                    or cand.translated_lyrics.strip()
                    or "没有可预览的歌词内容。"
                )

        self._set_preview_text(text or "没有可预览的歌词内容。")

    def _set_preview_text(self, text: str) -> None:
        self.preview_text.configure(state="normal")
        self.preview_text.delete("1.0", "end")
        self.preview_text.insert("1.0", text)
        self.preview_text.configure(state="disabled")

    def _clear_preview(self) -> None:
        self.selected_candidate = None
        self.save_button.configure(state="disabled")
        self.preview_title_var.set("未选择结果")
        self.preview_meta_var.set("请先执行搜索")
        self.preview_source_var.set("来源：-")
        self.preview_stats_var.set("时间轴：-   纯文本：-   翻译：-")
        self._set_preview_text(
            "搜索并选择一条歌词结果后，这里会显示歌词预览。\n\n你可以在这里对比不同来源的内容，再决定保存哪一条。"
        )

    def _clear_search_results(self) -> None:
        self.current_bundle = None
        self.current_candidates = []
        self.filtered_candidates = []
        self.selected_candidate = None
        self.source_filter_menu.configure(values=["all"])
        self.source_filter_var.set("all")
        self.result_summary_var.set("还没有搜索结果")
        self.search_status_var.set("准备就绪")
        self._show_empty_result_state("执行搜索后，这里会展示来自不同歌词源的结果。")
        self._clear_preview()

    def _save_selected_candidate(self) -> None:
        if not self.selected_candidate or not self.current_query:
            messagebox.showinfo("提示", "请先选择一条结果。")
            return

        try:
            save_options = self._collect_save_options()
            if hasattr(core, "save_selected_candidate"):
                output_path = core.save_selected_candidate(
                    self.current_query,
                    self.selected_candidate,
                    save_options,
                )
            else:
                output_path = core.save_lyrics(
                    self.selected_candidate,
                    self.current_query,
                    save_options,
                )
        except FileExistsError as exc:
            messagebox.showwarning("文件已存在", str(exc))
            return
        except Exception as exc:
            messagebox.showerror("保存失败", str(exc))
            return

        self.search_status_var.set(f"已保存到：{output_path}")
        messagebox.showinfo("保存成功", f"歌词已保存到：\n{output_path}")

    def _quick_save_candidate(self, candidate: core.LyricsCandidate) -> None:
        self._select_candidate(candidate)
        self._save_selected_candidate()

    def _copy_preview_lyrics(self) -> None:
        text = self.preview_text.get("1.0", "end").strip()
        if not text:
            messagebox.showinfo("提示", "当前没有可复制的歌词内容。")
            return
        self.clipboard_clear()
        self.clipboard_append(text)
        self.search_status_var.set("已复制歌词到剪贴板")

    def _open_output_dir(self) -> None:
        candidate = self.out_dir_var.get().strip()
        if not candidate and self.current_query and self.current_query.source_file:
            candidate = str(self.current_query.source_file.parent)
        if not candidate and self.batch_dir_var.get().strip():
            candidate = self.batch_dir_var.get().strip()
        if not candidate:
            candidate = str(Path.cwd())

        path = Path(candidate)
        if not path.exists():
            messagebox.showwarning("提示", f"目录不存在：\n{path}")
            return

        try:
            os.startfile(str(path))
        except Exception as exc:
            messagebox.showerror("错误", f"无法打开目录：\n{exc}")

    def _clear_batch_log(self) -> None:
        self.batch_log_text.configure(state="normal")
        self.batch_log_text.delete("1.0", "end")
        self.batch_log_text.configure(state="disabled")

    def _append_batch_log(self, text: str) -> None:
        self.batch_log_text.configure(state="normal")
        self.batch_log_text.insert("end", text + "\n")
        self.batch_log_text.see("end")
        self.batch_log_text.configure(state="disabled")

    def _set_search_busy(self, busy: bool) -> None:
        self.search_button.configure(state="disabled" if busy else "normal")

    def _set_batch_busy(self, busy: bool) -> None:
        self.batch_button.configure(state="disabled" if busy else "normal")

    def _log_from_worker(self, message: str) -> None:
        self.log_queue.put(message)

    def _drain_queues(self) -> None:
        while True:
            try:
                message = self.log_queue.get_nowait()
            except queue.Empty:
                break
            else:
                self._append_batch_log(message)

        while True:
            try:
                event, payload = self.ui_queue.get_nowait()
            except queue.Empty:
                break
            else:
                if event == "search_result":
                    self._on_search_result(payload)
                elif event == "search_error":
                    self.search_status_var.set(f"搜索失败：{payload}")
                    messagebox.showerror("搜索失败", str(payload))
                elif event == "search_traceback":
                    self._append_batch_log("[SEARCH ERROR TRACEBACK]")
                    self._append_batch_log(str(payload))
                elif event == "search_done":
                    self._set_search_busy(False)
                elif event == "batch_done":
                    self._set_batch_busy(False)
                    self.batch_status_var.set("批量任务已结束")

        self.after(120, self._drain_queues)


def main() -> None:
    app = LyricsFetcherGUI()
    app.mainloop()


if __name__ == "__main__":
    main()

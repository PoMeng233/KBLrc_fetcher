#!/usr/bin/env python3
from __future__ import annotations

import json
import queue
import threading
from pathlib import Path
from tkinter import Text, filedialog, messagebox
from typing import Optional

import customtkinter as ctk

# Safe fallback so DND_FILES is always defined even when tkinterdnd2 is missing
DND_FILES = "DND_Files"
try:
    from tkinterdnd2 import DND_FILES as TKDND_FILES
    from tkinterdnd2 import TkinterDnD

    DND_FILES = TKDND_FILES
    HAS_DND = True
except ImportError:
    HAS_DND = False
    TkinterDnD = None

import lyrics_fetcher as core

SETTINGS_PATH = Path(__file__).with_name("gui_settings.json")


class ModernButton(ctk.CTkButton):
    """按钮 - 带悬停效果"""

    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        self._default_fg = kwargs.get("fg_color", ("#3b82f6", "#1e40af"))
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)

    def _on_enter(self, event=None):
        self.configure(
            fg_color=("#2563eb", "#1e3a8a")
            if isinstance(self._default_fg, tuple)
            else "#2563eb"
        )

    def _on_leave(self, event=None):
        self.configure(fg_color=self._default_fg)


class GlassFrame(ctk.CTkFrame):
    """毛玻璃风格框架"""

    def __init__(self, master, **kwargs):
        bg_color = kwargs.pop("bg_color", ("#f0f4f8", "#0f1419"))
        super().__init__(
            master, fg_color=bg_color, corner_radius=16, border_width=1, **kwargs
        )

        # 设置半透明边框效果
        self.configure(border_color=("#d0d8e0", "#2a3f5f"))


class LyricsFetcherGUI(ctk.CTk):
    """
    Main GUI class for KB歌词搜索.
    Supports drag-and-drop if tkinterdnd2 is available.
    """

    def __init__(self):
        super().__init__()

        ctk.set_appearance_mode("system")
        ctk.set_default_color_theme("blue")

        self.title("KB歌词搜索 - KBlrc_fetcher")
        self.geometry("1200x800")
        self.minsize(900, 600)

        # 配置网格权重，支持窗口缩放
        self.grid_rowconfigure(0, weight=0)  # 顶部
        self.grid_rowconfigure(1, weight=1)  # 主内容
        self.grid_rowconfigure(2, weight=0)  # 底部
        self.grid_columnconfigure(0, weight=1)

        # 队列和线程
        self.log_queue: queue.Queue[str] = queue.Queue()
        self.ui_queue: queue.Queue[tuple[str, object]] = queue.Queue()
        self.search_thread: Optional[threading.Thread] = None
        self.batch_thread: Optional[threading.Thread] = None

        # 搜索状态
        self.current_query: Optional[core.TrackQuery] = None
        self.current_candidates: list[core.LyricsCandidate] = []
        self.selected_candidate: Optional[core.LyricsCandidate] = None

        self._init_vars()
        self._suspend_query_sync = False
        self._build_ui()

        # 启动时检查歌词源可用性
        self._check_provider_health()

        # 先尝试为当前窗口注入 DnD 能力，再注册拖放
        self._enable_dnd_if_possible()
        if HAS_DND:
            self._register_drag_drop()

        self.after(100, self._drain_queues)

    def _init_vars(self) -> None:
        # 输入字段
        self.title_var = ctk.StringVar()
        self.artist_var = ctk.StringVar()
        self.album_var = ctk.StringVar()
        self.duration_var = ctk.StringVar()
        self.out_dir_var = ctk.StringVar()

        # 保存和歌词选项
        self.name_format_var = ctk.StringVar(value="file")
        self.lyric_mode_var = ctk.StringVar(value="auto")
        self.include_metadata_var = ctk.BooleanVar(value=False)
        self.strip_timestamps_var = ctk.BooleanVar(value=False)
        self.strip_translation_var = ctk.BooleanVar(value=False)
        self.overwrite_var = ctk.BooleanVar(value=False)

        # 歌词源
        self.provider_vars: dict[str, ctk.BooleanVar] = {}
        for provider in ["lrclib", "lyricsovh", "kugou", "kuwo", "netease", "qq"]:
            self.provider_vars[provider] = ctk.BooleanVar(value=True)

        # UI 状态
        self.status_var = ctk.StringVar(value="准备就绪")
        self.result_count_var = ctk.StringVar(value="0 条结果")
        self._load_settings()

    def _build_ui(self) -> None:
        # 设置背景
        self.configure(fg_color=("#f8fafb", "#0a0e14"))

        # 顶部栏
        self._build_header()

        # 主容器 - 左右两栏
        main_container = ctk.CTkFrame(self, fg_color="transparent")
        main_container.grid(row=1, column=0, sticky="nsew", padx=12, pady=12)
        main_container.grid_rowconfigure(0, weight=1)
        main_container.grid_columnconfigure(0, weight=0, minsize=320)
        main_container.grid_columnconfigure(1, weight=1, minsize=400)

        # 左侧面板
        self._build_left_panel(main_container)

        # 右侧面板
        self._build_right_panel(main_container)

        # 底部状态栏
        self._build_status_bar()
        self._build_drag_overlay()

    def _build_header(self) -> None:
        header = GlassFrame(self)
        header.grid(row=0, column=0, sticky="ew", padx=12, pady=(12, 6))
        header.grid_columnconfigure(0, weight=1)

        title = ctk.CTkLabel(
            header, text="🎵 KB歌词搜索", font=ctk.CTkFont(size=24, weight="bold")
        )
        title.grid(row=0, column=0, sticky="w", padx=16, pady=12)

        subtitle = ctk.CTkLabel(
            header,
            text="多源歌词搜索 • 拖放文件快速识别 • 现代化界面",
            font=ctk.CTkFont(size=12),
            text_color=("#6b7280", "#9ca3af"),
        )
        subtitle.grid(row=1, column=0, sticky="w", padx=16, pady=(0, 12))

    def _build_left_panel(self, parent) -> None:
        left = GlassFrame(parent)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        left.grid_rowconfigure(5, weight=0)
        left.grid_rowconfigure(8, weight=1)  # Empty space for flexibility
        left.grid_columnconfigure(0, weight=1)

        # 输入模式标签
        ctk.CTkLabel(
            left, text="🔍 搜索参数", font=ctk.CTkFont(size=14, weight="bold")
        ).grid(row=0, column=0, sticky="w", padx=14, pady=(14, 8))

        # 输入字段 - 紧凑布局
        self.title_entry = ctk.CTkEntry(
            left,
            textvariable=self.title_var,
            placeholder_text="歌曲名",
            height=36,
            corner_radius=10,
        )
        self.title_entry.grid(row=1, column=0, sticky="ew", padx=12, pady=4)

        self.artist_entry = ctk.CTkEntry(
            left,
            textvariable=self.artist_var,
            placeholder_text="歌手",
            height=36,
            corner_radius=10,
        )
        self.artist_entry.grid(row=2, column=0, sticky="ew", padx=12, pady=4)

        album_duration = ctk.CTkFrame(left, fg_color="transparent")
        album_duration.grid(row=3, column=0, sticky="ew", padx=12, pady=4)
        album_duration.grid_columnconfigure((0, 1), weight=1)

        self.album_entry = ctk.CTkEntry(
            album_duration,
            textvariable=self.album_var,
            placeholder_text="专辑",
            height=36,
            corner_radius=10,
        )
        self.album_entry.grid(row=0, column=0, sticky="ew", padx=(0, 4))

        self.duration_entry = ctk.CTkEntry(
            album_duration,
            textvariable=self.duration_var,
            placeholder_text="时长(秒)",
            height=36,
            corner_radius=10,
            width=80,
        )
        self.duration_entry.grid(row=0, column=1, sticky="e", padx=(4, 0))

        self._bind_query_reset_handlers()

        # 歌词源选择 - 紧凑网格
        ctk.CTkLabel(
            left, text="📚 歌词源", font=ctk.CTkFont(size=12, weight="bold")
        ).grid(row=4, column=0, sticky="w", padx=12, pady=(12, 6))

        provider_frame = ctk.CTkFrame(left, fg_color="transparent")
        provider_frame.grid(row=5, column=0, sticky="nsew", padx=12, pady=4)
        provider_frame.grid_columnconfigure((0, 1), weight=1)

        providers = [
            ("lrclib", "LRCLIB"),
            ("lyricsovh", "Lyrics.ovh"),
            ("kugou", "酷狗"),
            ("kuwo", "酷我"),
            ("netease", "网易"),
            ("qq", "QQ"),
        ]

        for idx, (key, label) in enumerate(providers):
            cb = ctk.CTkCheckBox(
                provider_frame,
                text=label,
                variable=self.provider_vars[key],
                font=ctk.CTkFont(size=11),
            )
            cb.grid(row=idx // 2, column=idx % 2, sticky="w", padx=4, pady=3)

        # 保存选项 - 折叠式
        ctk.CTkLabel(
            left, text="⚙️ 保存选项", font=ctk.CTkFont(size=12, weight="bold")
        ).grid(row=6, column=0, sticky="w", padx=12, pady=(12, 6))

        options_frame = ctk.CTkFrame(left, fg_color="transparent")
        options_frame.grid(row=7, column=0, sticky="ew", padx=12, pady=4)
        options_frame.grid_columnconfigure(0, weight=1)

        ctk.CTkCheckBox(
            options_frame,
            text="写入元数据",
            variable=self.include_metadata_var,
            font=ctk.CTkFont(size=10),
        ).grid(row=0, column=0, sticky="w", pady=2)

        ctk.CTkCheckBox(
            options_frame,
            text="去掉时间戳",
            variable=self.strip_timestamps_var,
            font=ctk.CTkFont(size=10),
        ).grid(row=1, column=0, sticky="w", pady=2)

        ctk.CTkCheckBox(
            options_frame,
            text="覆盖已有文件",
            variable=self.overwrite_var,
            font=ctk.CTkFont(size=10),
        ).grid(row=2, column=0, sticky="w", pady=2)

        ctk.CTkCheckBox(
            options_frame,
            text="自动去除翻译行",
            variable=self.strip_translation_var,
            font=ctk.CTkFont(size=10),
        ).grid(row=3, column=0, sticky="w", pady=2)

        # 输出目录
        ctk.CTkLabel(
            left, text="📁 输出目录", font=ctk.CTkFont(size=11, weight="bold")
        ).grid(row=8, column=0, sticky="w", padx=12, pady=(12, 4))

        dir_frame = ctk.CTkFrame(left, fg_color="transparent")
        dir_frame.grid(row=9, column=0, sticky="ew", padx=12, pady=4)
        dir_frame.grid_columnconfigure(0, weight=1)

        ctk.CTkEntry(
            dir_frame,
            textvariable=self.out_dir_var,
            placeholder_text="留空则保存到默认位置",
            height=32,
            corner_radius=10,
        ).grid(row=0, column=0, sticky="ew", padx=(0, 6))

        ModernButton(
            dir_frame,
            text="浏览",
            width=70,
            height=32,
            corner_radius=10,
            command=self._browse_dir,
        ).grid(row=0, column=1, sticky="e")

        # 浏览歌曲文件并自动搜索
        self.browse_song_btn = ModernButton(
            left,
            text="🎧 浏览歌曲文件并搜索",
            height=38,
            font=ctk.CTkFont(size=12, weight="bold"),
            corner_radius=10,
            command=self._browse_song_and_search,
        )
        self.browse_song_btn.grid(row=10, column=0, sticky="ew", padx=12, pady=(10, 6))

        # 搜索按钮 - 主要操作
        self.search_btn = ModernButton(
            left,
            text="🔍 搜索歌词",
            height=44,
            font=ctk.CTkFont(size=13, weight="bold"),
            corner_radius=12,
            command=self._start_search,
        )
        self.search_btn.grid(row=11, column=0, sticky="ew", padx=12, pady=(8, 12))

    def _build_right_panel(self, parent) -> None:
        right = GlassFrame(parent)
        right.grid(row=0, column=1, sticky="nsew", padx=(8, 0))
        right.grid_rowconfigure(1, weight=1)
        right.grid_rowconfigure(2, weight=0)
        right.grid_columnconfigure(0, weight=1)

        # 结果标题
        title_frame = ctk.CTkFrame(right, fg_color="transparent")
        title_frame.grid(row=0, column=0, sticky="ew", padx=14, pady=(14, 8))
        title_frame.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            title_frame, text="🎼 搜索结果", font=ctk.CTkFont(size=14, weight="bold")
        ).grid(row=0, column=0, sticky="w")

        ctk.CTkLabel(
            title_frame,
            textvariable=self.result_count_var,
            font=ctk.CTkFont(size=11),
            text_color=("#6b7280", "#9ca3af"),
        ).grid(row=0, column=1, sticky="e")

        # 结果滚动框
        self.results_scroll = ctk.CTkScrollableFrame(
            right,
            corner_radius=14,
            fg_color=("#f3f4f6", "#1a1f2e"),
        )
        self.results_scroll.grid(row=1, column=0, sticky="nsew", padx=12, pady=(0, 12))
        self.results_scroll.grid_columnconfigure(0, weight=1)

        self._show_empty_state()

        # 预览和保存区
        preview_frame = GlassFrame(right, bg_color=("#f9fafb", "#111827"))
        preview_frame.grid(row=2, column=0, sticky="ew", padx=12, pady=(0, 0))
        preview_frame.grid_columnconfigure(0, weight=1)

        self.preview_btn = ModernButton(
            preview_frame,
            text="👁️ 浏览歌词",
            height=34,
            font=ctk.CTkFont(size=11, weight="bold"),
            corner_radius=10,
            command=self._preview_candidate,
            state="disabled",
        )
        self.preview_btn.grid(row=0, column=0, sticky="ew", padx=12, pady=(12, 6))

        self.save_btn = ModernButton(
            preview_frame,
            text="💾 保存选中结果",
            height=38,
            font=ctk.CTkFont(size=12, weight="bold"),
            corner_radius=10,
            command=self._save_candidate,
            state="disabled",
        )
        self.save_btn.grid(row=1, column=0, sticky="ew", padx=12, pady=(6, 12))

    def _build_status_bar(self) -> None:
        status = ctk.CTkFrame(self, fg_color=("#f3f4f6", "#111827"), corner_radius=0)
        status.grid(row=2, column=0, sticky="ew")
        status.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            status,
            textvariable=self.status_var,
            font=ctk.CTkFont(size=11),
            text_color=("#4b5563", "#a0aac0"),
        ).grid(row=0, column=0, sticky="w", padx=16, pady=10)

    def _enable_dnd_if_possible(self) -> None:
        """为当前 CTk 根窗口动态注入 DnD 能力"""
        self._dnd_ready = False
        if not HAS_DND or TkinterDnD is None:
            return
        try:
            # 加载 tkdnd 包，让底层 tk 命令可用
            TkinterDnD._require(self)

            # 将 DnDWrapper 的方法动态挂到当前实例类上（CTk -> tkinter.Tk）
            for name in (
                "_substitute_dnd",
                "_dnd_bind",
                "dnd_bind",
                "drag_source_register",
                "drag_source_unregister",
                "drop_target_register",
                "drop_target_unregister",
                "platform_independent_types",
                "platform_specific_types",
                "get_dropfile_tempdir",
                "set_dropfile_tempdir",
            ):
                if not hasattr(self.__class__, name) and hasattr(
                    TkinterDnD.DnDWrapper, name
                ):
                    setattr(self.__class__, name, getattr(TkinterDnD.DnDWrapper, name))

            # 与 tkinter 事件替换机制对齐
            if hasattr(TkinterDnD.DnDWrapper, "_subst_format_dnd"):
                self._subst_format_dnd = TkinterDnD.DnDWrapper._subst_format_dnd
            if hasattr(TkinterDnD.DnDWrapper, "_subst_format_str_dnd"):
                self._subst_format_str_dnd = TkinterDnD.DnDWrapper._subst_format_str_dnd

            self._dnd_ready = True
        except Exception as e:
            self._dnd_ready = False
            print(f"Warning: DnD init failed: {e}")

    def _register_drag_drop(self) -> None:
        """注册拖放支持 (drag-and-drop)"""
        if not HAS_DND or not getattr(self, "_dnd_ready", False):
            return
        if not hasattr(self, "drop_target_register") or not hasattr(self, "dnd_bind"):
            return
        try:
            self.drop_target_register(DND_FILES)
            self.dnd_bind("<<DropEnter>>", self._on_drop_enter)
            self.dnd_bind("<<DropLeave>>", self._on_drop_leave)
            self.dnd_bind("<<Drop>>", self._on_drop)
            self.status_var.set("准备就绪（支持拖拽文件）")
        except Exception as e:
            print(f"Warning: Drag-and-drop not available: {e}")

    def _build_drag_overlay(self) -> None:
        """构建拖拽覆盖层（模糊感+中心提示）"""
        self.drag_overlay = ctk.CTkFrame(
            self,
            fg_color=("#e5e7eb", "#0f172a"),
            corner_radius=0,
        )
        self.drag_overlay.grid_columnconfigure(0, weight=1)
        self.drag_overlay.grid_rowconfigure(0, weight=1)
        self.drag_overlay.grid(row=0, column=0, rowspan=3, sticky="nsew")
        self.drag_overlay.grid_remove()

        center = ctk.CTkFrame(
            self.drag_overlay,
            fg_color=("#ffffff", "#111827"),
            corner_radius=18,
            border_width=1,
            border_color=("#cbd5e1", "#334155"),
        )
        center.grid(row=0, column=0, padx=40, pady=40)

        ctk.CTkLabel(
            center,
            text="拖入到此处搜索歌词",
            font=ctk.CTkFont(size=26, weight="bold"),
            text_color=("#0f172a", "#e2e8f0"),
        ).grid(row=0, column=0, padx=36, pady=(26, 10))

        ctk.CTkLabel(
            center,
            text="支持常见音频文件，放开后自动识别并搜索",
            font=ctk.CTkFont(size=13),
            text_color=("#64748b", "#94a3b8"),
        ).grid(row=1, column=0, padx=36, pady=(0, 26))

    def _show_drag_overlay(self) -> None:
        if hasattr(self, "drag_overlay"):
            self.drag_overlay.grid()
            self.drag_overlay.lift()
            self.drag_overlay.focus_force()

    def _hide_drag_overlay(self) -> None:
        if hasattr(self, "drag_overlay"):
            self.drag_overlay.grid_remove()

    def _on_drop_enter(self, event):
        self._show_drag_overlay()
        return event.action if hasattr(event, "action") else "copy"

    def _on_drop_leave(self, event):
        self._hide_drag_overlay()
        return event.action if hasattr(event, "action") else "copy"

    def _on_drop(self, event) -> None:
        """处理拖放文件 (handle dropped files)"""
        self._hide_drag_overlay()
        try:
            files = self.tk.splitlist(event.data) if hasattr(event, "data") else []
        except Exception:
            files = []

        if not files:
            self.status_var.set("❌ 未检测到拖入文件")
            return

        file_path = Path(str(files[0]).strip("{}"))
        if file_path.exists() and file_path.suffix.lower() in core.AUDIO_EXTENSIONS:
            try:
                self._load_file_query_and_search(file_path)
            except Exception as e:
                self.status_var.set(f"❌ 识别失败：{str(e)[:30]}")
        else:
            self.status_var.set("❌ 不支持的文件格式")

    def _show_empty_state(self) -> None:
        """显示空状态"""
        for child in self.results_scroll.winfo_children():
            child.destroy()

        empty = ctk.CTkFrame(self.results_scroll, fg_color="transparent")
        empty.grid(row=0, column=0, sticky="ew")

        ctk.CTkLabel(
            empty,
            text="📭 暂无结果",
            font=ctk.CTkFont(size=14, weight="bold"),
            text_color=("#9ca3af", "#6b7280"),
        ).pack(pady=24)

        ctk.CTkLabel(
            empty,
            text="拖放音乐文件到这里\n或输入歌曲信息后点击搜索",
            font=ctk.CTkFont(size=11),
            text_color=("#d1d5db", "#4b5563"),
            justify="center",
        ).pack(pady=(0, 24))

    def _build_result_card(self, cand: core.LyricsCandidate, idx: int) -> None:
        """构建结果卡片"""
        selected = self.selected_candidate is cand
        card = GlassFrame(
            self.results_scroll,
            bg_color=("#dbe7ff", "#17304e") if selected else ("#ffffff", "#111b28"),
        )
        card.grid(row=idx, column=0, sticky="ew", pady=6)
        card.grid_columnconfigure(0, weight=1)

        # 标题和来源
        header = ctk.CTkFrame(card, fg_color="transparent")
        header.grid(row=0, column=0, sticky="ew", padx=12, pady=(10, 4))
        header.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            header,
            text=cand.title or "未知",
            font=ctk.CTkFont(size=12, weight="bold"),
            anchor="w",
        ).grid(row=0, column=0, sticky="w")

        provider_label = {
            "lrclib": "LRCLIB",
            "lyricsovh": "Lyrics.ovh",
            "kugou": "酷狗",
            "kuwo": "酷我",
            "netease": "网易",
            "qq": "QQ",
        }.get(cand.source, cand.source)

        ctk.CTkLabel(
            header,
            text=f"📍 {provider_label}",
            font=ctk.CTkFont(size=10),
            text_color=("#4f46e5", "#818cf8"),
        ).grid(row=0, column=1, sticky="e")

        # 元数据
        meta = f"{cand.artist or '未知'} • {cand.album or '未知'}"
        ctk.CTkLabel(
            card,
            text=meta,
            font=ctk.CTkFont(size=10),
            text_color=("#6b7280", "#9ca3af"),
            anchor="w",
        ).grid(row=1, column=0, sticky="w", padx=12, pady=2)

        # 标签
        badges = []
        if cand.has_synced:
            badges.append("⏱️ 时间轴")
        if cand.has_plain:
            badges.append("📄 纯文本")
        if cand.has_translation:
            badges.append("🌐 翻译")

        if badges:
            ctk.CTkLabel(
                card,
                text=" | ".join(badges),
                font=ctk.CTkFont(size=9),
                text_color=("#6b7280", "#a0aac0"),
                anchor="w",
            ).grid(row=2, column=0, sticky="w", padx=12, pady=(4, 0))

        # 行为
        def select_this(refresh: bool = True):
            self.selected_candidate = cand
            self.save_btn.configure(state="normal")
            self.preview_btn.configure(state="normal")
            self.status_var.set(
                f"已选中：{cand.title or '未知标题'} - {cand.artist or '未知歌手'}"
            )
            if refresh:
                self._refresh_results()

        def open_preview():
            # 双击时先选中但不立即刷新，避免刷新重建卡片导致预览回调丢失
            select_this(refresh=False)
            self._preview_candidate()

        preview_text = core.render_lrc(
            cand,
            lyric_mode=self.lyric_mode_var.get(),
            include_metadata=bool(self.include_metadata_var.get()),
            strip_timestamps=bool(self.strip_timestamps_var.get()),
            strip_translation_lines=bool(self.strip_translation_var.get()),
        )
        snippet = "\n".join(preview_text.splitlines()[:4]).strip() or "（无歌词内容）"

        ctk.CTkLabel(
            card,
            text=snippet,
            font=ctk.CTkFont(size=10),
            justify="left",
            anchor="w",
            text_color=("#475569", "#94a3b8"),
        ).grid(row=3, column=0, sticky="ew", padx=12, pady=(6, 10))

        def _on_single_click(_event=None):
            # 延迟一点执行，避免和双击事件冲突
            card.after(180, lambda: select_this())

        def _on_double_click(_event=None):
            open_preview()
            return "break"

        card.bind("<Button-1>", _on_single_click)
        card.bind("<Double-Button-1>", _on_double_click)
        for child in card.winfo_children():
            child.bind("<Button-1>", _on_single_click)
            child.bind("<Double-Button-1>", _on_double_click)

    def _refresh_results(self) -> None:
        """刷新结果显示"""
        for child in self.results_scroll.winfo_children():
            child.destroy()

        if not self.current_candidates:
            self.save_btn.configure(state="disabled")
            self.preview_btn.configure(state="disabled")
            self._show_empty_state()
            return

        for idx, cand in enumerate(self.current_candidates):
            self._build_result_card(cand, idx)

    def _start_search(self) -> None:
        """启动搜索"""
        if self.search_thread and self.search_thread.is_alive():
            messagebox.showinfo("提示", "当前搜索在进行中")
            return

        try:
            title = self.title_entry.get().strip()
            artist = self.artist_entry.get().strip()
            album = self.album_entry.get().strip()

            duration_text = self.duration_entry.get().strip()
            duration_val = None
            if duration_text:
                if not duration_text.isdigit():
                    messagebox.showwarning("错误", "时长必须是数字（秒）")
                    return
                duration_val = int(duration_text)

            providers = [k for k, v in self.provider_vars.items() if v.get()]
            if not providers:
                messagebox.showwarning("错误", "请至少选择一个歌词源")
                return

            valid_providers = set(core.available_providers())
            invalid = [p for p in providers if p not in valid_providers]
            if invalid:
                messagebox.showwarning("错误", f"存在无效歌词源：{', '.join(invalid)}")
                return

            # 手动输入优先；若未填写则允许回退到已识别的文件查询
            if title:
                self.current_query = core.build_manual_query(
                    title=title,
                    artist=artist,
                    album=album,
                    duration=duration_val,
                )
            elif not self.current_query:
                messagebox.showwarning("错误", "请输入歌曲名")
                return
        except Exception as e:
            messagebox.showerror("错误", str(e))
            return

        self.status_var.set("🔍 正在搜索...")
        self.search_btn.configure(state="disabled")

        self.search_thread = threading.Thread(
            target=self._search_worker,
            args=(self.current_query, providers),
            daemon=True,
        )
        self.search_thread.start()

    def _search_worker(self, query: core.TrackQuery, providers: list[str]) -> None:
        """搜索线程"""
        try:
            bundle = core.search_candidates_by_source(
                query,
                providers,
                prefer_synced=True,
                logger=lambda msg: self.log_queue.put(msg),
                max_duration_sec=12.0,
            )

            if isinstance(bundle, dict):
                candidates = list(bundle.get("all_candidates", []))
            else:
                candidates = list(getattr(bundle, "all_candidates", []))

            self.current_candidates = candidates
            self.ui_queue.put(("search_done", None))
        except Exception as e:
            self.ui_queue.put(("search_error", str(e)))

    def _save_candidate(self) -> None:
        """保存选中的候选"""
        if not self.selected_candidate or not self.current_query:
            messagebox.showwarning("错误", "请先选择搜索结果")
            return

        try:
            save_options = core.SaveOptions(
                output_mode=self.name_format_var.get(),
                overwrite=bool(self.overwrite_var.get()),
                out_dir=Path(self.out_dir_var.get())
                if self.out_dir_var.get()
                else None,
                lyric_mode=self.lyric_mode_var.get(),
                include_metadata=bool(self.include_metadata_var.get()),
                strip_timestamps=bool(self.strip_timestamps_var.get()),
                strip_translation_lines=bool(self.strip_translation_var.get()),
            )

            output_path = core.save_selected_candidate(
                self.current_query,
                self.selected_candidate,
                save_options,
            )

            self.status_var.set(f"✅ 已保存：{output_path.name}")
            messagebox.showinfo("成功", f"已保存到：\n{output_path}")
        except Exception as e:
            messagebox.showerror("错误", str(e))

    def _browse_dir(self) -> None:
        """浏览输出目录"""
        path = filedialog.askdirectory(title="选择输出目录")
        if path:
            self.out_dir_var.set(path)

    def _drain_queues(self) -> None:
        """处理队列消息"""
        # 处理日志
        while True:
            try:
                self.log_queue.get_nowait()
            except queue.Empty:
                break

        # 处理 UI 事件
        while True:
            try:
                event, payload = self.ui_queue.get_nowait()
            except queue.Empty:
                break

            if event == "search_done":
                self.search_btn.configure(state="normal")
                self.result_count_var.set(f"{len(self.current_candidates)} 条结果")
                self.status_var.set("✅ 搜索完成")
                self._refresh_results()
            elif event == "search_error":
                self.search_btn.configure(state="normal")
                self.status_var.set(f"❌ {str(payload)}")
                messagebox.showerror("搜索错误", str(payload))

        self.after(100, self._drain_queues)

    def _load_file_query_and_search(self, file_path: Path) -> None:
        """从音频文件读取元数据并自动搜索"""
        query = core.read_audio_metadata(file_path)
        self._suspend_query_sync = True
        try:
            self.title_var.set(query.title)
            self.artist_var.set(query.artist)
            self.album_var.set(query.album)
            if query.duration:
                self.duration_var.set(str(query.duration))
            else:
                self.duration_var.set("")
        finally:
            self._suspend_query_sync = False

        self.status_var.set(f"✅ 已识别：{file_path.name}")
        self.current_query = query
        self.after(300, self._start_search)

    def _browse_song_and_search(self) -> None:
        """浏览歌曲文件并自动搜索歌词"""
        file_path = filedialog.askopenfilename(
            title="选择歌曲文件",
            filetypes=[
                ("音频文件", "*.mp3 *.flac *.wav *.m4a *.ogg *.aac *.wma"),
                ("所有文件", "*.*"),
            ],
        )
        if not file_path:
            return
        path_obj = Path(file_path)
        if path_obj.suffix.lower() not in core.AUDIO_EXTENSIONS:
            messagebox.showwarning("错误", "不支持的文件格式")
            return
        try:
            self._load_file_query_and_search(path_obj)
        except Exception as e:
            messagebox.showerror("错误", f"读取音频元数据失败：{e}")

    def _preview_candidate(self) -> None:
        """浏览选中候选歌词"""
        if not self.selected_candidate:
            self.preview_btn.configure(state="disabled")
            messagebox.showwarning("错误", "请先选择搜索结果")
            return

        text = core.render_lrc(
            self.selected_candidate,
            lyric_mode=self.lyric_mode_var.get(),
            include_metadata=bool(self.include_metadata_var.get()),
            strip_timestamps=bool(self.strip_timestamps_var.get()),
            strip_translation_lines=bool(self.strip_translation_var.get()),
        )

        win = ctk.CTkToplevel(self)
        win.title("KB歌词搜索 - 歌词预览")
        win.geometry("760x520")
        win.minsize(560, 380)
        win.grid_rowconfigure(0, weight=1)
        win.grid_columnconfigure(0, weight=1)

        # 确保预览窗口显示在最前并获得焦点
        win.transient(self)
        win.attributes("-topmost", True)
        win.deiconify()
        win.lift()
        win.focus_force()
        win.grab_set()
        win.after(600, lambda: win.attributes("-topmost", False))

        box = Text(win, wrap="word", font=("Consolas", 11), bg="#0f172a", fg="#e2e8f0")
        box.grid(row=0, column=0, sticky="nsew", padx=12, pady=12)
        box.insert("1.0", text if text.strip() else "（无歌词内容）")
        box.config(state="disabled")

    def _check_provider_health(self) -> None:
        """启动时检查 GUI 中配置的歌词源是否有效"""
        valid = set(core.available_providers())
        invalid = [name for name in self.provider_vars.keys() if name not in valid]

        if invalid:
            for name in invalid:
                if name in self.provider_vars:
                    self.provider_vars[name].set(False)
            self.status_var.set(f"⚠️ 已禁用无效歌词源: {', '.join(invalid)}")
        else:
            self.status_var.set("准备就绪（歌词源检查通过）")

    def _bind_query_reset_handlers(self) -> None:
        for widget, placeholder in (
            (self.title_entry, "歌曲名"),
            (self.artist_entry, "歌手"),
            (self.album_entry, "专辑"),
            (self.duration_entry, "时长(秒)"),
        ):
            widget.bind("<KeyRelease>", self._on_manual_query_input, add="+")
            widget.bind("<<Paste>>", self._on_manual_query_input, add="+")
            widget.bind("<FocusIn>", self._on_manual_query_input, add="+")
            widget.bind("<FocusOut>", self._on_manual_query_input, add="+")
            widget.configure(placeholder_text=placeholder)

        # 初始化时强制刷新占位文本，避免显示为空白
        self.title_entry.configure(placeholder_text="歌曲名")
        self.artist_entry.configure(placeholder_text="歌手")
        self.album_entry.configure(placeholder_text="专辑")
        self.duration_entry.configure(placeholder_text="时长(秒)")

    def _on_manual_query_input(self, _event=None) -> None:
        if getattr(self, "_suspend_query_sync", False):
            return
        # 用户手动修改输入时，清除旧的文件识别查询，避免搜索参数“看起来空但仍沿用旧值”
        self.current_query = None

        # 保障占位提示不会被异常状态覆盖，且空值时强制显示占位
        self.title_entry.configure(placeholder_text="歌曲名")
        self.artist_entry.configure(placeholder_text="歌手")
        self.album_entry.configure(placeholder_text="专辑")
        self.duration_entry.configure(placeholder_text="时长(秒)")

    def _settings_payload(self) -> dict:
        return {
            "providers": {k: bool(v.get()) for k, v in self.provider_vars.items()},
            "include_metadata": bool(self.include_metadata_var.get()),
            "strip_timestamps": bool(self.strip_timestamps_var.get()),
            "strip_translation": bool(self.strip_translation_var.get()),
            "overwrite": bool(self.overwrite_var.get()),
            "name_format": self.name_format_var.get(),
            "lyric_mode": self.lyric_mode_var.get(),
            "out_dir": self.out_dir_var.get(),
        }

    def _load_settings(self) -> None:
        if not SETTINGS_PATH.exists():
            return
        try:
            data = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
        except Exception:
            return

        providers = data.get("providers", {})
        if isinstance(providers, dict):
            for key, var in self.provider_vars.items():
                if key in providers:
                    var.set(bool(providers.get(key)))

        self.include_metadata_var.set(bool(data.get("include_metadata", False)))
        self.strip_timestamps_var.set(bool(data.get("strip_timestamps", False)))
        self.strip_translation_var.set(bool(data.get("strip_translation", False)))
        self.overwrite_var.set(bool(data.get("overwrite", False)))

        if data.get("name_format"):
            self.name_format_var.set(str(data.get("name_format")))
        if data.get("lyric_mode"):
            self.lyric_mode_var.set(str(data.get("lyric_mode")))
        if isinstance(data.get("out_dir"), str):
            self.out_dir_var.set(data.get("out_dir"))

    def _save_settings(self) -> None:
        try:
            SETTINGS_PATH.write_text(
                json.dumps(self._settings_payload(), ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception:
            pass

    def _on_close(self) -> None:
        self._save_settings()
        self.destroy()


def main() -> None:
    app = LyricsFetcherGUI()
    app.protocol("WM_DELETE_WINDOW", app._on_close)
    app.mainloop()


if __name__ == "__main__":
    main()

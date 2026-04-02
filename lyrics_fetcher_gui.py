#!/usr/bin/env python3
from __future__ import annotations

import os
import queue
import threading
import tkinter as tk
import traceback
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import lyrics_fetcher as core


class LyricsFetcherGUI(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("歌词抓取工具")
        self.geometry("1000x780")
        self.minsize(920, 700)

        self.log_queue: queue.Queue[str] = queue.Queue()
        self.worker_thread: threading.Thread | None = None

        self.mode_var = tk.StringVar(value="file")
        self.file_var = tk.StringVar()
        self.dir_var = tk.StringVar()
        self.title_var = tk.StringVar()
        self.artist_var = tk.StringVar()
        self.album_var = tk.StringVar()
        self.duration_var = tk.StringVar()
        self.providers_var = tk.StringVar(value="lrclib,kugou,netease,qq")
        self.out_dir_var = tk.StringVar()
        self.name_format_var = tk.StringVar(value="file")
        self.recursive_var = tk.BooleanVar(value=True)
        self.overwrite_var = tk.BooleanVar(value=False)
        self.include_metadata_var = tk.BooleanVar(value=True)
        self.dry_run_var = tk.BooleanVar(value=False)
        self.strip_timestamps_var = tk.BooleanVar(value=False)
        self.lyric_mode_var = tk.StringVar(value="auto")

        self._build_ui()
        self._set_mode()
        self.after(120, self._drain_log_queue)

    def _build_ui(self) -> None:
        outer = ttk.Frame(self, padding=12)
        outer.pack(fill=tk.BOTH, expand=True)

        title_label = ttk.Label(
            outer,
            text="歌词抓取工具",
            font=("Microsoft YaHei UI", 16, "bold"),
        )
        title_label.pack(anchor="w")

        subtitle = ttk.Label(
            outer,
            text="支持手动输入、单文件、文件夹批量；可保存带时间轴或不带时间轴歌词",
            foreground="#666666",
        )
        subtitle.pack(anchor="w", pady=(2, 12))

        self._build_mode_frame(outer)
        self._build_source_frame(outer)
        self._build_output_frame(outer)
        self._build_action_frame(outer)
        self._build_log_frame(outer)

    def _build_mode_frame(self, parent: ttk.Frame) -> None:
        frame = ttk.LabelFrame(parent, text="输入方式", padding=10)
        frame.pack(fill=tk.X, pady=(0, 10))

        mode_row = ttk.Frame(frame)
        mode_row.pack(fill=tk.X, pady=(0, 8))

        ttk.Radiobutton(
            mode_row,
            text="单文件",
            variable=self.mode_var,
            value="file",
            command=self._set_mode,
        ).pack(side=tk.LEFT, padx=(0, 12))
        ttk.Radiobutton(
            mode_row,
            text="文件夹批量",
            variable=self.mode_var,
            value="dir",
            command=self._set_mode,
        ).pack(side=tk.LEFT, padx=(0, 12))
        ttk.Radiobutton(
            mode_row,
            text="手动输入",
            variable=self.mode_var,
            value="manual",
            command=self._set_mode,
        ).pack(side=tk.LEFT)

        self.file_frame = ttk.Frame(frame)
        self.file_frame.pack(fill=tk.X, pady=4)
        ttk.Label(self.file_frame, text="音频文件", width=10).pack(side=tk.LEFT)
        ttk.Entry(self.file_frame, textvariable=self.file_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 6)
        )
        ttk.Button(self.file_frame, text="浏览", command=self._browse_file).pack(
            side=tk.LEFT
        )

        self.dir_frame = ttk.Frame(frame)
        self.dir_frame.pack(fill=tk.X, pady=4)
        ttk.Label(self.dir_frame, text="音乐目录", width=10).pack(side=tk.LEFT)
        ttk.Entry(self.dir_frame, textvariable=self.dir_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 6)
        )
        ttk.Button(self.dir_frame, text="浏览", command=self._browse_dir).pack(
            side=tk.LEFT
        )

        self.manual_frame = ttk.Frame(frame)
        self.manual_frame.pack(fill=tk.X, pady=(8, 0))

        row1 = ttk.Frame(self.manual_frame)
        row1.pack(fill=tk.X, pady=2)
        ttk.Label(row1, text="歌曲名", width=10).pack(side=tk.LEFT)
        ttk.Entry(row1, textvariable=self.title_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 10)
        )
        ttk.Label(row1, text="歌手", width=8).pack(side=tk.LEFT)
        ttk.Entry(row1, textvariable=self.artist_var, width=28).pack(side=tk.LEFT)

        row2 = ttk.Frame(self.manual_frame)
        row2.pack(fill=tk.X, pady=2)
        ttk.Label(row2, text="专辑", width=10).pack(side=tk.LEFT)
        ttk.Entry(row2, textvariable=self.album_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 10)
        )
        ttk.Label(row2, text="时长(秒)", width=8).pack(side=tk.LEFT)
        ttk.Entry(row2, textvariable=self.duration_var, width=28).pack(side=tk.LEFT)

    def _build_source_frame(self, parent: ttk.Frame) -> None:
        frame = ttk.LabelFrame(parent, text="歌词源与保存选项", padding=10)
        frame.pack(fill=tk.X, pady=(0, 10))

        row1 = ttk.Frame(frame)
        row1.pack(fill=tk.X, pady=2)
        ttk.Label(row1, text="歌词源", width=10).pack(side=tk.LEFT)
        ttk.Entry(row1, textvariable=self.providers_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        mode_row = ttk.Frame(frame)
        mode_row.pack(fill=tk.X, pady=(10, 4))
        ttk.Label(mode_row, text="歌词模式", width=10).pack(side=tk.LEFT)
        ttk.Radiobutton(
            mode_row,
            text="自动优先时间轴",
            variable=self.lyric_mode_var,
            value="auto",
        ).pack(side=tk.LEFT, padx=(0, 14))
        ttk.Radiobutton(
            mode_row,
            text="只保存时间轴歌词",
            variable=self.lyric_mode_var,
            value="synced",
        ).pack(side=tk.LEFT, padx=(0, 14))
        ttk.Radiobutton(
            mode_row,
            text="只保存无时间轴歌词",
            variable=self.lyric_mode_var,
            value="plain",
        ).pack(side=tk.LEFT)

        row2 = ttk.Frame(frame)
        row2.pack(fill=tk.X, pady=(8, 2))
        ttk.Checkbutton(
            row2,
            text="去掉时间戳后保存",
            variable=self.strip_timestamps_var,
        ).pack(side=tk.LEFT, padx=(0, 18))
        ttk.Checkbutton(
            row2,
            text="写入元数据头",
            variable=self.include_metadata_var,
        ).pack(side=tk.LEFT, padx=(0, 18))
        ttk.Checkbutton(
            row2,
            text="覆盖已存在 LRC",
            variable=self.overwrite_var,
        ).pack(side=tk.LEFT, padx=(0, 18))
        ttk.Checkbutton(
            row2,
            text="只搜索不保存",
            variable=self.dry_run_var,
        ).pack(side=tk.LEFT, padx=(0, 18))
        ttk.Checkbutton(
            row2,
            text="文件夹模式递归子目录",
            variable=self.recursive_var,
        ).pack(side=tk.LEFT)

    def _build_output_frame(self, parent: ttk.Frame) -> None:
        frame = ttk.LabelFrame(parent, text="输出设置", padding=10)
        frame.pack(fill=tk.X, pady=(0, 10))

        row1 = ttk.Frame(frame)
        row1.pack(fill=tk.X, pady=2)
        ttk.Label(row1, text="命名格式", width=10).pack(side=tk.LEFT)

        ttk.Radiobutton(
            row1,
            text="跟随音频文件名",
            variable=self.name_format_var,
            value="file",
        ).pack(side=tk.LEFT, padx=(0, 12))
        ttk.Radiobutton(
            row1,
            text="歌曲名 - 歌手",
            variable=self.name_format_var,
            value="title-artist",
        ).pack(side=tk.LEFT)

        row2 = ttk.Frame(frame)
        row2.pack(fill=tk.X, pady=(8, 2))
        ttk.Label(row2, text="输出目录", width=10).pack(side=tk.LEFT)
        ttk.Entry(row2, textvariable=self.out_dir_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 6)
        )
        ttk.Button(row2, text="浏览", command=self._browse_out_dir).pack(side=tk.LEFT)

        tip = ttk.Label(
            frame,
            text="留空则默认保存到歌曲所在目录；手动输入模式留空则保存到程序当前目录。",
            foreground="#666666",
        )
        tip.pack(anchor="w", pady=(8, 0))

    def _build_action_frame(self, parent: ttk.Frame) -> None:
        frame = ttk.Frame(parent)
        frame.pack(fill=tk.X, pady=(0, 10))

        self.start_button = ttk.Button(
            frame, text="开始处理", command=self._start_worker
        )
        self.start_button.pack(side=tk.LEFT)

        ttk.Button(frame, text="清空日志", command=self._clear_log).pack(
            side=tk.LEFT, padx=8
        )
        ttk.Button(frame, text="打开输出目录", command=self._open_output_dir).pack(
            side=tk.LEFT
        )

    def _build_log_frame(self, parent: ttk.Frame) -> None:
        frame = ttk.LabelFrame(parent, text="运行日志", padding=8)
        frame.pack(fill=tk.BOTH, expand=True)

        self.log_text = tk.Text(
            frame,
            wrap="word",
            font=("Consolas", 10),
            height=20,
        )
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        scrollbar = ttk.Scrollbar(
            frame, orient=tk.VERTICAL, command=self.log_text.yview
        )
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        self.log_text.configure(yscrollcommand=scrollbar.set)

    def _set_mode(self) -> None:
        mode = self.mode_var.get()
        self._set_widget_state(self.file_frame, mode == "file")
        self._set_widget_state(self.dir_frame, mode == "dir")
        self._set_widget_state(self.manual_frame, mode == "manual")

    def _set_widget_state(self, widget: tk.Widget, enabled: bool) -> None:
        for child in widget.winfo_children():
            self._apply_state(child, enabled)

    def _apply_state(self, widget: tk.Widget, enabled: bool) -> None:
        try:
            widget.state(["!disabled"] if enabled else ["disabled"])
        except Exception:
            try:
                widget.configure(state=tk.NORMAL if enabled else tk.DISABLED)
            except Exception:
                pass

        for child in widget.winfo_children():
            self._apply_state(child, enabled)

    def _browse_file(self) -> None:
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
            self.file_var.set(path)

    def _browse_dir(self) -> None:
        path = filedialog.askdirectory(title="选择音乐目录")
        if path:
            self.dir_var.set(path)

    def _browse_out_dir(self) -> None:
        path = filedialog.askdirectory(title="选择输出目录")
        if path:
            self.out_dir_var.set(path)

    def _open_output_dir(self) -> None:
        candidate = self.out_dir_var.get().strip()
        if not candidate:
            mode = self.mode_var.get()
            if mode == "file" and self.file_var.get().strip():
                candidate = str(
                    Path(self.file_var.get().strip()).expanduser().resolve().parent
                )
            elif mode == "dir" and self.dir_var.get().strip():
                candidate = self.dir_var.get().strip()
            else:
                candidate = str(Path.cwd())

        path = Path(candidate)
        if not path.exists():
            messagebox.showwarning("提示", f"目录不存在：\n{path}")
            return

        try:
            os.startfile(str(path))
        except Exception as exc:
            messagebox.showerror("错误", f"无法打开目录：\n{exc}")

    def _clear_log(self) -> None:
        self.log_text.delete("1.0", tk.END)

    def _append_log(self, text: str) -> None:
        self.log_text.insert(tk.END, text + "\n")
        self.log_text.see(tk.END)

    def _drain_log_queue(self) -> None:
        while True:
            try:
                line = self.log_queue.get_nowait()
            except queue.Empty:
                break
            else:
                self._append_log(line)
        self.after(120, self._drain_log_queue)

    def _start_worker(self) -> None:
        if self.worker_thread and self.worker_thread.is_alive():
            messagebox.showinfo("提示", "当前已有任务在运行。")
            return

        try:
            config = self._collect_config()
        except ValueError as exc:
            messagebox.showwarning("参数错误", str(exc))
            return

        self.start_button.state(["disabled"])
        self._append_log("=== 开始处理 ===")
        self.worker_thread = threading.Thread(
            target=self._run_task,
            args=(config,),
            daemon=True,
        )
        self.worker_thread.start()

    def _collect_config(self) -> dict:
        mode = self.mode_var.get()
        providers = [
            item.strip().lower()
            for item in self.providers_var.get().split(",")
            if item.strip()
        ]
        if not providers:
            raise ValueError("请至少填写一个歌词源。")

        out_dir_text = self.out_dir_var.get().strip()
        out_dir = Path(out_dir_text).expanduser().resolve() if out_dir_text else None

        duration = None
        duration_text = self.duration_var.get().strip()
        if duration_text:
            try:
                duration = int(duration_text)
            except ValueError as exc:
                raise ValueError("时长必须是整数秒。") from exc

        config = {
            "mode": mode,
            "providers": providers,
            "name_format": self.name_format_var.get(),
            "overwrite": self.overwrite_var.get(),
            "out_dir": out_dir,
            "dry_run": self.dry_run_var.get(),
            "recursive": self.recursive_var.get(),
            "file": self.file_var.get().strip(),
            "dir": self.dir_var.get().strip(),
            "title": self.title_var.get().strip(),
            "artist": self.artist_var.get().strip(),
            "album": self.album_var.get().strip(),
            "duration": duration,
            "lyric_mode": self.lyric_mode_var.get(),
            "include_metadata": self.include_metadata_var.get(),
            "strip_timestamps": self.strip_timestamps_var.get(),
        }

        if mode == "file":
            if not config["file"]:
                raise ValueError("请选择一个音频文件。")
        elif mode == "dir":
            if not config["dir"]:
                raise ValueError("请选择一个音乐目录。")
        elif mode == "manual":
            if not config["title"]:
                raise ValueError("手动输入模式下必须填写歌曲名。")

        return config

    def _run_task(self, config: dict) -> None:
        try:
            failed = self._dispatch_task(config)
            if failed:
                self.log_queue.put(f"[SUMMARY] 完成，但有 {failed} 项失败。")
            else:
                self.log_queue.put("[SUMMARY] 全部完成。")
        except Exception:
            self.log_queue.put("[FATAL] 程序发生未处理异常：")
            self.log_queue.put(traceback.format_exc())
        finally:
            self.after(0, lambda: self.start_button.state(["!disabled"]))

    def _dispatch_task(self, config: dict) -> int:
        mode = config["mode"]
        if mode == "file":
            path = Path(config["file"]).expanduser().resolve()
            if not path.exists():
                raise ValueError(f"文件不存在：{path}")
            query = core.read_audio_metadata(path)
            return self._process_single_query(query, config)

        if mode == "dir":
            folder = Path(config["dir"]).expanduser().resolve()
            if not folder.exists():
                raise ValueError(f"文件夹不存在：{folder}")

            files = core.find_audio_files(folder, recursive=config["recursive"])
            if not files:
                raise ValueError("没有找到支持的音频文件。")

            failed = 0
            total = len(files)
            self.log_queue.put(f"[INFO] 共找到 {total} 个音频文件。")

            for index, file_path in enumerate(files, start=1):
                self.log_queue.put(
                    f"\n=== [{index}/{total}] 处理: {file_path.name} ==="
                )
                query = core.read_audio_metadata(file_path)
                code = self._process_single_query(query, config)
                if code != 0:
                    failed += 1
            return failed

        query = core.build_manual_query(
            config["title"],
            config["artist"],
            config["album"],
            config["duration"],
        )
        return self._process_single_query(query, config)

    def _process_single_query(self, query, config: dict) -> int:
        self.log_queue.put(f"[INFO] 搜索: {query.title} / {query.artist}")

        save_options = core.SaveOptions(
            output_mode=config["name_format"],
            overwrite=config["overwrite"],
            out_dir=config["out_dir"],
            lyric_mode=config["lyric_mode"],
            include_metadata=config["include_metadata"],
            strip_timestamps=config["strip_timestamps"],
        )

        if config["dry_run"]:
            best, candidates = core.choose_best_candidate(
                query,
                config["providers"],
                prefer_synced=(
                    config["lyric_mode"] != "plain" and not config["strip_timestamps"]
                ),
                logger=self._log_from_worker,
            )
            if not best:
                self.log_queue.put(f"[FAIL] 未找到歌词: {query.title} - {query.artist}")
                return 1

            self.log_queue.put(
                f"[OK] 预览来源: {best.source} | {best.title} - {best.artist} | "
                f"synced={best.has_synced} | candidates={len(candidates)}"
            )
            return 0

        result = core.process_query(
            query,
            config["providers"],
            save_options,
            logger=self._log_from_worker,
        )

        if result.success:
            if result.output_path:
                self.log_queue.put(f"[SAVE] {result.output_path}")
            else:
                self.log_queue.put(f"[OK] {result.message}")
            return 0

        self.log_queue.put(f"[FAIL] {result.message}")
        return 1

    def _log_from_worker(self, message: str) -> None:
        self.log_queue.put(message)


def main() -> None:
    app = LyricsFetcherGUI()
    app.mainloop()


if __name__ == "__main__":
    main()

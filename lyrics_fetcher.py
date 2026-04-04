#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from difflib import SequenceMatcher
from pathlib import Path
from typing import Callable, Optional
from urllib.parse import quote

import requests
from mutagen import File as MutagenFile

VERSION = "3.0.0"
USER_AGENT = f"LyricsFetcher/{VERSION} (+local script)"

AUDIO_EXTENSIONS = {
    ".mp3",
    ".flac",
    ".m4a",
    ".aac",
    ".ogg",
    ".opus",
    ".wav",
    ".wma",
    ".ape",
    ".mp4",
}

PROVIDER_CATALOG: dict[str, dict[str, object]] = {
    "lrclib": {
        "label": "LRCLIB",
        "region": "global",
        "supports_synced": True,
        "supports_plain": True,
    },
    "lyricsovh": {
        "label": "Lyrics.ovh",
        "region": "global",
        "supports_synced": False,
        "supports_plain": True,
    },
    "kugou": {
        "label": "酷狗音乐",
        "region": "cn",
        "supports_synced": True,
        "supports_plain": True,
    },
    "kuwo": {
        "label": "酷我音乐",
        "region": "cn",
        "supports_synced": True,
        "supports_plain": True,
    },
    "netease": {
        "label": "网易云音乐",
        "region": "cn",
        "supports_synced": True,
        "supports_plain": True,
    },
    "qq": {
        "label": "QQ 音乐",
        "region": "cn",
        "supports_synced": True,
        "supports_plain": True,
    },
}

DEFAULT_PROVIDERS = ["lrclib", "lyricsovh", "kugou", "kuwo", "netease", "qq"]

SOURCE_PRIORITY = {
    "lrclib": 42,
    "kugou": 40,
    "qq": 36,
    "netease": 34,
    "kuwo": 32,
    "lyricsovh": 24,
}

SESSION = requests.Session()
SESSION.headers.update(
    {
        "User-Agent": USER_AGENT,
        "Accept": "*/*",
    }
)


@dataclass
class TrackQuery:
    title: str
    artist: str = ""
    album: str = ""
    duration: Optional[int] = None
    source_file: Optional[Path] = None
    search_variants: list[tuple[str, str]] = field(default_factory=list)


@dataclass
class LyricsCandidate:
    source: str
    title: str = ""
    artist: str = ""
    album: str = ""
    duration: Optional[int] = None
    synced_lyrics: str = ""
    plain_lyrics: str = ""
    translated_lyrics: str = ""
    score: float = 0.0
    extra: dict = field(default_factory=dict)

    @property
    def has_synced(self) -> bool:
        return bool(
            self.synced_lyrics
            and re.search(r"^\[\d{2}:\d{2}(?:\.\d{1,3})?\]", self.synced_lyrics, re.M)
        )

    @property
    def has_plain(self) -> bool:
        return bool((self.plain_lyrics or "").strip())

    @property
    def has_translation(self) -> bool:
        return bool((self.translated_lyrics or "").strip())

    @property
    def has_any(self) -> bool:
        return bool(
            (self.synced_lyrics or "").strip()
            or (self.plain_lyrics or "").strip()
            or (self.translated_lyrics or "").strip()
        )


@dataclass
class SaveOptions:
    output_mode: str = "file"
    overwrite: bool = False
    out_dir: Optional[Path] = None
    lyric_mode: str = "auto"  # auto | synced | plain
    include_metadata: bool = True
    strip_timestamps: bool = False
    strip_translation_lines: bool = False


@dataclass
class ProcessResult:
    query: TrackQuery
    success: bool
    message: str
    candidate: Optional[LyricsCandidate] = None
    output_path: Optional[Path] = None
    candidates: list[LyricsCandidate] = field(default_factory=list)


@dataclass
class ProviderSearchStatus:
    provider: str
    ok: bool = False
    result_count: int = 0
    error: str = ""
    timed_out: bool = False


@dataclass
class SearchResultBundle:
    query: TrackQuery
    providers: list[str]
    all_candidates: list[LyricsCandidate] = field(default_factory=list)
    grouped_candidates: dict[str, list[LyricsCandidate]] = field(default_factory=dict)
    provider_status: dict[str, ProviderSearchStatus] = field(default_factory=dict)
    best_candidate: Optional[LyricsCandidate] = None


Logger = Optional[Callable[[str], None]]


def default_logger(message: str) -> None:
    print(message)


def provider_label(provider: str) -> str:
    info = PROVIDER_CATALOG.get(provider, {})
    return str(info.get("label") or provider)


def available_providers() -> list[str]:
    return list(PROVIDER_CATALOG.keys())


def sanitize_filename(name: str) -> str:
    name = re.sub(r'[<>:"/\\|?*]', "_", (name or "")).strip()
    name = re.sub(r"\s+", " ", name)
    return name[:180] or "lyrics"


def normalize_text(text: str) -> str:
    text = (text or "").strip().lower()
    text = re.sub(r"\([^)]*\)", " ", text)
    text = re.sub(r"\[[^\]]*\]", " ", text)
    text = re.sub(r"[^\w\u4e00-\u9fff\u3040-\u30ff]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def similarity(a: str, b: str) -> float:
    a = normalize_text(a)
    b = normalize_text(b)
    if not a or not b:
        return 0.0
    return SequenceMatcher(None, a, b).ratio()


def safe_json_from_jsonp(text: str):
    text = text.strip()
    if text.startswith("{") or text.startswith("["):
        return json.loads(text)
    match = re.search(r"^[^(]+\((.*)\)\s*;?\s*$", text, re.S)
    if match:
        return json.loads(match.group(1))
    raise ValueError("Unable to parse JSON/JSONP response")


def first_tag(tags: dict, *keys: str) -> str:
    for key in keys:
        value = tags.get(key)
        if isinstance(value, list) and value:
            return str(value[0]).strip()
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def parse_filename_variants(stem: str) -> list[tuple[str, str]]:
    stem = stem.strip()
    variants: list[tuple[str, str]] = [(stem, "")]
    separators = [" - ", " — ", " – ", "-", "—", "–"]

    for sep in separators:
        if sep in stem:
            left, right = stem.split(sep, 1)
            left = left.strip()
            right = right.strip()
            if left and right:
                variants.append((right, left))
                variants.append((left, right))
                break

    dedup: list[tuple[str, str]] = []
    seen = set()
    for title, artist in variants:
        key = (title.strip().lower(), artist.strip().lower())
        if key not in seen:
            dedup.append((title, artist))
            seen.add(key)
    return dedup


def read_audio_metadata(path: Path) -> TrackQuery:
    title = ""
    artist = ""
    album = ""
    duration = None

    try:
        audio = MutagenFile(path, easy=True)
        if audio:
            tags = dict(audio.tags or {})
            title = first_tag(tags, "title")
            artist = first_tag(tags, "artist", "albumartist")
            album = first_tag(tags, "album")
            info = getattr(audio, "info", None)
            if info and getattr(info, "length", None):
                duration = int(round(info.length))
    except Exception:
        pass

    if not title:
        title = path.stem

    variants = parse_filename_variants(path.stem)
    if artist and title:
        variants.insert(0, (title, artist))

    dedup: list[tuple[str, str]] = []
    seen = set()
    for t, a in variants:
        key = (t.strip().lower(), a.strip().lower())
        if key not in seen:
            dedup.append((t, a))
            seen.add(key)

    return TrackQuery(
        title=title.strip(),
        artist=artist.strip(),
        album=album.strip(),
        duration=duration,
        source_file=path,
        search_variants=dedup,
    )


def build_manual_query(
    title: str,
    artist: str = "",
    album: str = "",
    duration: Optional[int] = None,
) -> TrackQuery:
    title = title.strip()
    artist = artist.strip()
    variants = [(title, artist)]
    if not artist:
        variants.extend(parse_filename_variants(title))

    dedup: list[tuple[str, str]] = []
    seen = set()
    for t, a in variants:
        key = (t.strip().lower(), a.strip().lower())
        if key not in seen:
            dedup.append((t, a))
            seen.add(key)

    return TrackQuery(
        title=title,
        artist=artist,
        album=album.strip(),
        duration=duration,
        source_file=None,
        search_variants=dedup,
    )


def try_request(method: str, url: str, *, timeout: int = 8, **kwargs):
    response = SESSION.request(method, url, timeout=timeout, **kwargs)
    response.raise_for_status()
    return response


def score_candidate(query: TrackQuery, cand: LyricsCandidate) -> float:
    score = SOURCE_PRIORITY.get(cand.source, 0)
    score += 100 if cand.has_synced else 12
    score += 6 if cand.has_translation else 0

    if query.title:
        score += similarity(query.title, cand.title or query.title) * 40
    if query.artist:
        score += similarity(query.artist, cand.artist or query.artist) * 25
    if query.album and cand.album:
        score += similarity(query.album, cand.album) * 10

    if query.duration and cand.duration:
        diff = abs(query.duration - cand.duration)
        if diff <= 2:
            score += 15
        elif diff <= 5:
            score += 8
        elif diff <= 12:
            score += 3

    return score


def is_timestamped_lyric(text: str) -> bool:
    return bool(re.search(r"^\[\d{2}:\d{2}(?:\.\d{1,3})?\]", text or "", re.M))


def remove_lrc_timestamps(text: str) -> str:
    lines = []
    for raw_line in (text or "").splitlines():
        line = raw_line.strip("\ufeff")
        line = re.sub(r"^\[(?:ar|ti|al|by|offset):.*?\]\s*$", "", line, flags=re.I)
        line = re.sub(r"(?:\[\d{2}:\d{2}(?:\.\d{1,3})?\])+", "", line).strip()
        if line:
            lines.append(line)
    return "\n".join(lines)


def clean_plain_lyrics(text: str) -> str:
    lines = [line.rstrip() for line in (text or "").splitlines()]
    lines = [line for line in lines if line.strip()]
    return "\n".join(lines)


def candidate_best_text(candidate: LyricsCandidate, lyric_mode: str) -> str:
    lyric_mode = (lyric_mode or "auto").lower()

    if lyric_mode == "synced":
        return (candidate.synced_lyrics or "").strip()

    if lyric_mode == "plain":
        if candidate.plain_lyrics.strip():
            return clean_plain_lyrics(candidate.plain_lyrics)
        return remove_lrc_timestamps(candidate.synced_lyrics)

    if candidate.has_synced:
        return (candidate.synced_lyrics or "").strip()
    if candidate.plain_lyrics.strip():
        return clean_plain_lyrics(candidate.plain_lyrics)
    return remove_lrc_timestamps(candidate.synced_lyrics)


def render_lrc(
    candidate: LyricsCandidate,
    *,
    lyric_mode: str = "auto",
    include_metadata: bool = True,
    strip_timestamps: bool = False,
    strip_translation_lines: bool = False,
) -> str:
    body = candidate_best_text(candidate, lyric_mode)

    if strip_timestamps and body:
        body = remove_lrc_timestamps(body)

    body = clean_plain_lyrics(body) if not is_timestamped_lyric(body) else body.strip()

    if strip_translation_lines and body and (candidate.translated_lyrics or "").strip():
        # Only remove lines that are known to come from translated_lyrics.
        # This avoids accidentally deleting original lyric lines.
        translated_lines = {
            normalize_text(re.sub(r"^\[\d{2}:\d{2}(?:\.\d{1,3})?\]\s*", "", line))
            for line in candidate.translated_lyrics.splitlines()
            if line.strip()
        }
        translated_lines.discard("")

        if translated_lines:
            filtered_lines: list[str] = []
            for line in body.splitlines():
                norm = normalize_text(
                    re.sub(r"^\[\d{2}:\d{2}(?:\.\d{1,3})?\]\s*", "", line)
                )
                if norm and norm in translated_lines:
                    continue
                filtered_lines.append(line)
            body = "\n".join(filtered_lines).strip()

    header: list[str] = []
    if include_metadata:
        if candidate.title:
            header.append(f"[ti:{candidate.title}]")
        if candidate.artist:
            header.append(f"[ar:{candidate.artist}]")
        if candidate.album:
            header.append(f"[al:{candidate.album}]")
        header.append("[by:KBlrc_fetcher]")

    if header:
        return "\n".join(header + [""] + body.splitlines()) + "\n"
    return body.strip() + ("\n" if body.strip() else "")


def choose_output_filename(
    candidate: LyricsCandidate,
    query: TrackQuery,
    output_mode: str,
) -> str:
    if query.source_file and output_mode == "file":
        return f"{query.source_file.stem}.lrc"

    title = (
        candidate.title
        or query.title
        or (query.source_file.stem if query.source_file else "lyrics")
    )
    artist = candidate.artist or query.artist

    if output_mode == "title-artist" and artist:
        return f"{sanitize_filename(title)} - {sanitize_filename(artist)}.lrc"
    if output_mode == "title-artist":
        return f"{sanitize_filename(title)}.lrc"

    if query.source_file:
        return f"{query.source_file.stem}.lrc"
    if artist:
        return f"{sanitize_filename(title)} - {sanitize_filename(artist)}.lrc"
    return f"{sanitize_filename(title)}.lrc"


def save_lyrics(
    candidate: LyricsCandidate,
    query: TrackQuery,
    options: SaveOptions,
) -> Path:
    if query.source_file:
        song_dir = query.source_file.parent
    else:
        song_dir = Path.cwd()

    target_dir = options.out_dir or song_dir
    target_dir.mkdir(parents=True, exist_ok=True)

    filename = choose_output_filename(candidate, query, options.output_mode)
    out_path = target_dir / filename

    if out_path.exists() and not options.overwrite:
        raise FileExistsError(f"文件已存在: {out_path}")

    content = render_lrc(
        candidate,
        lyric_mode=options.lyric_mode,
        include_metadata=options.include_metadata,
        strip_timestamps=options.strip_timestamps,
        strip_translation_lines=options.strip_translation_lines,
    )
    out_path.write_text(content, encoding="utf-8-sig")
    return out_path


def save_selected_candidate(
    query: TrackQuery,
    candidate: LyricsCandidate,
    save_options: SaveOptions,
) -> Path:
    return save_lyrics(candidate, query, save_options)


def deduplicate_candidates(
    candidates: list[LyricsCandidate],
    query: Optional[TrackQuery] = None,
) -> list[LyricsCandidate]:
    best_by_key: dict[tuple[str, str, str, str], LyricsCandidate] = {}

    for cand in candidates:
        lyrics_hint = ""
        body = cand.synced_lyrics or cand.plain_lyrics or cand.translated_lyrics or ""
        for line in body.splitlines():
            line = line.strip()
            if line:
                lyrics_hint = normalize_text(line)[:80]
                break

        fallback_title = cand.title or (query.title if query else "")
        fallback_artist = cand.artist or (query.artist if query else "")

        key = (
            cand.source,
            normalize_text(fallback_title),
            normalize_text(fallback_artist),
            lyrics_hint,
        )

        existing = best_by_key.get(key)
        if existing is None or cand.score > existing.score:
            best_by_key[key] = cand

    result = list(best_by_key.values())
    result.sort(key=lambda item: item.score, reverse=True)
    return result


def rank_and_deduplicate_candidates(
    candidates: list[LyricsCandidate],
    query: TrackQuery,
) -> list[LyricsCandidate]:
    for cand in candidates:
        cand.score = score_candidate(query, cand)
    return deduplicate_candidates(candidates, query=query)


def get_candidate_preview(
    candidate: LyricsCandidate,
    query: TrackQuery,
    save_options: SaveOptions,
) -> dict[str, object]:
    filename = choose_output_filename(candidate, query, save_options.output_mode)
    text = render_lrc(
        candidate,
        lyric_mode=save_options.lyric_mode,
        include_metadata=save_options.include_metadata,
        strip_timestamps=save_options.strip_timestamps,
        strip_translation_lines=save_options.strip_translation_lines,
    )
    return {
        "provider": candidate.source,
        "provider_label": provider_label(candidate.source),
        "title": candidate.title or query.title,
        "artist": candidate.artist or query.artist,
        "album": candidate.album or query.album,
        "duration": candidate.duration or query.duration,
        "has_synced": candidate.has_synced,
        "has_plain": candidate.has_plain,
        "has_translation": candidate.has_translation,
        "preview_text": text,
        "suggested_filename": filename,
    }


def parse_kuwo_search_response(text: str) -> list[dict]:
    text = (text or "").strip()
    if not text:
        return []

    if text.startswith("{") and "abslist" in text:
        try:
            data = json.loads(text)
            return data.get("abslist") or []
        except Exception:
            pass

    match = re.search(r"'abslist'\s*:\s*(\[[\s\S]*\])", text)
    if not match:
        match = re.search(r'"abslist"\s*:\s*(\[[\s\S]*\])', text)
    if not match:
        return []

    abslist_text = match.group(1)

    try:
        fixed = abslist_text.replace("'", '"')
        fixed = re.sub(r",\s*([}\]])", r"\1", fixed)
        data = json.loads(fixed)
        return data if isinstance(data, list) else []
    except Exception:
        pass

    results: list[dict] = []
    for obj_text in re.findall(r"\{[\s\S]*?\}", abslist_text):
        item: dict[str, str] = {}
        for key, value in re.findall(r"'([^']+)'\s*:\s*'([^']*)'", obj_text):
            item[key] = value
        if item:
            results.append(item)
    return results


def parse_kuwo_song_xml(xml_text: str) -> dict[str, str]:
    root = ET.fromstring(xml_text)
    data: dict[str, str] = {}
    for child in root:
        tag = (child.tag or "").strip()
        data[tag] = (child.text or "").strip()
    return data


def search_lrclib(query: TrackQuery) -> list[LyricsCandidate]:
    results: list[LyricsCandidate] = []

    if query.title and query.artist and query.album and query.duration:
        try:
            response = try_request(
                "GET",
                "https://lrclib.net/api/get",
                params={
                    "track_name": query.title,
                    "artist_name": query.artist,
                    "album_name": query.album,
                    "duration": query.duration,
                },
                headers={"User-Agent": USER_AGENT},
            )
            data = response.json()
            results.append(
                LyricsCandidate(
                    source="lrclib",
                    title=data.get("trackName", ""),
                    artist=data.get("artistName", ""),
                    album=data.get("albumName", ""),
                    duration=data.get("duration"),
                    synced_lyrics=data.get("syncedLyrics", "") or "",
                    plain_lyrics=data.get("plainLyrics", "") or "",
                )
            )
        except Exception:
            pass

    for title, artist in query.search_variants:
        try:
            response = try_request(
                "GET",
                "https://lrclib.net/api/search",
                params={
                    "track_name": title,
                    "artist_name": artist,
                    "album_name": query.album,
                },
                headers={"User-Agent": USER_AGENT},
            )
            data = response.json()
            if isinstance(data, list):
                for item in data[:6]:
                    results.append(
                        LyricsCandidate(
                            source="lrclib",
                            title=item.get("trackName", ""),
                            artist=item.get("artistName", ""),
                            album=item.get("albumName", ""),
                            duration=item.get("duration"),
                            synced_lyrics=item.get("syncedLyrics", "") or "",
                            plain_lyrics=item.get("plainLyrics", "") or "",
                        )
                    )
        except Exception:
            continue

    return [item for item in results if item.has_any]


def search_lyricsovh(query: TrackQuery) -> list[LyricsCandidate]:
    results: list[LyricsCandidate] = []

    for title, artist in query.search_variants:
        if not title:
            continue

        try:
            if artist:
                response = try_request(
                    "GET",
                    f"https://api.lyrics.ovh/v1/{quote(artist)}/{quote(title)}",
                    headers={"User-Agent": USER_AGENT},
                )
                data = response.json()
                lyrics = data.get("lyrics", "") or ""
                if lyrics.strip():
                    results.append(
                        LyricsCandidate(
                            source="lyricsovh",
                            title=title,
                            artist=artist,
                            album=query.album,
                            duration=query.duration,
                            plain_lyrics=clean_plain_lyrics(lyrics),
                        )
                    )
                    continue
        except Exception:
            pass

        try:
            keyword = " ".join(part for part in [artist, title] if part).strip()
            suggest_response = try_request(
                "GET",
                f"https://api.lyrics.ovh/suggest/{quote(keyword or title)}",
                headers={"User-Agent": USER_AGENT},
            )
            suggest_data = suggest_response.json()
            items = (suggest_data.get("data") or [])[:5]

            for item in items:
                cand_title = item.get("title", "") or title
                artist_obj = item.get("artist") or {}
                cand_artist = (
                    artist_obj.get("name", "")
                    if isinstance(artist_obj, dict)
                    else artist
                )
                if not cand_title or not cand_artist:
                    continue

                try:
                    lyric_response = try_request(
                        "GET",
                        f"https://api.lyrics.ovh/v1/{quote(cand_artist)}/{quote(cand_title)}",
                        headers={"User-Agent": USER_AGENT},
                    )
                    lyric_data = lyric_response.json()
                    lyrics = lyric_data.get("lyrics", "") or ""
                    if lyrics.strip():
                        results.append(
                            LyricsCandidate(
                                source="lyricsovh",
                                title=cand_title,
                                artist=cand_artist,
                                album=query.album,
                                plain_lyrics=clean_plain_lyrics(lyrics),
                            )
                        )
                except Exception:
                    continue
        except Exception:
            continue

    return [item for item in results if item.has_any]


def search_kugou(query: TrackQuery) -> list[LyricsCandidate]:
    results: list[LyricsCandidate] = []
    headers = {"Referer": "https://www.kugou.com/", "User-Agent": USER_AGENT}

    for title, artist in query.search_variants:
        keyword = f"{artist} - {title}".strip(" -")
        if not keyword:
            continue

        songs: list[dict] = []

        # endpoint 1: mobilecdn
        try:
            response = try_request(
                "GET",
                "https://mobilecdn.kugou.com/api/v3/search/song",
                params={
                    "format": "json",
                    "keyword": keyword,
                    "page": 1,
                    "pagesize": 10,
                    "showtype": 1,
                },
                headers=headers,
            )
            data = response.json()
            songs.extend((((data or {}).get("data") or {}).get("info") or [])[:8])
        except Exception:
            pass

        # endpoint 2: legacy search api fallback
        if not songs:
            try:
                response = try_request(
                    "GET",
                    "https://songsearch.kugou.com/song_search_v2",
                    params={
                        "keyword": keyword,
                        "page": 1,
                        "pagesize": 10,
                        "platform": "WebFilter",
                        "tag": "em",
                    },
                    headers=headers,
                )
                data = response.json()
                songs.extend((((data or {}).get("data") or {}).get("lists") or [])[:8])
            except Exception:
                pass

        for song in songs:
            song_hash = (
                song.get("hash")
                or song.get("FileHash")
                or song.get("320hash")
                or song.get("sqhash")
            )
            if not song_hash:
                continue

            duration_ms = ""
            duration_sec = None
            duration_val = song.get("duration") or song.get("Duration")
            if duration_val:
                try:
                    duration_sec = int(duration_val)
                    duration_ms = duration_sec * 1000
                except Exception:
                    duration_sec = None
                    duration_ms = ""

            candidates = []
            try:
                candidate_response = try_request(
                    "GET",
                    "https://krcs.kugou.com/search",
                    params={
                        "ver": 1,
                        "man": "yes",
                        "client": "mobi",
                        "keyword": keyword,
                        "duration": duration_ms,
                        "hash": song_hash,
                        "album_audio_id": song.get("album_audio_id", ""),
                    },
                    headers=headers,
                )
                candidate_data = candidate_response.json()
                candidates = (candidate_data or {}).get("candidates") or []
            except Exception:
                candidates = []

            if not candidates:
                continue

            # try several candidate rows for better compatibility
            for item in candidates[:3]:
                content = ""
                try:
                    lyric_response = try_request(
                        "GET",
                        "https://lyrics.kugou.com/download",
                        params={
                            "ver": 1,
                            "client": "pc",
                            "id": item.get("id"),
                            "accesskey": item.get("accesskey"),
                            "fmt": "lrc",
                            "charset": "utf8",
                        },
                        headers=headers,
                    )
                    lyric_data = lyric_response.json()
                    content = lyric_data.get("content", "") or ""
                except Exception:
                    content = ""

                if not content:
                    continue

                try:
                    decoded = base64.b64decode(content).decode("utf-8", errors="ignore")
                except Exception:
                    decoded = content

                decoded = (decoded or "").strip()
                if not decoded:
                    continue

                results.append(
                    LyricsCandidate(
                        source="kugou",
                        title=song.get("songname") or song.get("SongName") or title,
                        artist=song.get("singername")
                        or song.get("SingerName")
                        or artist,
                        album=song.get("album_name") or song.get("AlbumName") or "",
                        duration=duration_sec,
                        synced_lyrics=decoded,
                        plain_lyrics=remove_lrc_timestamps(decoded),
                    )
                )
                break

    return [item for item in results if item.has_any]


def search_kuwo(query: TrackQuery) -> list[LyricsCandidate]:
    results: list[LyricsCandidate] = []
    headers = {"Referer": "https://www.kuwo.cn/", "User-Agent": USER_AGENT}

    for title, artist in query.search_variants:
        keyword = " ".join(part for part in [title, artist] if part).strip()
        if not keyword:
            continue

        songs: list[dict] = []

        # endpoint 1: legacy search
        try:
            response = try_request(
                "GET",
                "https://search.kuwo.cn/r.s",
                params={
                    "all": keyword,
                    "ft": "music",
                    "itemset": "web_2013",
                    "client": "kt",
                    "pn": 0,
                    "rn": 8,
                    "rformat": "json",
                    "encoding": "utf8",
                },
                headers=headers,
            )
            songs.extend(parse_kuwo_search_response(response.text)[:8])
        except Exception:
            pass

        # endpoint 2: www search fallback
        if not songs:
            try:
                response = try_request(
                    "GET",
                    "https://www.kuwo.cn/api/www/search/searchMusicBykeyWord",
                    params={
                        "key": keyword,
                        "pn": 1,
                        "rn": 10,
                        "httpsStatus": 1,
                    },
                    headers={**headers, "csrf": "", "Cookie": "kw_token="},
                )
                data = response.json()
                songs.extend((((data or {}).get("data") or {}).get("list") or [])[:8])
            except Exception:
                pass

        for song in songs:
            rid = song.get("MUSICRID") or song.get("rid") or song.get("musicrid") or ""
            rid = str(rid).replace("MUSIC_", "").strip()
            if not rid:
                continue

            synced = ""
            translated = ""
            song_data: dict[str, str] = {}

            # primary metadata endpoint
            try:
                song_response = try_request(
                    "GET",
                    "https://player.kuwo.cn/webmusic/st/getNewMuiseByRid",
                    params={"rid": rid},
                    headers=headers,
                )
                song_data = parse_kuwo_song_xml(song_response.text)
            except Exception:
                song_data = {}

            lrc_key = song_data.get("lyric", "")
            trans_key = song_data.get("lyric_zz", "")

            if lrc_key:
                try:
                    lrc_response = try_request(
                        "GET",
                        f"https://newlyric.kuwo.cn/newlyric.lrc?{lrc_key}",
                        headers=headers,
                    )
                    synced = lrc_response.text.strip()
                except Exception:
                    synced = ""

            if trans_key:
                try:
                    trans_response = try_request(
                        "GET",
                        f"https://newlyric.kuwo.cn/newlyric.lrc?{trans_key}",
                        headers=headers,
                    )
                    translated = trans_response.text.strip()
                except Exception:
                    translated = ""

            # fallback lyric endpoint for many tracks
            if not synced and not translated:
                try:
                    lrc_api = try_request(
                        "GET",
                        "https://m.kuwo.cn/newh5/singles/songinfoandlrc",
                        params={"musicId": rid},
                        headers=headers,
                    )
                    lrc_data = lrc_api.json()
                    lrclist = (
                        ((lrc_data or {}).get("data") or {}).get("lrclist")
                    ) or []
                    if isinstance(lrclist, list) and lrclist:
                        synced_lines: list[str] = []
                        for row in lrclist:
                            line = (row.get("lineLyric") or "").strip()
                            tval = str(row.get("time") or "0").strip()
                            if not line:
                                continue
                            try:
                                sec = float(tval)
                            except Exception:
                                sec = 0.0
                            mm = int(sec // 60)
                            ss = sec - mm * 60
                            synced_lines.append(f"[{mm:02d}:{ss:05.2f}]{line}")
                        synced = "\n".join(synced_lines).strip()
                except Exception:
                    pass

            if not synced and not translated:
                continue

            duration = None
            duration_raw = (
                song.get("DURATION")
                or song_data.get("songTimeMinutes")
                or song.get("duration")
                or song.get("songTimeMinutes")
            )
            if duration_raw:
                if str(duration_raw).isdigit():
                    duration = int(duration_raw)
                else:
                    time_match = re.match(r"(\d+):(\d+)", str(duration_raw))
                    if time_match:
                        duration = int(time_match.group(1)) * 60 + int(
                            time_match.group(2)
                        )

            results.append(
                LyricsCandidate(
                    source="kuwo",
                    title=song.get("SONGNAME")
                    or song.get("name")
                    or song_data.get("name")
                    or title,
                    artist=song.get("ARTIST")
                    or song.get("artist")
                    or song_data.get("artist")
                    or artist,
                    album=song.get("ALBUM")
                    or song.get("album")
                    or song_data.get("special")
                    or "",
                    duration=duration,
                    synced_lyrics=synced,
                    plain_lyrics=remove_lrc_timestamps(synced)
                    if synced
                    else clean_plain_lyrics(translated),
                    translated_lyrics=translated,
                )
            )

    return [item for item in results if item.has_any]


def search_netease(query: TrackQuery) -> list[LyricsCandidate]:
    results: list[LyricsCandidate] = []
    headers = {"Referer": "https://music.163.com/", "User-Agent": USER_AGENT}

    for title, artist in query.search_variants:
        keyword = f"{title} {artist}".strip()
        if not keyword:
            continue

        try:
            response = try_request(
                "GET",
                "https://music.163.com/api/search/get/web",
                params={
                    "s": keyword,
                    "type": 1,
                    "offset": 0,
                    "limit": 8,
                },
                headers=headers,
            )
            data = response.json()
            songs = (((data or {}).get("result") or {}).get("songs") or [])[:5]

            for song in songs:
                song_id = song.get("id")
                if not song_id:
                    continue

                lyric_response = try_request(
                    "GET",
                    "https://music.163.com/api/song/lyric",
                    params={
                        "id": song_id,
                        "lv": -1,
                        "kv": -1,
                        "tv": -1,
                    },
                    headers=headers,
                )
                lyric_data = lyric_response.json()
                lrc = (((lyric_data or {}).get("lrc") or {}).get("lyric")) or ""
                tlyric = (((lyric_data or {}).get("tlyric") or {}).get("lyric")) or ""
                if not lrc and not tlyric:
                    continue

                artists = ", ".join(
                    item.get("name", "")
                    for item in song.get("artists", [])
                    if item.get("name")
                )
                album = ((song.get("album") or {}).get("name")) or ""
                duration = (
                    int(round((song.get("duration") or 0) / 1000))
                    if song.get("duration")
                    else None
                )

                results.append(
                    LyricsCandidate(
                        source="netease",
                        title=song.get("name") or title,
                        artist=artists or artist,
                        album=album,
                        duration=duration,
                        synced_lyrics=lrc,
                        translated_lyrics=tlyric,
                        plain_lyrics=remove_lrc_timestamps(lrc)
                        if lrc
                        else clean_plain_lyrics(tlyric),
                    )
                )
        except Exception:
            continue

    return [item for item in results if item.has_any]


def search_qq(query: TrackQuery) -> list[LyricsCandidate]:
    results: list[LyricsCandidate] = []
    headers = {"Referer": "https://y.qq.com/", "User-Agent": USER_AGENT}

    for title, artist in query.search_variants:
        keyword = f"{title} {artist}".strip()
        if not keyword:
            continue

        songs: list[dict] = []

        # endpoint 1: classic search
        try:
            response = try_request(
                "GET",
                "https://c.y.qq.com/soso/fcgi-bin/client_search_cp",
                params={
                    "ct": 24,
                    "qqmusic_ver": 1298,
                    "new_json": 1,
                    "remoteplace": "txt.yqq.song",
                    "searchid": 0,
                    "t": 0,
                    "aggr": 1,
                    "cr": 1,
                    "catZhida": 1,
                    "lossless": 0,
                    "flag_qc": 0,
                    "p": 1,
                    "n": 10,
                    "w": keyword,
                    "g_tk": 5381,
                    "format": "json",
                    "inCharset": "utf8",
                    "outCharset": "utf-8",
                    "notice": 0,
                    "platform": "yqq.json",
                    "needNewCode": 0,
                },
                headers=headers,
            )
            data = safe_json_from_jsonp(response.text)
            songs.extend(
                (
                    (((data or {}).get("data") or {}).get("song") or {}).get("list")
                    or []
                )[:8]
            )
        except Exception:
            pass

        # endpoint 2: smartbox fallback
        if not songs:
            try:
                response = try_request(
                    "GET",
                    "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg",
                    params={
                        "key": keyword,
                        "format": "json",
                        "inCharset": "utf-8",
                        "outCharset": "utf-8",
                        "platform": "yqq.json",
                        "g_tk": 5381,
                    },
                    headers=headers,
                )
                data = safe_json_from_jsonp(response.text)
                songs.extend(
                    (
                        (((data or {}).get("data") or {}).get("song") or {}).get(
                            "itemlist"
                        )
                        or []
                    )[:8]
                )
            except Exception:
                pass

        for song in songs:
            songmid = song.get("mid") or song.get("songmid")
            if not songmid:
                continue

            lrc = ""
            trans = ""

            # endpoint A: json lyric with plain text
            try:
                lyric_response = try_request(
                    "GET",
                    "https://i.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                    params={
                        "songmid": songmid,
                        "format": "json",
                        "nobase64": 1,
                        "g_tk": 5381,
                        "inCharset": "utf-8",
                        "outCharset": "utf-8",
                        "notice": 0,
                        "platform": "yqq.json",
                        "needNewCode": 0,
                    },
                    headers=headers,
                )
                lyric_data = safe_json_from_jsonp(lyric_response.text)
                lrc = lyric_data.get("lyric", "") or ""
                trans = lyric_data.get("trans", "") or ""
            except Exception:
                lrc = ""
                trans = ""

            # endpoint B: fallback base64 lyric
            if not lrc and not trans:
                try:
                    lyric_response = try_request(
                        "GET",
                        "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric.fcg",
                        params={
                            "songmid": songmid,
                            "format": "json",
                            "nobase64": 0,
                            "platform": "yqq",
                            "g_tk": 5381,
                        },
                        headers=headers,
                    )
                    lyric_data = safe_json_from_jsonp(lyric_response.text)
                    lrc_b64 = lyric_data.get("lyric", "") or ""
                    trans_b64 = lyric_data.get("trans", "") or ""
                    if lrc_b64:
                        try:
                            lrc = base64.b64decode(lrc_b64).decode(
                                "utf-8", errors="ignore"
                            )
                        except Exception:
                            lrc = ""
                    if trans_b64:
                        try:
                            trans = base64.b64decode(trans_b64).decode(
                                "utf-8", errors="ignore"
                            )
                        except Exception:
                            trans = ""
                except Exception:
                    pass

            if not lrc and not trans:
                continue

            singers = ", ".join(
                item.get("name", "")
                for item in song.get("singer", [])
                if isinstance(item, dict) and item.get("name")
            )
            if not singers and song.get("singer"):
                singers = str(song.get("singer"))

            album = (
                (song.get("album") or {}).get("name", "")
                if isinstance(song.get("album"), dict)
                else (song.get("albumName") or "")
            )
            interval = song.get("interval")
            duration = int(interval) if str(interval).isdigit() else None

            results.append(
                LyricsCandidate(
                    source="qq",
                    title=song.get("title") or song.get("name") or title,
                    artist=singers or artist,
                    album=album,
                    duration=duration,
                    synced_lyrics=lrc,
                    translated_lyrics=trans,
                    plain_lyrics=remove_lrc_timestamps(lrc)
                    if lrc
                    else clean_plain_lyrics(trans),
                )
            )

    return [item for item in results if item.has_any]


PROVIDER_FUNCS: dict[str, Callable[[TrackQuery], list[LyricsCandidate]]] = {
    "lrclib": search_lrclib,
    "lyricsovh": search_lyricsovh,
    "kugou": search_kugou,
    "kuwo": search_kuwo,
    "netease": search_netease,
    "qq": search_qq,
}


def search_single_provider(
    query: TrackQuery,
    provider: str,
) -> tuple[list[LyricsCandidate], ProviderSearchStatus]:
    func = PROVIDER_FUNCS.get(provider)
    status = ProviderSearchStatus(provider=provider)

    if not func:
        status.error = "未知歌词源"
        return [], status

    try:
        items = func(query)
        status.ok = True
        status.result_count = len(items)
        return items, status
    except Exception as exc:
        status.error = str(exc)
        return [], status


def collect_candidates(
    query: TrackQuery,
    providers: list[str],
    logger: Logger = None,
) -> list[LyricsCandidate]:
    log = logger or (lambda _: None)
    candidates: list[LyricsCandidate] = []

    for provider in providers:
        func = PROVIDER_FUNCS.get(provider)
        if not func:
            log(f"[WARN] 未知歌词源: {provider}")
            continue

        log(f"[INFO] 搜索 {provider_label(provider)}: {query.title} / {query.artist}")
        try:
            items = func(query)
            for item in items:
                item.score = score_candidate(query, item)
                candidates.append(item)
            log(f"[INFO] {provider_label(provider)} 返回 {len(items)} 条结果")
        except Exception as exc:
            log(f"[WARN] {provider_label(provider)} 搜索失败: {exc}")

    candidates = deduplicate_candidates(candidates, query=query)
    candidates.sort(key=lambda item: item.score, reverse=True)
    return candidates


def search_candidates_by_source(
    query: TrackQuery,
    providers: list[str],
    prefer_synced: bool = True,
    logger: Logger = None,
    max_duration_sec: float = 15.0,
) -> SearchResultBundle:
    log = logger or (lambda _: None)
    normalized_providers = [p for p in providers if p in PROVIDER_FUNCS]
    bundle = SearchResultBundle(query=query, providers=normalized_providers)

    all_items: list[LyricsCandidate] = []
    provider_items: dict[str, list[LyricsCandidate]] = {
        provider: [] for provider in normalized_providers
    }

    if not normalized_providers:
        bundle.all_candidates = []
        bundle.grouped_candidates = {}
        return bundle

    start_ts = time.monotonic()
    max_workers = min(6, max(1, len(normalized_providers)))

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_provider = {}
        for provider in normalized_providers:
            log(
                f"[INFO] 搜索 {provider_label(provider)}: {query.title} / {query.artist}"
            )
            future = executor.submit(search_single_provider, query, provider)
            future_to_provider[future] = provider

        completed = set()
        remaining = set(future_to_provider.keys())

        while remaining:
            elapsed = time.monotonic() - start_ts
            remaining_time = max_duration_sec - elapsed
            if remaining_time <= 0:
                break

            try:
                done_batch = next(iter(as_completed(remaining, timeout=remaining_time)))
            except Exception:
                break

            provider = future_to_provider[done_batch]
            remaining.remove(done_batch)
            completed.add(done_batch)

            try:
                items, status = done_batch.result()
            except Exception as exc:
                items = []
                status = ProviderSearchStatus(
                    provider=provider, error=str(exc), ok=False
                )

            bundle.provider_status[provider] = status
            provider_items[provider] = list(items)

            if status.error:
                log(f"[WARN] {provider_label(provider)} 搜索失败: {status.error}")
            else:
                log(f"[INFO] {provider_label(provider)} 返回 {len(items)} 条结果")

            for item in items:
                item.score = score_candidate(query, item)
                all_items.append(item)

        # 超时未完成的 provider 标记为 timed_out
        for future in remaining:
            provider = future_to_provider[future]
            future.cancel()
            timeout_status = ProviderSearchStatus(
                provider=provider,
                ok=False,
                result_count=0,
                error=f"provider timeout (> {max_duration_sec:.1f}s overall)",
                timed_out=True,
            )
            bundle.provider_status[provider] = timeout_status
            provider_items[provider] = []
            log(f"[WARN] {provider_label(provider)} 超时，已跳过")

    ranked = rank_and_deduplicate_candidates(all_items, query)
    grouped: dict[str, list[LyricsCandidate]] = {}
    for provider in normalized_providers:
        grouped[provider] = [item for item in ranked if item.source == provider]

    bundle.all_candidates = ranked
    bundle.grouped_candidates = grouped

    if ranked:
        if prefer_synced:
            synced = [item for item in ranked if item.has_synced]
            bundle.best_candidate = synced[0] if synced else ranked[0]
        else:
            bundle.best_candidate = ranked[0]

    return bundle


def choose_best_candidate(
    query: TrackQuery,
    providers: list[str],
    prefer_synced: bool = True,
    logger: Logger = None,
) -> tuple[Optional[LyricsCandidate], list[LyricsCandidate]]:
    bundle = search_candidates_by_source(
        query,
        providers,
        prefer_synced=prefer_synced,
        logger=logger,
    )
    return bundle.best_candidate, bundle.all_candidates


def find_audio_files(path: Path, recursive: bool = True) -> list[Path]:
    if path.is_file():
        return [path] if path.suffix.lower() in AUDIO_EXTENSIONS else []
    globber = path.rglob if recursive else path.glob
    return sorted(
        item
        for item in globber("*")
        if item.is_file() and item.suffix.lower() in AUDIO_EXTENSIONS
    )


def process_query(
    query: TrackQuery,
    providers: list[str],
    save_options: SaveOptions,
    logger: Logger = None,
) -> ProcessResult:
    log = logger or (lambda _: None)
    prefer_synced = (
        save_options.lyric_mode != "plain" and not save_options.strip_timestamps
    )
    bundle = search_candidates_by_source(
        query,
        providers,
        prefer_synced=prefer_synced,
        logger=logger,
    )
    best = bundle.best_candidate
    candidates = bundle.all_candidates

    if not best:
        return ProcessResult(
            query=query,
            success=False,
            message=f"未找到歌词: {query.title} - {query.artist}",
            candidates=[],
        )

    log(
        f"[OK] 选中来源: {provider_label(best.source)} | "
        f"{best.title} - {best.artist} | synced={best.has_synced}"
    )

    try:
        output_path = save_selected_candidate(query, best, save_options)
    except FileExistsError as exc:
        return ProcessResult(
            query=query,
            success=False,
            message=str(exc),
            candidate=best,
            candidates=candidates,
        )
    except Exception as exc:
        return ProcessResult(
            query=query,
            success=False,
            message=f"保存失败: {exc}",
            candidate=best,
            candidates=candidates,
        )

    return ProcessResult(
        query=query,
        success=True,
        message=f"已保存: {output_path}",
        candidate=best,
        output_path=output_path,
        candidates=candidates,
    )


def process_file(
    file_path: Path,
    providers: list[str],
    save_options: SaveOptions,
    logger: Logger = None,
) -> ProcessResult:
    query = read_audio_metadata(file_path)
    return process_query(query, providers, save_options, logger=logger)


def process_directory(
    directory: Path,
    providers: list[str],
    save_options: SaveOptions,
    *,
    recursive: bool = True,
    logger: Logger = None,
) -> list[ProcessResult]:
    files = find_audio_files(directory, recursive=recursive)
    results: list[ProcessResult] = []

    for index, file_path in enumerate(files, start=1):
        if logger:
            logger(f"\n=== [{index}/{len(files)}] 处理: {file_path.name} ===")
        results.append(process_file(file_path, providers, save_options, logger=logger))

    return results


def parse_provider_list(raw: str) -> list[str]:
    providers = [
        item.strip().lower() for item in (raw or "").split(",") if item.strip()
    ]
    normalized = [item for item in providers if item in PROVIDER_FUNCS]
    return normalized or list(DEFAULT_PROVIDERS)


def build_save_options_from_args(args: argparse.Namespace) -> SaveOptions:
    lyric_mode = args.lyric_mode
    strip_timestamps = bool(args.strip_timestamps)

    if args.unsynced_only:
        lyric_mode = "plain"
        strip_timestamps = True

    out_dir = Path(args.out_dir).expanduser().resolve() if args.out_dir else None

    return SaveOptions(
        output_mode=args.name_format,
        overwrite=args.overwrite,
        out_dir=out_dir,
        lyric_mode=lyric_mode,
        include_metadata=not args.no_metadata,
        strip_timestamps=strip_timestamps,
    )


def create_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="自动搜索歌词并保存为 LRC")
    parser.add_argument("--title", help="歌曲名")
    parser.add_argument("--artist", default="", help="歌手名")
    parser.add_argument("--album", default="", help="专辑名")
    parser.add_argument("--duration", type=int, default=None, help="时长(秒)")
    parser.add_argument("--file", help="单个音频文件路径")
    parser.add_argument("--dir", help="批量处理文件夹")
    parser.add_argument(
        "--providers",
        default=",".join(DEFAULT_PROVIDERS),
        help="歌词源，逗号分隔",
    )
    parser.add_argument(
        "--name-format",
        choices=["file", "title-artist"],
        default="file",
        help="输出文件名格式",
    )
    parser.add_argument("--overwrite", action="store_true", help="覆盖已存在的 LRC")
    parser.add_argument("--out-dir", help="指定输出目录；默认保存到歌曲所在目录")
    parser.add_argument(
        "--non-recursive",
        action="store_true",
        help="文件夹模式下不递归子目录",
    )
    parser.add_argument("--dry-run", action="store_true", help="只搜索不保存")
    parser.add_argument(
        "--lyric-mode",
        choices=["auto", "synced", "plain"],
        default="auto",
        help="歌词保存模式：自动/仅时间轴/仅纯文本",
    )
    parser.add_argument(
        "--strip-timestamps",
        action="store_true",
        help="保存前去掉时间戳",
    )
    parser.add_argument(
        "--unsynced-only",
        action="store_true",
        help="等价于 --lyric-mode plain --strip-timestamps",
    )
    parser.add_argument(
        "--no-metadata",
        action="store_true",
        help="不写入 [ti]/[ar]/[al]/[by] 头信息",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {VERSION}",
    )
    return parser


def cli_out(message: str, *, error: bool = False) -> None:
    print(message, file=sys.stderr if error else sys.stdout)


def cli_print_result(result: ProcessResult) -> None:
    prefix = "[OK]" if result.success else "[FAIL]"
    cli_out(f"{prefix} {result.message}", error=not result.success)


def cli_print_preview(best: LyricsCandidate, candidates: list[LyricsCandidate]) -> None:
    cli_out(
        f"[OK] 预览来源: {provider_label(best.source)} | "
        f"{best.title} - {best.artist} | synced={best.has_synced} | "
        f"candidates={len(candidates)}"
    )


def main(argv: Optional[list[str]] = None) -> int:
    parser = create_argument_parser()
    args = parser.parse_args(argv)

    providers = parse_provider_list(args.providers)
    save_options = build_save_options_from_args(args)

    if args.file:
        file_path = Path(args.file).expanduser().resolve()
        if not file_path.exists():
            cli_out(f"[ERROR] 文件不存在: {file_path}", error=True)
            return 2

        query = read_audio_metadata(file_path)
        cli_out(f"[INFO] 搜索: {query.title} / {query.artist}")

        if args.dry_run:
            best, candidates = choose_best_candidate(
                query,
                providers,
                prefer_synced=(
                    save_options.lyric_mode != "plain"
                    and not save_options.strip_timestamps
                ),
                logger=default_logger,
            )
            if not best:
                cli_out(
                    f"[FAIL] 未找到歌词: {query.title} - {query.artist}", error=True
                )
                return 1
            cli_print_preview(best, candidates)
            return 0

        result = process_query(query, providers, save_options, logger=default_logger)
        cli_print_result(result)
        return 0 if result.success else 1

    if args.dir:
        directory = Path(args.dir).expanduser().resolve()
        if not directory.exists():
            cli_out(f"[ERROR] 文件夹不存在: {directory}", error=True)
            return 2

        files = find_audio_files(directory, recursive=not args.non_recursive)
        if not files:
            cli_out("[ERROR] 没找到音频文件", error=True)
            return 2

        cli_out(f"[INFO] 共找到 {len(files)} 个音频文件")
        failed = 0

        for index, file_path in enumerate(files, start=1):
            cli_out(f"\n=== [{index}/{len(files)}] 处理: {file_path.name} ===")
            query = read_audio_metadata(file_path)
            cli_out(f"[INFO] 搜索: {query.title} / {query.artist}")

            if args.dry_run:
                best, candidates = choose_best_candidate(
                    query,
                    providers,
                    prefer_synced=(
                        save_options.lyric_mode != "plain"
                        and not save_options.strip_timestamps
                    ),
                    logger=default_logger,
                )
                if not best:
                    cli_out(
                        f"[FAIL] 未找到歌词: {query.title} - {query.artist}",
                        error=True,
                    )
                    failed += 1
                    continue
                cli_print_preview(best, candidates)
                continue

            result = process_query(
                query, providers, save_options, logger=default_logger
            )
            cli_print_result(result)
            if not result.success:
                failed += 1

        if failed:
            cli_out(f"\n[SUMMARY] 完成，但有 {failed} 项失败。", error=True)
            return 1

        cli_out("\n[SUMMARY] 全部完成。")
        return 0

    if args.title:
        query = build_manual_query(
            args.title,
            artist=args.artist,
            album=args.album,
            duration=args.duration,
        )
        cli_out(f"[INFO] 搜索: {query.title} / {query.artist}")

        if args.dry_run:
            best, candidates = choose_best_candidate(
                query,
                providers,
                prefer_synced=(
                    save_options.lyric_mode != "plain"
                    and not save_options.strip_timestamps
                ),
                logger=default_logger,
            )
            if not best:
                cli_out(
                    f"[FAIL] 未找到歌词: {query.title} - {query.artist}", error=True
                )
                return 1
            cli_print_preview(best, candidates)
            return 0

        result = process_query(query, providers, save_options, logger=default_logger)
        cli_print_result(result)
        return 0 if result.success else 1

    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

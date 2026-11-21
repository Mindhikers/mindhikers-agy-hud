#!/usr/bin/env python3
"""Read-only telemetry aggregator for MindHikers AGY HUD.

Reads local Antigravity conversation SQLite databases and annotations read-only.
Zero network calls, zero Keychain/OAuth access, zero writes to Antigravity files.

Builds on context_report.py (MIT License, dimitr-io/antigravity-desktop-context).
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import sys
import tempfile

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import context_report as cr  # noqa: E402

CATEGORY_ZH = {
    "user": "用户消息",
    "agent": "Agent 回复",
    "tool": "工具调用",
    "system_prompt": "系统提示词",
    "system_tools": "内置工具",
    "rules": "Rules 规则",
    "skills": "Skills 技能",
    "subagents": "子智能体",
    "legacy_workflows": "旧工作流",
    "workflows": "工作流",
    "plugins": "插件",
    "mcp_tools": "MCP 工具",
    "system_messages": "系统消息",
    "system_overhead": "系统开销",
}

RE_TITLE = re.compile(r'title:"((?:[^"\\]|\\.)*)"')
RE_VIEW_TIME = re.compile(r'last_user_view_time:\{[^}]*seconds:(\d+)(?:\s+nanos:(\d+))?')


def unescape_pbtxt_string(raw: str) -> str:
    try:
        return bytes(raw, "utf-8").decode("unicode_escape").encode("latin1").decode("utf-8")
    except Exception:
        return raw.replace('\\"', '"').replace("\\\\", "\\")


def read_annotations(annotations_dir: Path) -> dict[str, dict]:
    """Read last_user_view_time and official title from ~/.gemini/antigravity/annotations/*.pbtxt."""
    result: dict[str, dict] = {}
    if not annotations_dir.is_dir():
        return result
    for p in annotations_dir.glob("*.pbtxt"):
        cid = p.stem
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
            st_mtime = p.stat().st_mtime
        except OSError:
            continue
        title = ""
        m_title = RE_TITLE.search(text)
        if m_title:
            title = unescape_pbtxt_string(m_title.group(1)).strip()
        view_ts = 0.0
        m_vt = RE_VIEW_TIME.search(text)
        if m_vt:
            secs = int(m_vt.group(1))
            nanos = int(m_vt.group(2) or 0)
            view_ts = secs + nanos / 1e9
        result[cid] = {
            "title": title,
            "view_ts": max(view_ts, 0.0),
            "file_mtime": st_mtime,
        }
    return result


def effective_mtime(db_path: Path) -> float:
    mt = db_path.stat().st_mtime
    wal = Path(f"{db_path}-wal")
    if wal.is_file():
        try:
            mt = max(mt, wal.stat().st_mtime)
        except OSError:
            pass
    return mt


def db_fingerprint(db_path: Path) -> str:
    parts = []
    for p in (db_path, Path(f"{db_path}-wal")):
        try:
            st = p.stat()
            parts.append(f"{st.st_mtime_ns}:{st.st_size}")
        except OSError:
            parts.append("-")
    return "|".join(parts)


@contextmanager
def open_readonly_db(db_path: Path):
    """Open an Antigravity SQLite DB safely without ever mutating original files."""
    conn = None
    try:
        conn = sqlite3.connect(f"file:{db_path.as_posix()}?mode=ro", uri=True, timeout=1.5)
        conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
    except sqlite3.Error:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass
            conn = None

    if conn is not None:
        try:
            yield conn
        finally:
            conn.close()
        return

    wal = Path(f"{db_path}-wal")
    has_wal_data = False
    try:
        has_wal_data = wal.is_file() and wal.stat().st_size > 0
    except OSError:
        has_wal_data = False

    if not has_wal_data:
        conn = sqlite3.connect(
            f"file:{db_path.as_posix()}?mode=ro&immutable=1", uri=True, timeout=1.5
        )
        try:
            yield conn
        finally:
            conn.close()
        return

    with tempfile.TemporaryDirectory(prefix="agyhud-") as td:
        tmp_db = Path(td) / db_path.name
        shutil.copy2(db_path, tmp_db)
        shutil.copy2(wal, Path(f"{tmp_db}-wal"))
        conn = sqlite3.connect(tmp_db.as_posix(), timeout=2.0)
        try:
            yield conn
        finally:
            conn.close()


def load_from_conn(conn: sqlite3.Connection) -> tuple[list[cr.Step], cr.Msg | None]:
    rows = conn.execute(
        "SELECT idx, step_type, status, metadata, step_payload FROM steps ORDER BY idx"
    ).fetchall()
    steps = [cr.Step(pos, r[4] or b"", r[1], r[2], r[3]) for pos, r in enumerate(rows)]
    row = conn.execute("SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 1").fetchone()
    return steps, (cr.Msg(row[0]) if row else None)


def extract_title(conn: sqlite3.Connection, fallback: str) -> str:
    try:
        rows = conn.execute(
            "SELECT step_payload FROM steps WHERE step_payload IS NOT NULL ORDER BY idx ASC LIMIT 24"
        ).fetchall()
    except sqlite3.Error:
        return fallback
    for (payload,) in rows:
        if not payload:
            continue
        msg = cr.Msg(payload)
        ui = msg.msg(cr.STEP_USER_INPUT)
        if ui is not None:
            raw = ui.str(2).strip()
            if raw:
                one_line = " ".join(raw.split())
                if len(one_line) > 34:
                    return one_line[:33] + "…"
                return one_line
    return fallback


def scan_session_totals(conn: sqlite3.Connection) -> dict:
    tot_in = 0
    tot_out = 0
    tot_cache = 0
    tot_cw = 0
    gens = 0
    try:
        rows = conn.execute(
            "SELECT data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx ASC"
        ).fetchall()
    except sqlite3.Error:
        rows = []
    for (blob,) in rows:
        if not blob:
            continue
        gens += 1
        wrapped = cr.Msg(blob).msg(1)
        if wrapped is None:
            continue
        usage = wrapped.msg(4)
        if usage is None:
            continue
        raw_in = max(0, usage.int(2))
        raw_out = max(0, usage.int(3))
        raw_cw = max(0, usage.int(4))
        raw_cache = max(0, usage.int(5))
        tot_in += raw_in
        tot_out += raw_out
        tot_cw += raw_cw
        tot_cache += raw_cache
    denom = tot_in + tot_cache + tot_cw
    cache_hit_pct = round((tot_cache / denom) * 100.0, 1) if denom > 0 else 0.0
    return {
        "generations": gens,
        "input_tokens": tot_in,
        "output_tokens": tot_out,
        "cached_tokens": tot_cache,
        "cache_write_tokens": tot_cw,
        "total_tokens": tot_in + tot_out + tot_cache + tot_cw,
        "cache_hit_pct": cache_hit_pct,
    }


def list_recent(conv_dir: Path, annotations: dict[str, dict], limit: int = 8) -> list[dict]:
    if not conv_dir.is_dir():
        return []
    candidates = []
    for p in conv_dir.glob("*.db"):
        cid = p.stem
        try:
            db_mt = effective_mtime(p)
        except OSError:
            continue
        ann = annotations.get(cid)
        view_ts = ann["view_ts"] if ann else 0.0
        # Rank by most recently viewed in Antigravity UI OR most recently modified DB
        sort_ts = max(db_mt, view_ts)
        candidates.append((sort_ts, view_ts, db_mt, p))
    candidates.sort(key=lambda item: (item[0], item[1], item[2]), reverse=True)
    result = []
    for sort_ts, _vt, _mt, p in candidates[:limit]:
        cid = p.stem
        ann = annotations.get(cid)
        title = (ann["title"] if ann and ann.get("title") else "")
        if not title:
            title = cid[:8]
            try:
                with open_readonly_db(p) as conn:
                    title = extract_title(conn, cid[:8])
            except (sqlite3.Error, OSError):
                pass
        if len(title) > 36:
            title = title[:35] + "…"
        result.append({
            "id": cid,
            "title": title,
            "updated_at_ms": int(sort_ts * 1000),
        })
    return result


def build_payload(
    conv_dir: Path,
    conv_id: str | None,
    recent_limit: int = 8,
    annotations_dir: Path | None = None,
) -> dict:
    ann_dir = annotations_dir if annotations_dir is not None else conv_dir.parent / "annotations"
    annotations = read_annotations(ann_dir)
    recent = list_recent(conv_dir, annotations, recent_limit)
    if not recent and not conv_id:
        return {"status": "empty", "message": "未找到本地 Antigravity 对话记录", "recent_conversations": []}

    target_id = conv_id or recent[0]["id"]
    db_path = conv_dir / f"{target_id}.db"
    if not db_path.is_file():
        if recent:
            target_id = recent[0]["id"]
            db_path = conv_dir / f"{target_id}.db"
        else:
            return {"status": "empty", "message": "对话数据库不存在", "recent_conversations": recent}

    try:
        with open_readonly_db(db_path) as conn:
            steps, gen = load_from_conn(conn)
            ann = annotations.get(target_id)
            title = (ann["title"] if ann and ann.get("title") else "") or extract_title(conn, target_id[:8])
            totals = scan_session_totals(conn)
    except (sqlite3.Error, OSError) as exc:
        return {
            "status": "error",
            "message": f"无法读取该会话记录：{exc}",
            "conversation_id": target_id,
            "recent_conversations": recent,
        }

    limit = cr.context_limit(gen)
    st = cr.collect_stats(steps, gen, limit)
    model = cr.model_name(gen)
    budget = cr.request_budget(gen)

    user_turns = sum(1 for s in steps if s.payload(cr.STEP_USER_INPUT) is not None)
    last_status = steps[-1].status if steps else cr.STATUS_DONE
    is_running = last_status in (1, 2)

    used = st["total"]
    used_pct = round(min(100.0, cr.pct(used, limit)), 1) if limit > 0 else 0.0
    budget_pct = round(min(100.0, cr.pct(used, budget)), 1) if budget > 0 else 0.0
    over_budget = budget > 0 and used >= budget

    ck_view = cr.checkpoint_view(st)
    ck_count = ck_view["count"] if ck_view else 0

    categories = []
    for icon, name, key, always in cr.CATEGORIES:
        if always or st[key]:
            categories.append({
                "key": key,
                "name": name,
                "name_zh": CATEGORY_ZH.get(key, name),
                "tokens": st[key],
                "pct": round(cr.pct(st[key], limit), 1) if limit > 0 else 0.0,
            })

    system_files = cr.detect_system_files(os.path.expanduser("~"), None, "antigravity")
    text_report = cr.render(st, model, system_files, 100, False)

    return {
        "status": "ok",
        "conversation_id": target_id,
        "title": title,
        "fingerprint": db_fingerprint(db_path),
        "updated_at_ms": int(effective_mtime(db_path) * 1000),
        "model": model,
        "model_id": cr.model_id(gen),
        "used_tokens": used,
        "limit_tokens": limit,
        "used_pct": used_pct,
        "free_tokens": max(0, limit - used),
        "request_budget_tokens": budget,
        "budget_pct": budget_pct,
        "over_budget": over_budget,
        "has_breakdown": st["has_breakdown"],
        "compacted": st["compacted"],
        "checkpoint_count": ck_count,
        "checkpoint_buffer": st["checkpoint"],
        "checkpoint_active_text": ck_view["active_text"] if ck_view else "",
        "user_turns": user_turns,
        "total_steps": len(steps),
        "is_running": is_running,
        "session_totals": totals,
        "categories": categories,
        "recent_conversations": recent,
        "text_report": text_report,
    }


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description="Read-only telemetry parser for MindHikers AGY HUD.")
    parser.add_argument("--conversation-id", default=None, help="Pinned conversation UUID (auto-latest if omitted)")
    parser.add_argument("--conversations-dir", default=None, help="Override conversations directory")
    parser.add_argument("--annotations-dir", default=None, help="Override annotations directory")
    parser.add_argument("--recent-limit", type=int, default=8, help="Max recent conversations to list")
    args = parser.parse_args()

    conv_dir = (
        Path(args.conversations_dir).expanduser()
        if args.conversations_dir
        else Path.home() / ".gemini" / "antigravity" / "conversations"
    )
    ann_dir = Path(args.annotations_dir).expanduser() if args.annotations_dir else None
    payload = build_payload(conv_dir, args.conversation_id, args.recent_limit, ann_dir)
    print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()

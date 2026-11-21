from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
PARSER = ROOT / "Resources" / "hud_parser.py"


def varint(n: int) -> bytes:
    n &= 0xFFFFFFFFFFFFFFFF
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def field(fn: int, val) -> bytes:
    if isinstance(val, int):
        return varint(fn << 3) + varint(val)
    if isinstance(val, str):
        val = val.encode("utf-8")
    return varint((fn << 3) | 2) + varint(len(val)) + val


def build_synthetic_db(path: Path, prompt_text: str) -> None:
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, "
        "status integer NOT NULL DEFAULT 3, metadata blob, step_payload blob)"
    )
    conn.execute(
        "CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob, size integer NOT NULL DEFAULT 0)"
    )
    user_payload = field(19, field(2, prompt_text))
    conn.execute(
        "INSERT INTO steps (idx, step_type, status, metadata, step_payload) VALUES (0, 14, 3, ?, ?)",
        (b"", user_payload),
    )
    conn.execute(
        "INSERT INTO steps (idx, step_type, status, metadata, step_payload) VALUES (1, 15, 2, ?, ?)",
        (b"", b""),
    )

    # TopLevelTokenGroup: Chat Messages (type=7) with 120000 tokens
    item = field(1, "0: USER_INPUT") + field(3, 120000)
    group = field(1, "Chat Messages") + field(2, 7) + field(4, 120000) + field(5, item)
    cwm = field(1, 120000) + field(3, field(1, group)) + field(4, 256000)
    start = field(10, cwm)
    usage = field(2, 12000) + field(3, 5000) + field(5, 108000)
    chat = field(4, usage) + field(9, start) + field(21, "Gemini 4 Test (High)")
    planner = field(28, "gemini-4-test-high")
    gen = field(1, chat) + field(3, planner)
    conn.execute("INSERT INTO gen_metadata (idx, data, size) VALUES (0, ?, ?)", (gen, len(gen)))
    conn.commit()
    conn.close()


class TestHudParser(unittest.TestCase):
    def test_synthetic_conversation_payload(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            conv_dir = Path(td)
            cid = "11111111-2222-3333-4444-555555555555"
            build_synthetic_db(conv_dir / f"{cid}.db", "检查上下文水位")

            out = subprocess.check_output(
                [sys.executable, str(PARSER), "--conversations-dir", str(conv_dir)],
                text=True,
            )
            data = json.loads(out)
            self.assertEqual(data["status"], "ok")
            self.assertEqual(data["conversation_id"], cid)
            self.assertEqual(data["title"], "检查上下文水位")
            self.assertEqual(data["model"], "Gemini 4 Test (High)")
            self.assertEqual(data["used_tokens"], 120000)
            self.assertEqual(data["request_budget_tokens"], 256000)
            self.assertFalse(data["over_budget"])
            self.assertEqual(data["user_turns"], 1)
            self.assertTrue(data["is_running"])
            self.assertAlmostEqual(data["session_totals"]["cache_hit_pct"], 90.0, places=1)
            self.assertEqual(len(data["recent_conversations"]), 1)

    def test_closed_wal_db_without_shm(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            conv_dir = Path(td)
            cid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            db_path = conv_dir / f"{cid}.db"
            build_synthetic_db(db_path, "已关闭的 WAL 历史会话")
            # Enable WAL mode and close cleanly so no -shm/-wal remains
            conn = sqlite3.connect(db_path)
            conn.execute("PRAGMA journal_mode=WAL;")
            conn.commit()
            conn.close()
            for suffix in ("-shm", "-wal"):
                extra = Path(f"{db_path}{suffix}")
                if extra.exists():
                    extra.unlink()

            out = subprocess.check_output(
                [sys.executable, str(PARSER), "--conversations-dir", str(conv_dir), "--conversation-id", cid],
                text=True,
            )
            data = json.loads(out)
            self.assertEqual(data["status"], "ok")
            self.assertEqual(data["title"], "已关闭的 WAL 历史会话")
            self.assertEqual(data["used_tokens"], 120000)

    def test_annotation_view_time_tracks_switched_conversation(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            conv_dir = root / "conversations"
            ann_dir = root / "annotations"
            conv_dir.mkdir()
            ann_dir.mkdir()
            c1 = "11111111-1111-1111-1111-111111111111"
            c2 = "22222222-2222-2222-2222-222222222222"
            build_synthetic_db(conv_dir / f"{c1}.db", "老会话")
            build_synthetic_db(conv_dir / f"{c2}.db", "新会话")
            # Simulate user clicking c1 later in Antigravity UI via annotations last_user_view_time
            (ann_dir / f"{c1}.pbtxt").write_text(
                'title:"Switched Official Title" last_user_view_time:{seconds:2999999999 nanos:0}',
                encoding="utf-8",
            )
            out = subprocess.check_output(
                [sys.executable, str(PARSER), "--conversations-dir", str(conv_dir), "--annotations-dir", str(ann_dir)],
                text=True,
            )
            data = json.loads(out)
            self.assertEqual(data["status"], "ok")
            self.assertEqual(data["conversation_id"], c1)
            self.assertEqual(data["title"], "Switched Official Title")

    def test_empty_directory(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out = subprocess.check_output(
                [sys.executable, str(PARSER), "--conversations-dir", td],
                text=True,
            )
            data = json.loads(out)
            self.assertEqual(data["status"], "empty")


if __name__ == "__main__":
    unittest.main()

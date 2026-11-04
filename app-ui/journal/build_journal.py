#!/usr/bin/env python3
"""Turn everything in docs/ into journal.json for the Journal page.

    python3 build_journal.py <docs-dir> <out.json>

Runs at image build time (app-ui/Dockerfile), so a new or changed file in docs/ reaches
the site with the next pipeline run. Standard library only.

Supported: .docx, .md, .txt. Each file becomes a "chapter"; each section at the file's most
common heading level becomes an "entry", tagged with an emoji (what kind of problem) and a
status (fixed / open / false alarm / noted). Unsupported or unreadable files are skipped
with a warning, never fatal: a bad doc must not break the site build.

The site may be public, so text is redacted before it leaves the build: private IPs,
SSH keys, long hex strings (tokens, fingerprints), password assignments and emails.
"""
import json
import re
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

MAX_BYTES = 5 * 1024 * 1024
W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"

# ---------------------------------------------------------------- redaction
REDACT = [
    (re.compile(r"\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b|\b192\.168\.\d{1,3}\.\d{1,3}\b"
                r"|\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b"), "‹private-ip›"),
    (re.compile(r"\bssh-(?:ed25519|rsa|dss)\s+AAAA[0-9A-Za-z+/=]+(?:\s+\S+)?"), "‹ssh-key›"),
    (re.compile(r"-----BEGIN [A-Z ]+-----.*?-----END [A-Z ]+-----", re.S), "‹key›"),
    (re.compile(r"(?i)\b(password|passwd|secret|token)(\s*[:=]\s*)(?!\s)(?!make\b)[^\s,;'\"]{6,}"),
     r"\1\2‹redacted›"),
    (re.compile(r"\b[0-9a-f]{32,}\b"), "‹hex›"),
    (re.compile(r"\b[0-9a-f]{8,}…"), "‹hex›"),
    (re.compile(r"\bSHA256:[A-Za-z0-9+/]{20,}={0,2}"), "‹fingerprint›"),
    (re.compile(r"(?:[0-9A-F]{2}:){15,}[0-9A-F]{2}"), "‹fingerprint›"),
    (re.compile(r"\b[\w.+-]+@(?!github\.com\b)[\w-]+\.[\w.-]+\b"), "‹email›"),
]


def redact(text: str) -> str:
    for pattern, repl in REDACT:
        text = pattern.sub(repl, text)
    return text


# ---------------------------------------------------------------- readers -> blocks
# block: {"t": "h", "level": n, "text"} | {"t": "label", "text"} | {"t": "p", "text"}
#        {"t": "li", "text"} | {"t": "code", "text"} | {"t": "row", "cells": [...]}

def read_docx(path: Path) -> list[dict]:
    with zipfile.ZipFile(path) as z:
        root = ET.fromstring(z.read("word/document.xml"))
    body = root.find(f"{W}body")
    blocks: list[dict] = []
    code: list[str] = []

    def flush_code():
        if code:
            blocks.append({"t": "code", "text": "\n".join(code).rstrip()})
            code.clear()

    def para_text(p) -> str:
        return "".join(t.text or "" for t in p.iter(f"{W}t"))

    for el in body:
        if el.tag == f"{W}tbl":
            flush_code()
            for tr in el.iter(f"{W}tr"):
                cells = [" ".join(para_text(p) for p in tc.iter(f"{W}p")).strip() for tc in tr.iter(f"{W}tc")]
                blocks.append({"t": "row", "cells": cells})
            blocks.append({"t": "tblend"})
            continue
        if el.tag != f"{W}p":
            continue
        style_el = el.find(f"{W}pPr/{W}pStyle")
        style = style_el.get(f"{W}val") if style_el is not None else ""
        text = para_text(el)
        if style == "Code":
            code.append(text)
            continue
        flush_code()
        if not text.strip():
            continue
        if style == "Title":
            blocks.append({"t": "h", "level": 0, "text": text})
        elif style.startswith("Heading") and style[7:].isdigit():
            blocks.append({"t": "h", "level": int(style[7:]), "text": text})
        elif style == "Label":
            blocks.append({"t": "label", "text": text})
        elif style.startswith("List"):
            blocks.append({"t": "li", "text": text})
        else:
            blocks.append({"t": "p", "text": text})
    flush_code()
    return blocks


def read_md(path: Path) -> list[dict]:
    blocks: list[dict] = []
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("```"):
            j = i + 1
            while j < len(lines) and not lines[j].startswith("```"):
                j += 1
            blocks.append({"t": "code", "text": "\n".join(lines[i + 1:j]).rstrip()})
            i = j + 1
            continue
        m = re.match(r"^(#{1,6})\s+(.*)", line)
        if m:
            blocks.append({"t": "h", "level": len(m.group(1)) - 1, "text": m.group(2)})
        elif line.strip().startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if not all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
                blocks.append({"t": "row", "cells": cells})
            if not (i + 1 < len(lines) and lines[i + 1].strip().startswith("|")):
                blocks.append({"t": "tblend"})
        elif re.match(r"^\s*([-*]|\d+\.)\s+", line):
            blocks.append({"t": "li", "text": re.sub(r"^\s*([-*]|\d+\.)\s+", "", line)})
        elif line.strip() and not re.fullmatch(r"\s*-{3,}\s*", line):
            blocks.append({"t": "p", "text": line.strip()})
        i += 1
    return blocks


FIELD = re.compile(r"^\s*([A-Z][A-Za-z /]{1,24}):\s+(.*)")   # "Cause:   text" (short label)


def read_txt(path: Path) -> list[dict]:
    """Plain text conventions: a line underlined with === or --- is a heading; a numbered
    line at column 0 ("3. Title") starts an entry; "Field: text" lines are labelled fields
    and indented lines continue them; aligned tables are kept as preformatted text."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    blocks: list[dict] = []
    table: list[str] = []

    def flush_table():
        if table:
            blocks.append({"t": "code", "text": "\n".join(table).rstrip()})
            table.clear()

    i = 0
    while i < len(lines):
        line, nxt = lines[i], lines[i + 1] if i + 1 < len(lines) else ""
        if line.strip() and re.fullmatch(r"=+", nxt.strip() or "x"):
            flush_table(); blocks.append({"t": "h", "level": 0, "text": line.strip()}); i += 2; continue
        if line.strip() and re.fullmatch(r"-{3,}", nxt.strip() or "x"):
            flush_table(); blocks.append({"t": "h", "level": 1, "text": line.strip()}); i += 2; continue
        m = re.match(r"^(\d+)\.\s+(\S.*)", line)
        if m:
            flush_table(); blocks.append({"t": "h", "level": 2, "text": m.group(2), "num": m.group(1)}); i += 1; continue
        if re.match(r"^\s*(#|-{2,}\s{2,})", line) or "  " in line.strip() and not FIELD.match(line):
            if line.strip():
                table.append(line)
            i += 1
            continue
        flush_table()
        f = FIELD.match(line)
        if f:
            text = [f.group(2)]
            while i + 1 < len(lines) and re.match(r"^\s{6,}\S", lines[i + 1]) \
                    and not FIELD.match(lines[i + 1]):
                i += 1
                text.append(lines[i].strip())
            blocks.append({"t": "label", "text": f.group(1)})
            blocks.append({"t": "p", "text": " ".join(text)})
        elif re.match(r"^\s*-\s+", line):
            blocks.append({"t": "li", "text": re.sub(r"^\s*-\s+", "", line)})
        elif line.strip():
            blocks.append({"t": "p", "text": line.strip()})
        i += 1
    flush_table()
    return blocks


READERS = {".docx": read_docx, ".md": read_md, ".txt": read_txt}

# ---------------------------------------------------------------- blocks -> entries
KINDS = [  # first match wins: (emoji, kind, pattern); tried on the title first, then the body
    ("🕵️", "false alarm", r"false alarm"),
    ("🧱", "design", r"design decision|blocked by policy"),
    ("🐢", "slow", r"\bslow\b|minutes per|takes about"),
    ("🔒", "access denied", r"permission denied|publickey|forbidden|apparmor|unauthori[sz]ed"),
    ("🔑", "keys", r"ssh key|deploy key"),
    ("💥", "crash", r"crash|bootfailure|exited with|\boom\b|oomkilled|\bkilled\b"),
    ("⏳", "timeout", r"timed out|timeout|deadline exceeded"),
    ("🛡️", "vulnerability", r"\bcve-|vulnerab|trivy"),
    ("🧭", "not found", r"\b404\b|not found|could not open|failed to connect"),
    ("🤦", "mistake", r"\bmistake\b|\bwrong\b|\bslips?\b"),
    ("🧹", "lint", r"hadolint|\bruff\b|\blint"),
    ("🧪", "test", r"\bverify\b|\btests?\b|\bchecks?\b|pipefail"),
    ("🎨", "ui", r"\b(css|layout|sticky|header|tiles?|screenshots?|animations?|opacity|phones?|invisible)\b"),
    ("📏", "sizing", r"\bquotas?\b|\bram\b|\bsizing\b|sized for|resource limits?"),
    ("⚠️", "warning", r"\bwarning\b|\brisk\b"),
]
FIXED_WORDS = r"\b(fix(ed)?|resolved|solved|clarified|explained|passed)\b"


def entry_level(blocks: list[dict]) -> int | None:
    """The heading level used most often (ties -> deeper): that's where incidents live."""
    counts: dict[int, int] = {}
    for b in blocks:
        if b["t"] == "h" and b["level"] > 0:
            counts[b["level"]] = counts.get(b["level"], 0) + 1
    if not counts:
        return None
    return max(counts, key=lambda lvl: (counts[lvl], lvl))


def normalize_status(note: str) -> str:
    n = note.lower()
    if "false alarm" in n:
        return "false-alarm"
    if re.match(r"\s*open\b", n):
        return "open"
    if re.search(FIXED_WORDS, n):
        return "fixed"
    return "noted"


def classify(title: str, text: str, note: str | None) -> tuple[str, str, str]:
    t, hay = title.lower(), f"{title}\n{text}".lower()
    title_kinds = [("🎉", "success", r"\bsuccess\b"), *KINDS]
    emoji, kind = next(((e, k) for e, k, p in title_kinds if re.search(p, t)), (None, None))
    if emoji is None:   # body text: "false alarm" mentioned in passing doesn't make the entry one
        body_kinds = [k for k in KINDS if k[1] != "false alarm"]
        emoji, kind = next(((e, k) for e, k, p in body_kinds if re.search(p, hay)), ("🐞", "issue"))
    if "success" in t or "✅" in title:
        status = "passed"
    elif note:                                    # the doc's own summary table said so
        status = normalize_status(note)
    elif "false alarm" in t or "ℹ️" in title:
        status = "false-alarm"
    elif re.search(r"\(open\b", t):
        status = "open"
    elif any(lbl in text for lbl in ("Fix", "Fixed")) or re.search(FIXED_WORDS, hay):
        status = "fixed"
    else:
        status = "noted"
    if status == "false-alarm":
        emoji, kind = "🕵️", "false alarm"
    return emoji, kind, status


def status_table(blocks: list[dict]) -> dict[str, str]:
    """Item number -> status text, from a summary table with "#" and "Status" columns
    (Word/Markdown tables, or an aligned plain-text table)."""
    found: dict[str, str] = {}
    header = None
    for b in blocks:
        if b["t"] == "row":
            low = [c.lower() for c in b["cells"]]
            if low and low[0] == "#" and "status" in low:
                header = low.index("status")
            elif header is not None and len(b["cells"]) > header and b["cells"][0].strip().isdigit():
                found.setdefault(b["cells"][0].strip(), b["cells"][header].strip())
        elif b["t"] == "tblend":
            header = None
        elif b["t"] == "code" and re.search(r"^\s*#\s{2,}.*\bStatus\b", b["text"], re.M):
            for line in b["text"].splitlines():
                m = re.match(r"^\s*(\d+)\s{2,}.*\s{2,}(\S.*?)\s*$", line)
                if m:
                    found.setdefault(m.group(1), m.group(2))
    return found


def item_number(heading: dict) -> str | None:
    if heading.get("num"):
        return heading["num"]
    m = re.match(r"^Issue\s+(\d+)\b", heading["text"])
    return m.group(1) if m else None


def clean_title(title: str) -> str:
    title = re.sub(r"\s*[✅❌⚠️ℹ️]+\s*$", "", title).strip()
    return re.sub(r"^(Issue\s+\d+\s*[—–-]\s*)", "", title)


def to_parts(blocks: list[dict]) -> list[dict]:
    """Entry body as typed parts the page renders with textContent only."""
    parts: list[dict] = []
    pending_label = None
    for b in blocks:
        if b["t"] == "label":
            pending_label = b["text"].rstrip(":")
            continue
        if b["t"] == "tblend":
            if parts and parts[-1]["type"] == "table":
                parts[-1]["closed"] = True
            continue
        if b["t"] == "h":
            parts.append({"type": "subhead", "text": b["text"]})
        elif b["t"] == "code":
            parts.append({"type": "log", "text": b["text"]})
        elif b["t"] == "row":
            if parts and parts[-1]["type"] == "table" and not parts[-1].get("closed"):
                parts[-1]["rows"].append(b["cells"])
            else:
                fields = b["cells"][:2] == ["Field", "Value"]
                parts.append({"type": "table", "fields": fields, "rows": [] if fields else [b["cells"]]})
            continue
        elif b["t"] == "li":
            if parts and parts[-1]["type"] == "list" and pending_label is None:
                parts[-1]["items"].append(b["text"])
            else:
                parts.append({"type": "list", "label": pending_label, "items": [b["text"]]})
        else:
            parts.append({"type": "field" if pending_label else "text", "label": pending_label, "text": b["text"]})
        pending_label = None
    for p in parts:
        p.pop("closed", None)
    return parts


DATE_RE = re.compile(r"(\d{1,2})(?:\s*[–-]\s*(\d{1,2}))?\s+(January|February|March|April|May|June|July|"
                     r"August|September|October|November|December)\s+(\d{4})")


def doc_date(blocks: list[dict], path: Path) -> str:
    for b in blocks[:15]:
        m = DATE_RE.search(b.get("text", ""))
        if m:
            day = m.group(2) or m.group(1)
            return datetime.strptime(f"{day} {m.group(3)} {m.group(4)}", "%d %B %Y").date().isoformat()
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).date().isoformat()


def build_chapter(path: Path, blocks: list[dict]) -> dict | None:
    level = entry_level(blocks)
    title = next((b["text"] for b in blocks if b["t"] == "h" and b["level"] == 0), path.stem.replace("-", " "))
    # first plain paragraph that isn't the value of a "Label:" field (dates, environment lines)
    intro = next((b["text"] for prev, b in zip([{}] + blocks, blocks)
                  if b["t"] == "p" and prev.get("t") != "label"), "")
    statuses = status_table(blocks)
    entries, current = [], None
    for b in blocks:
        if b["t"] == "h" and level is not None and b["level"] <= level:
            if current:
                entries.append(current)
            current = {"title": b["text"], "blocks": [], "num": item_number(b)} if b["level"] == level else None
            continue
        if current is not None:
            current["blocks"].append(b)
    if current:
        entries.append(current)

    out = []
    for e in entries:
        if not e["blocks"]:
            continue
        body = " ".join(b.get("text", "") or " ".join(b.get("cells", [])) for b in e["blocks"])
        note = statuses.get(e["num"]) if e["num"] else None
        emoji, kind, status = classify(e["title"], body, note)
        out.append({"title": clean_title(e["title"]), "emoji": emoji, "kind": kind, "status": status,
                    "status_note": note, "parts": to_parts(e["blocks"])})
    if not out:
        return None
    head = " ".join(b.get("text", "") for b in blocks[:6])
    mtime = path.stat().st_mtime
    phases = [float(x) for x in re.findall(r"(?i)phase\s+(\d+(?:\.\d+)?)", f"{path.stem} {head}")]
    return {"file": path.name, "title": title, "date": doc_date(blocks, path), "phase": max(phases, default=0),
            "mtime": mtime, "intro": intro, "entries": out}


def redact_tree(obj):
    if isinstance(obj, str):
        return redact(obj)
    if isinstance(obj, list):
        return [redact_tree(x) for x in obj]
    if isinstance(obj, dict):
        return {k: (v if k in ("file", "date", "phase", "status", "kind", "emoji", "type") else redact_tree(v))
                for k, v in obj.items()}
    return obj


def main(docs: Path, out: Path) -> int:
    chapters, skipped = [], []
    for path in sorted(p for p in docs.rglob("*") if p.is_file()):
        reader = READERS.get(path.suffix.lower())
        if path.name.startswith(("~$", ".")) or reader is None or path.stat().st_size > MAX_BYTES:
            skipped.append(path.name)
            continue
        try:
            chapter = build_chapter(path, reader(path))
        except Exception as exc:  # noqa: BLE001 - one bad doc must not break the build
            print(f"journal: skipped {path.name}: {exc}", file=sys.stderr)
            skipped.append(path.name)
            continue
        if chapter:
            chapters.append(chapter)
    # Newest first: the date written in the doc, then the most recently changed file (git only
    # rewrites changed files in the agent's workspace), then the highest phase number.
    chapters.sort(key=lambda c: (c["date"], c.pop("mtime"), c["phase"], c["file"]), reverse=True)
    data = redact_tree({"generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                        "chapters": chapters})
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    n = sum(len(c["entries"]) for c in chapters)
    print(f"journal: {len(chapters)} docs, {n} entries -> {out}" + (f" (skipped: {', '.join(skipped)})" if skipped else ""))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2])))

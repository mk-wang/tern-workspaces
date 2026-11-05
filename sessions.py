#!/usr/bin/env python3
"""Read session metadata without launching agents or loading transcript bodies."""

from contextlib import closing
import heapq
import json
import os
import re
import shlex
import shutil
import sqlite3
import stat
import subprocess
import sys
from urllib.parse import quote

PREFIX_BYTES = 64 * 1024
CANDIDATES_PER_AGENT = 150
INDEX_BYTES = 4 * 1024 * 1024
RESULT_LIMIT = 30


def entries(directory):
    try:
        with os.scandir(directory) as scan:
            return list(scan)
    except (FileNotFoundError, NotADirectoryError):
        return []


def directories(directory):
    for entry in entries(directory):
        try:
            if entry.is_dir(follow_symlinks=False):
                yield entry.path
        except OSError:
            continue


def candidates(root, agent):
    if agent == "codex":
        folders = [root]
        for pattern in (r"\d{4}", r"\d{2}", r"\d{2}"):
            folders = [child for folder in folders for child in directories(folder)
                       if re.fullmatch(pattern, os.path.basename(child))]
    else:
        folders = list(directories(root))
    for folder in folders:
        for entry in entries(folder):
            if not entry.name.endswith(".jsonl"):
                continue
            if agent == "codex" and not entry.name.startswith("rollout-"):
                continue
            try:
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISREG(info.st_mode):
                    yield (info.st_mtime_ns, entry.path)
            except OSError:
                continue


def open_regular(file):
    fd = os.open(file, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError("Not a regular file")
    return os.fdopen(fd, "rb")


def metadata(file, agent, modified_ns):
    try:
        with open_regular(file) as stream:
            prefix = stream.read(PREFIX_BYTES).decode("utf-8", "replace")
            tail = ""
            if agent == "claude":
                size = os.fstat(stream.fileno()).st_size
                if size > PREFIX_BYTES:
                    stream.seek(max(PREFIX_BYTES, size - PREFIX_BYTES))
                    tail = stream.read(PREFIX_BYTES).decode("utf-8", "replace").partition("\n")[2]
    except OSError:
        return None
    cwd = None
    title = None
    session_id = os.path.basename(file)[:-6] if agent == "claude" else None
    continuation = None
    if agent == "claude" and not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", session_id):
        return None
    for line in (prefix + "\n" + tail).splitlines():
        try:
            record = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(record, dict):
            continue
        if agent == "omp":
            if record.get("type") == "title" and isinstance(record.get("title"), str):
                title = record["title"] or title
            if record.get("type") == "session":
                cwd = record.get("cwd")
                session_id = record.get("id")
                title = title or record.get("title")
                parent = record.get("continuationOf")
                if isinstance(parent, str) and parent:
                    continuation = parent
                break
        elif agent == "codex" and record.get("type") == "session_meta":
            payload = record.get("payload")
            if isinstance(payload, dict):
                cwd = payload.get("cwd")
                session_id = payload.get("id")
                title = payload.get("title")
                break
        elif agent == "claude":
            if record.get("type") == "custom-title":
                title = record.get("customTitle") or title
            elif record.get("type") == "ai-title" and not title:
                title = record.get("title") or record.get("aiTitle")
            if not cwd and isinstance(record.get("cwd"), str):
                recorded_id = record.get("sessionId")
                if recorded_id is not None and (not isinstance(recorded_id, str) or recorded_id.lower() != session_id.lower()):
                    return None
                cwd = record["cwd"]
    if not isinstance(cwd, str) or not os.path.isabs(cwd) or "\0" in cwd:
        return None
    if agent == "codex":
        if not isinstance(session_id, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", session_id):
            return None
        command = "codex resume " + shlex.quote(session_id)
    elif agent == "claude":
        command = "claude --resume " + shlex.quote(session_id)
    else:
        command = "omp --resume " + shlex.quote(file)
    if not isinstance(title, str) or not title.strip():
        label = session_id if isinstance(session_id, str) and session_id else os.path.basename(file)[:-6]
        title = "Chat session " + label[:8]
    return {"agent": agent, "title": title, "cwd": cwd, "project_root": cwd,
            "command": command, "updated_ms": modified_ns // 1_000_000, "session_files": [],
            "_id": session_id if isinstance(session_id, str) else os.path.basename(file)[:-6],
            "_file": file, "_continuation": continuation}


def indexed_titles(agent, root, items, omp_data_dir):
    ids = {item["_id"] for item in items}
    titles = {}
    if not ids:
        return titles
    if agent == "omp":
        database = os.path.abspath(os.path.join(omp_data_dir, "history.db"))
        try:
            if not stat.S_ISREG(os.lstat(database).st_mode):
                return titles
            uri = "file:" + quote(database, safe="/") + "?mode=ro"
            with closing(sqlite3.connect(uri, uri=True, timeout=0.2)) as db:
                placeholders = ",".join("?" for _ in ids)
                for session_id, title in db.execute(
                    "SELECT session_id, title FROM session_titles WHERE session_id IN (" + placeholders + ")", tuple(ids)
                ):
                    if isinstance(title, str) and title.strip():
                        titles[session_id] = title
        except (OSError, sqlite3.Error):
            pass
    elif agent == "codex":
        try:
            with open_regular(os.path.join(root, "..", "session_index.jsonl")) as stream:
                stream.seek(0, os.SEEK_END)
                offset = max(0, stream.tell() - INDEX_BYTES)
                stream.seek(offset)
                data = stream.read(INDEX_BYTES)
            if offset:
                data = data.partition(b"\n")[2]
            for line in data.splitlines():
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if isinstance(entry, dict) and isinstance(entry.get("id"), str) and entry["id"] in ids:
                    name = entry.get("thread_name")
                    if isinstance(name, str):
                        titles[entry["id"]] = name
        except OSError:
            pass
    else:
        for folder in {os.path.dirname(item["_file"]) for item in items}:
            try:
                with open_regular(os.path.join(folder, "sessions-index.json")) as stream:
                    data = stream.read(INDEX_BYTES + 1)
                if len(data) > INDEX_BYTES:
                    continue
                index = json.loads(data)
            except (OSError, ValueError):
                continue
            if not isinstance(index, dict) or not isinstance(index.get("entries"), list):
                continue
            for entry in index["entries"]:
                if not isinstance(entry, dict) or not isinstance(entry.get("sessionId"), str) or entry["sessionId"] not in ids:
                    continue
                for item in items:
                    if item["_id"] != entry["sessionId"] or os.path.dirname(item["_file"]) != folder:
                        continue
                    if entry.get("projectPath") and entry["projectPath"] != item["cwd"]:
                        continue
                    if entry.get("fullPath") and (not isinstance(entry["fullPath"], str) or os.path.normpath(entry["fullPath"]) != item["_file"]):
                        continue
                    title = entry.get("customTitle") or entry.get("summary")
                    if isinstance(title, str) and title.strip():
                        titles[item["_file"]] = title
    return titles


def recent_sessions(workspace_paths):
    resolved_workspaces = [(path, os.path.realpath(path)) for path in workspace_paths]
    home = os.path.expanduser("~")
    profile = os.environ.get("OMP_PROFILE", os.environ.get("PI_PROFILE", ""))
    if profile and not re.fullmatch(r"[a-zA-Z0-9_-]+", profile):
        profile = ""
    config_root = os.path.join(home, os.environ.get("PI_CONFIG_DIR", ".omp"))
    if profile:
        config_root = os.path.join(config_root, "profiles", profile)
    agent_dir = os.path.join(config_root, "agent") if profile else (os.environ.get("PI_CODING_AGENT_DIR") or os.path.join(config_root, "agent"))
    omp_data_dir = agent_dir
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg and (profile or not os.environ.get("PI_CODING_AGENT_DIR")):
        xdg_root = os.path.join(xdg, "omp", "profiles", profile) if profile else os.path.join(xdg, "omp")
        if os.path.isdir(xdg_root):
            omp_data_dir = xdg_root
    omp_root = os.environ.get("PI_CODING_AGENT_SESSION_DIR") or os.path.join(omp_data_dir, "sessions")
    roots = {
        "omp": omp_root,
        "codex": os.path.join(os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"), "sessions"),
        "claude": os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude"), "projects"),
    }
    found = []
    for agent, root in roots.items():
        # ponytail: inspect the newest 150 files per agent; raise this limit if a
        # user needs more than the 30 displayed sessions despite invalid files.
        items = []
        for modified, file in heapq.nlargest(CANDIDATES_PER_AGENT, candidates(os.path.abspath(root), agent)):
            session = metadata(file, agent, modified)
            if session is not None:
                items.append(session)
        if agent == "omp":
            parents = {item["_id"]: item["_continuation"] for item in items if item["_continuation"]}
            continued = set(parents.values())
            chains = {}
            # Prefer a continuation head even if saving its ancestor changed the ancestor's mtime.
            for item in sorted(items, key=lambda row: (row["_id"] not in continued, row["updated_ms"]), reverse=True):
                identifier = item["_id"]
                seen = set()
                while identifier in parents and identifier not in seen:
                    seen.add(identifier)
                    identifier = parents[identifier]
                head = chains.setdefault(identifier, item)
                head["session_files"].append(os.path.realpath(item["_file"]))
            items = list(chains.values())
        titles = indexed_titles(agent, root, items, omp_data_dir)
        for item in items:
            title = titles.get(item["_file"] if agent == "claude" else item["_id"])
            if isinstance(title, str) and title.strip():
                item["title"] = title
            del item["_id"], item["_file"], item["_continuation"]
            found.append(item)
    found.sort(key=lambda session: session["updated_ms"], reverse=True)
    found = found[:RESULT_LIMIT]
    for session in found:
        paths = {os.path.realpath(path) for path in {session["cwd"], session["project_root"]}}
        session["workspace_paths"] = [
            original for original, canonical in resolved_workspaces
            if any(path == canonical or path.startswith(canonical.rstrip(os.sep) + os.sep) for path in paths)
        ]
    return found


def live_sessions():
    executable = os.environ.get("TERN_EXE") or shutil.which("tern")
    if not executable and sys.platform == "darwin":
        executable = "/Applications/Tern.app/Contents/MacOS/tern"
    result = subprocess.run([executable or "tern", "inspect", "--json"], check=True,
                            capture_output=True, text=True, timeout=2)
    panes = json.loads(result.stdout)["panes"]
    if not isinstance(panes, list):
        raise ValueError("Invalid Tern pane inventory")
    found = []
    for pane in panes:
        if not isinstance(pane, dict):
            continue
        identity = pane.get("identity")
        hops = identity.get("hops") if isinstance(identity, dict) else None
        if not isinstance(hops, list) or not hops or any(
            not isinstance(hop, dict) or hop.get("method") != "local" for hop in hops
        ):
            continue
        identifier, path = pane.get("pane"), pane.get("omp_session_file")
        # A new resume tab has launch arguments before OMP publishes its session file.
        if (path is None or path == "") and pane.get("exited") is None:
            args = pane.get("args")
            if isinstance(args, list) and "-c" in args:
                index = args.index("-c") + 1
                if index < len(args) and isinstance(args[index], str):
                    try:
                        words = shlex.split(args[index])
                    except ValueError:
                        words = []
                    if len(words) == 3 and words[:2] == ["omp", "--resume"]:
                        path = words[2]
        if type(identifier) is int and identifier > 0 and isinstance(path, str) and os.path.isabs(path) and "\0" not in path:
            found.append({"pane": identifier, "file": os.path.realpath(path)})
    return sorted(found, key=lambda pane: pane["pane"])


if __name__ == "__main__":
    data = live_sessions() if sys.argv[1] == "--live" else recent_sessions(json.loads(sys.argv[1]))
    json.dump(data, sys.stdout, ensure_ascii=True)

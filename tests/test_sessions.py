"""Run with: python3 tests/test_sessions.py (uses only disposable files)."""

import importlib.util
import json
import os
from pathlib import Path
import shlex
import sqlite3
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("sessions", Path(__file__).resolve().parent.parent / "sessions.py")
sessions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sessions)


def main():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        omp = root / "omp" / "bucket"
        codex = root / "codex" / "sessions" / "2026" / "01" / "01"
        claude = root / "claude" / "projects" / "bucket"
        for directory in (omp, codex, claude):
            directory.mkdir(parents=True)
        identifier = "12345678-1234-1234-1234-123456789abc"
        cwd = "/work/project's folder"
        omp_file = omp / "session's file.jsonl"
        claude_file = claude / (identifier + ".jsonl")
        codex_file = codex / ("rollout-2026-01-01T00-00-00-" + identifier + ".jsonl")
        omp_file.write_text(json.dumps({"type": "title", "title": "OMP title"}) + "\n" +
                            json.dumps({"type": "session", "id": identifier, "cwd": cwd}) + "\n" + "x" * (sessions.PREFIX_BYTES * 2))
        codex_file.write_text(json.dumps({"type": "session_meta", "payload": {"id": identifier, "cwd": cwd}}) + "\n" + "x" * (sessions.PREFIX_BYTES * 2))
        claude_file.write_text(json.dumps({"type": "user", "cwd": cwd, "sessionId": identifier}) + "\n" +
                               json.dumps({"type": "custom-title", "customTitle": "Claude title"}) + "\n" +
                               "x" * (sessions.PREFIX_BYTES * 2) + "\n" +
                               json.dumps({"type": "custom-title", "customTitle": "Claude tail"}) + "\n")
        for index, file in enumerate((omp_file, codex_file, claude_file), 1):
            os.utime(file, (index, index))
        (claude / "link.jsonl").symlink_to(claude_file)
        (root / "omp-agent").mkdir()
        with sqlite3.connect(root / "omp-agent" / "history.db") as db:
            db.execute("CREATE TABLE session_titles (session_id TEXT PRIMARY KEY, title TEXT)")
            db.execute("INSERT INTO session_titles VALUES (?, ?)", (identifier, "OMP indexed"))
        (root / "codex" / "session_index.jsonl").write_text(
            json.dumps({"id": identifier, "thread_name": "Old codex"}) + "\n" +
            json.dumps({"id": identifier, "thread_name": "Codex indexed"}) + "\n")
        (claude / "sessions-index.json").write_text(json.dumps({"entries": [
            {"sessionId": identifier, "projectPath": cwd, "fullPath": str(claude_file), "summary": "Claude indexed"}
        ]}))
        os.environ.update({"HOME": temporary, "OMP_PROFILE": "", "XDG_DATA_HOME": "",
                           "PI_CODING_AGENT_DIR": str(root / "omp-agent"), "PI_CODING_AGENT_SESSION_DIR": str(omp.parent),
                           "CODEX_HOME": str(root / "codex"), "CLAUDE_CONFIG_DIR": str(root / "claude")})
        result = sessions.recent_sessions([])
        assert [item["agent"] for item in result] == ["claude", "codex", "omp"]
        assert all(item["cwd"] == cwd and item["project_root"] == cwd for item in result)
        assert [item["title"] for item in result] == ["Claude indexed", "Codex indexed", "OMP indexed"]
        assert shlex.split(result[0]["command"]) == ["claude", "--resume", identifier]
        assert shlex.split(result[1]["command"]) == ["codex", "resume", identifier]
        assert shlex.split(result[2]["command"]) == ["omp", "--resume", str(omp_file)]
        assert all("_id" not in item and "_file" not in item for item in result)
        assert result[0]["session_files"] == result[1]["session_files"] == []
        assert result[2]["session_files"] == [str(omp_file.resolve())]
        (claude / "sessions-index.json").write_text(json.dumps({"entries": [
            {"sessionId": identifier, "projectPath": "/different", "summary": "Wrong workspace"}
        ]}))
        assert sessions.recent_sessions([])[0]["title"] == "Claude tail"
        codex_file.write_text(json.dumps({"type": "session_meta", "payload": {"id": "x; touch /tmp/bad", "cwd": cwd}}))
        assert sessions.metadata(str(codex_file), "codex", 0) is None
        assert sessions.metadata(str(claude / "link.jsonl"), "claude", 0) is None
        invalid = claude / "not-a-uuid.jsonl"
        invalid.write_text(json.dumps({"type": "user", "cwd": cwd, "sessionId": identifier}))
        assert sessions.metadata(str(invalid), "claude", 0) is None
        claude_file.write_text(json.dumps({"type": "user", "cwd": cwd, "sessionId": "00000000-0000-0000-0000-000000000000"}))
        assert sessions.metadata(str(claude_file), "claude", 0) is None
        database = root / "omp-agent" / "history.db"
        database.rename(database.with_suffix(".real"))
        database.symlink_to(database.with_suffix(".real"))
        assert sessions.indexed_titles("omp", "", [{"_id": identifier}], str(database.parent)) == {}
        database.unlink()
        os.mkfifo(database)
        assert sessions.indexed_titles("omp", "", [{"_id": identifier}], str(database.parent)) == {}

        for name, fields, modified in (
            ("continued-1", {"id": "continued-1", "continuationOf": identifier}, 10),
            ("continued's latest", {"id": "continued-2", "continuationOf": "continued-1"}, 20),
            ("independent", {"id": "independent"}, 25),
            ("fork", {"id": "fork", "parentSession": "continued-2"}, 30),
        ):
            file = omp / (name + ".jsonl")
            file.write_text(json.dumps({"type": "session", "cwd": cwd, "title": "Shared title", **fields}) + "\n")
            os.utime(file, (modified, modified))
        # A newer write to an ancestor must not replace its continuation head.
        os.utime(omp_file, (100, 100))
        result = sessions.recent_sessions([])
        assert [shlex.split(item["command"])[-1] for item in result] == [
            str(omp / "fork.jsonl"), str(omp / "independent.jsonl"), str(omp / "continued's latest.jsonl")
        ]
        assert all(item["title"] == "Shared title" for item in result)
        assert set(result[2]["session_files"]) == {
            str(omp_file.resolve()), str((omp / "continued-1.jsonl").resolve()), str((omp / "continued's latest.jsonl").resolve())
        }
        assert result[0]["session_files"] == [str((omp / "fork.jsonl").resolve())]
        assert result[1]["session_files"] == [str((omp / "independent.jsonl").resolve())]

        real = root / "project's directory"
        (real / "src").mkdir(parents=True)
        alias = root / "project-link"
        alias.symlink_to(real, target_is_directory=True)
        sibling = root / "project's directory-other"
        sibling.mkdir()
        cases = (("alias", alias / "src"), ("real", real / "src"), ("sibling", sibling))
        for index, (name, directory) in enumerate(cases, 200):
            file = omp / (name + ".jsonl")
            file.write_text(json.dumps({"type": "session", "id": name, "cwd": str(directory)}) + "\n")
            os.utime(file, (index, index))
        requested = [str(alias), str(real)]
        by_file = {shlex.split(item["command"])[-1]: item for item in sessions.recent_sessions(requested)}
        for name, directory in cases:
            item = by_file[str(omp / (name + ".jsonl"))]
            assert item["cwd"] == str(directory)
            assert item["workspace_paths"] == ([] if name == "sibling" else requested)

        session_alias = root / "omp-alias"
        session_alias.symlink_to(omp, target_is_directory=True)
        local = {"hops": [{"method": "local"}]}
        snapshot = {"panes": [
            {"pane": 1, "omp_session_file": str(session_alias / omp_file.name), "identity": local},
            {"pane": 2, "omp_session_file": str(omp_file), "identity": {"hops": [{"method": "ssh-key"}]}},
            {"pane": 3, "omp_session_file": str(omp_file), "identity": {"hops": [{"method": "local"}, {"method": "tailscale"}]}},
            {"pane": 4, "omp_session_file": str(omp_file)},
            {"pane": 5, "omp_session_file": None, "identity": local},
            {"pane": 6, "omp_session_file": "relative.jsonl", "identity": local},
            {"pane": True, "omp_session_file": str(omp_file), "identity": local},
            {"pane": 7, "omp_session_file": None, "exited": None, "identity": local,
             "args": ["-l", "-c", "omp --resume " + shlex.quote(str(session_alias / omp_file.name))]},
            {"pane": 8, "omp_session_file": str(omp / "fork.jsonl"), "exited": 0, "identity": local,
             "args": ["-l", "-c", "omp --resume " + shlex.quote(str(omp_file))]},
            {"pane": 9, "omp_session_file": None, "exited": None, "identity": local,
             "args": ["-l", "-c", "omp --resume 'unterminated"]},
            {"pane": 10, "omp_session_file": None, "exited": None, "identity": {"hops": [{"method": "ssh-key"}]},
             "args": ["-l", "-c", "omp --resume " + shlex.quote(str(omp_file))]},
            {"pane": 11, "omp_session_file": None, "exited": None, "identity": local,
             "args": ["-l", "-c", "omp --resume " + shlex.quote(str(omp_file)) + "; echo other-command"]},
            {"pane": 12, "omp_session_file": None, "exited": None, "identity": local,
             "args": ["-l", "-c", "codex resume " + identifier]},
            {"pane": 13, "omp_session_file": None, "exited": 0, "identity": local,
             "args": ["-c", "omp --resume " + shlex.quote(str(omp_file))]},
            {"pane": 14, "omp_session_file": None, "exited": None, "identity": local,
             "args": ["-c", "omp --resume " + shlex.quote(str(omp_file))]},
            {"pane": 15, "omp_session_file": None, "identity": local,
             "args": ["-c", "omp --resume " + shlex.quote(str(omp_file))]},
        ]}
        completed = sessions.subprocess.CompletedProcess([], 0, json.dumps(snapshot), "")
        with patch.object(sessions.subprocess, "run", return_value=completed):
            assert sessions.live_sessions() == [
                {"pane": 1, "file": str(omp_file.resolve())},
                {"pane": 7, "file": str(omp_file.resolve())},
                {"pane": 8, "file": str((omp / "fork.jsonl").resolve())},
                {"pane": 14, "file": str(omp_file.resolve())},
                {"pane": 15, "file": str(omp_file.resolve())},
            ]
        with patch.object(sessions.subprocess, "run", side_effect=sessions.subprocess.TimeoutExpired("tern", 2)):
            try:
                sessions.live_sessions()
            except sessions.subprocess.TimeoutExpired:
                pass
            else:
                raise AssertionError("Live inspection failure must not look like an empty inventory")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Exercise the real terminal menu against isolated, nonmutating backends."""
import errno
import os
import pathlib
import pty
import re
import select
import signal
import subprocess
import sys
import time

program, root = map(pathlib.Path, sys.argv[1:])
env = dict(os.environ, SBM_LIB=str(program), TERM="dumb", NO_COLOR="1")


class Terminal:
    def __init__(self, *args):
        self.master, slave = pty.openpty()
        child_env = env.copy()
        if "--no-color" in args:
            child_env.pop("NO_COLOR", None)
        self.proc = subprocess.Popen(
            ["bash", str(program / "sb"), *args], env=child_env,
            stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
        )
        os.close(slave)
        self.pending = b""
        self.transcript = b""

    def expect(self, text, timeout=30):
        wanted = text.encode()
        deadline = time.monotonic() + timeout
        while wanted not in self.pending:
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for {text!r}\n{self.transcript.decode(errors='replace')}")
            ready, _, _ = select.select([self.master], [], [], 0.2)
            if not ready:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b""
            if not chunk:
                raise AssertionError(f"menu exited waiting for {text!r}\n{self.transcript.decode(errors='replace')}")
            # jq 1.6 can emit ANSI colors on a PTY even with NO_COLOR set.
            self.pending = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", self.pending + chunk)
            self.transcript += chunk
        self.pending = self.pending.split(wanted, 1)[1]

    def send(self, text):
        os.write(self.master, text.encode())

    def choose(self, value):
        self.expect("选择操作 [0]: ")
        self.send(value + "\n")

    def done(self):
        assert self.proc.wait(timeout=10) == 0

    def close(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            self.proc.wait(timeout=10)
        os.close(self.master)


term = Terminal()
try:
    term.expect("请选择 [0]: ")
    term.send("20\n")
    term.choose("99")
    term.expect("选择无效，请输入 0–8。")
    term.choose("3")
    term.expect("INJECTED_ACTION_FAILURE")
    term.expect("按 Enter 继续…")
    term.send("\n")
    term.choose("4")
    term.expect("操作未完成")
    term.expect("按 Enter 继续…")
    term.send("\n")
    term.choose("8")
    term.expect("备份文件路径: ")
    term.send("/tmp/fixture-backup\n")
    term.expect("[y/N] ")
    term.send("n\n")
    term.expect("已取消。")
    term.choose("8")
    term.expect("备份文件路径: ")
    term.send("q\n")
    term.expect("已取消。")
    term.choose("0")
    term.expect("请选择 [0]: ")
    term.send("14\n")
    term.choose("5")
    term.choose("0")
    term.expect("9. 按带宽/延迟优化 TCP")
    term.choose("0")
    term.expect("请选择 [0]: ")
    term.send("3\n")
    term.expect("选择节点 [1]: ")
    term.send("1\n")
    term.choose("6")
    term.expect("新名称 [Panel]: ")
    term.send("Renamed\n")
    term.expect("按 Enter 继续…")
    term.send("\n")
    term.expect('"name": "Renamed"')
    term.choose("0")
    term.expect("选择节点 [1]: ")
    term.send("0\n")
    term.expect("请选择 [0]: ")
    term.send("20\n")
    term.choose("8")
    term.expect("备份文件路径: ")
    term.send("\x04")
    term.done()
finally:
    (root / "ui-terminal.log").write_bytes(term.transcript)
    term.close()

# Successful manager updates replace the parent menu with the new program.
term = Terminal()
try:
    term.expect("请选择 [0]: ")
    term.send("8\n")
    term.choose("11")
    term.expect("ui-reloaded")
    term.expect("请选择 [0]: ")
    term.send("19\n")
    term.choose("1")
    term.expect("TEST_UNINSTALL_CONFIRM [y/N] ")
    term.send("n\n")
    term.expect("已取消。")
    term.choose("1")
    term.expect("TEST_UNINSTALL_CONFIRM [y/N] ")
    term.send("y\n")
    term.expect("TEST_UNINSTALL_COMPLETE")
    term.done()
finally:
    term.close()

# Global options survive both the worker boundary and a manager reload.
term = Terminal("--dry-run", "--yes", "--quiet", "--no-color")
try:
    term.expect("请选择 [0]: ")
    term.send("8\n")
    term.choose("11")
    term.expect("ui-reloaded")
    term.expect("请选择 [0]: ")
    term.send("20\n")
    term.choose("6")
    term.expect("Sub-Store 本地订阅名称 [sb-manager]: ")
    term.send("\n")
    term.expect("SUBSTORE_ACTION_OK")
    term.expect("按 Enter 继续…")
    term.send("\n")
    term.choose("0")
    term.expect("请选择 [0]: ")
    term.send("0\n")
    term.done()
finally:
    term.close()
print("PTY MENU LIFECYCLE PASSED")

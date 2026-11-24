"""
Terminal logging, subprocess execution, host environment detection,
and safe filesystem utilities.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional


class Color:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    RED = "\033[31m"
    CYAN = "\033[36m"


def info(msg: str) -> None:
    print(f"{Color.CYAN}[INFO]{Color.RESET} {msg}")


def ok(msg: str) -> None:
    print(f"{Color.GREEN}[OK]{Color.RESET} {msg}")


def warn(msg: str) -> None:
    print(f"{Color.YELLOW}[WARN]{Color.RESET} {msg}")


def die(msg: str, code: int = 1) -> None:
    print(f"{Color.RED}[ERROR]{Color.RESET} {msg}", file=sys.stderr)
    sys.exit(code)


def is_wsl() -> bool:
    rel = platform.release().lower()
    return "microsoft" in rel or "wsl" in rel


def require_root(dry_run: bool = False) -> None:
    if dry_run:
        return
    if os.geteuid() != 0:
        die("This command must be run as root (use sudo).")


def run(
    cmd: list[str],
    *,
    check: bool = True,
    input_text: Optional[str] = None,
    capture: bool = False,
    dry_run: bool = False,
) -> subprocess.CompletedProcess:
    if dry_run:
        info(f"[dry-run] {' '.join(cmd)}")
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
    return subprocess.run(
        cmd,
        check=check,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def safe_copy_file(
    src: Path,
    dst: Path,
    mode: Optional[int] = None,
    *,
    dry_run: bool = False,
) -> bool:
    if not src.exists():
        warn(f"Optional file missing, skipping: {src}")
        return False
    if dry_run:
        info(f"[dry-run] copy {src} -> {dst}")
        return True
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if mode is not None:
        os.chmod(dst, mode)
    return True


def safe_symlink(target: str, link_path: Path, *, dry_run: bool = False) -> None:
    if dry_run:
        info(f"[dry-run] symlink {link_path} -> {target}")
        return
    link_path.parent.mkdir(parents=True, exist_ok=True)
    if link_path.is_symlink() or link_path.exists():
        link_path.unlink()
    os.symlink(target, link_path)


def write_text(path: Path, content: str, mode: int = 0o644, *, dry_run: bool = False) -> None:
    if dry_run:
        info(f"[dry-run] write {path} ({len(content)} bytes)")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    os.chmod(path, mode)


def detect_host_timezone() -> Optional[str]:
    lt = Path("/etc/localtime")
    if lt.is_symlink():
        resolved = str(lt.resolve())
        prefix = "/usr/share/zoneinfo/"
        if resolved.startswith(prefix):
            return resolved[len(prefix):]
    tz = Path("/etc/timezone")
    if tz.exists():
        val = tz.read_text().strip()
        if val:
            return val
    return None

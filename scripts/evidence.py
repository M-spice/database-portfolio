"""Run a command and save its unedited output as evidence under a standard header."""

import argparse
import os
import platform
import re
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
LAGOS = ZoneInfo("Africa/Lagos")
RULE = "=" * 78

SERVER_VERSION = {
    "postgres": ["docker", "compose", "exec", "-T", "postgres", "postgres", "--version"],
    "mongo": ["docker", "compose", "exec", "-T", "mongo", "mongod", "--version"],
}


def env_values():
    path = ROOT / ".env"
    if not path.exists():
        return []
    pairs = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip("'\"")
        if value:
            pairs.append((key.strip(), value))
    return sorted(pairs, key=lambda kv: len(kv[1]), reverse=True)


def make_redactor():
    pairs = env_values()
    root = re.compile(
        "|".join(re.escape(form) for form in {str(ROOT), ROOT.as_posix()}), re.IGNORECASE
    )

    def redact(text):
        for key, value in pairs:
            text = text.replace(value, f"[REDACTED:{key}]")
        return root.sub("<repository root>", text)

    return redact


def first_line(command):
    try:
        done = subprocess.run(
            command, cwd=ROOT, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable"
    text = (done.stdout or done.stderr).strip()
    return text.splitlines()[0] if done.returncode == 0 and text else "unavailable"


def detect_target(command):
    text = " ".join(command).lower()
    if "mongo" in text:
        return "mongo"
    if "psql" in text or "postgres" in text:
        return "postgres"
    return "none"


def run(command, redact):
    child_env = {**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"}
    started = time.perf_counter()
    try:
        proc = subprocess.Popen(
            command, cwd=Path.cwd(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", env=child_env,
        )
    except OSError as exc:
        return 127, time.perf_counter() - started, f"{exc}\n"
    lines = []
    for line in proc.stdout:
        lines.append(line)
        sys.stdout.write(redact(line))
        sys.stdout.flush()
    proc.wait()
    return proc.returncode, time.perf_counter() - started, "".join(lines)


def display_dir():
    cwd = Path.cwd().resolve()
    try:
        rel = cwd.relative_to(ROOT)
    except ValueError:
        return str(cwd)
    return "<repository root>" if rel == Path(".") else f"<repository root>/{rel.as_posix()}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--append", action="store_true")
    parser.add_argument("--target", choices=["auto", "postgres", "mongo", "none"], default="auto")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("give the command to run after --")

    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    redact = make_redactor()
    target = detect_target(command) if args.target == "auto" else args.target

    captured = datetime.now(timezone.utc)
    code, seconds, output = run(command, redact)
    server = first_line(SERVER_VERSION[target]) if target in SERVER_VERSION else "not applicable"

    header = "\n".join([
        RULE,
        f"Title:      {args.title}",
        f"Captured:   {captured.astimezone(LAGOS):%Y-%m-%d %H:%M:%S %Z} (Africa/Lagos)"
        f" | {captured:%Y-%m-%d %H:%M:%S} UTC",
        f"Command:    {subprocess.list2cmdline(command) if os.name == 'nt' else shlex.join(command)}",
        f"Directory:  {display_dir()}",
        f"Exit code:  {code}",
        f"Duration:   {seconds:.2f} s",
        f"Host:       {platform.platform()} | Python {platform.python_version()}",
        f"Docker:     {first_line(['docker', '--version'])}"
        f" | {first_line(['docker', 'compose', 'version'])}",
        f"Server:     {target}: {server}",
        RULE,
        "",
    ])
    body = output.replace("\r\n", "\n")
    if body and not body.endswith("\n"):
        body += "\n"

    out = Path(args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    gap = "\n" if args.append and out.exists() and out.stat().st_size else ""
    with out.open("a" if args.append else "w", encoding="utf-8", newline="\n") as fh:
        fh.write(gap + redact(header + body))
    sys.exit(code if code >= 0 else 1)


if __name__ == "__main__":
    main()

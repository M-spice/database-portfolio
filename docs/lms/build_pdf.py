"""Build the LMS summary PDF: a repository copy without the student ID, and an upload copy with it."""

import base64
import html
import mimetypes
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
NAME = "Itoju-portfolio-summary.pdf"
BROWSERS = [
    Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
    Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
    Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
]
FIGURE = re.compile(r"<!--fig:([^|>]+)\|([^|>]+)(?:\|(wide|tall))?-->")


def env(key):
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    return ""


def repo_url():
    remote = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT, capture_output=True, text=True,
                            check=True).stdout.strip()
    owner, repo = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?$", remote).groups()
    return f"https://github.com/{owner}/{repo}"


def figures(page):
    missing, number = [], 0

    def insert(match):
        nonlocal number
        path, caption, size = match.group(1), match.group(2), match.group(3) or ""
        number += 1
        file = ROOT / path
        if file.exists():
            data = base64.b64encode(file.read_bytes()).decode()
            body = f'<img src="data:{mimetypes.guess_type(file.name)[0]};base64,{data}" alt="{html.escape(caption)}">'
        else:
            missing.append(path)
            body = f'<div class="placeholder">Screenshot to add:<br>{html.escape(path)}</div>'
        return (f'<figure class="{size}">{body}<figcaption>Figure {number}. {html.escape(caption)}</figcaption>'
                f'</figure>')

    return FIGURE.sub(insert, page), missing


def render(page, out, browser):
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "summary.html"
        source.write_text(page, encoding="utf-8")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.unlink(missing_ok=True)
        subprocess.run([str(browser), "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                        f"--user-data-dir={Path(tmp) / 'profile'}", f"--print-to-pdf={out}", source.as_uri()],
                       check=True, capture_output=True, timeout=120)
    if not out.exists():
        raise SystemExit(f"the browser did not write {out}")
    return len(re.findall(rb"/Type\s*/Page[^s]", out.read_bytes()))


def main():
    browser = next((b for b in BROWSERS if b.exists()), None) or shutil.which("msedge") or shutil.which("chrome")
    if not browser:
        raise SystemExit("Microsoft Edge or Google Chrome is needed to print the PDF")
    url = repo_url()
    page, missing = figures((HERE / "summary.html").read_text(encoding="utf-8"))
    page = page.replace("<!--repo-->", f'<a href="{url}">{url}</a>')

    pages = render(page.replace("<!--student-id-->", ""), HERE / NAME, browser)
    print(f"repository copy: docs/lms/{NAME} ({pages} pages, no student ID)")

    student_id = env("STUDENT_ID")
    if student_id:
        pages = render(page.replace("<!--student-id-->", f"<span>Student ID: {html.escape(student_id)}</span>"),
                       HERE / "submission" / NAME, browser)
        print(f"upload copy:     docs/lms/submission/{NAME} ({pages} pages, with the student ID)")
    else:
        print("STUDENT_ID is not set in .env, so only the repository copy was written")
    print(f"screenshots still to add: {len(missing)}" + "".join(f"\n  {m}" for m in missing))


if __name__ == "__main__":
    main()

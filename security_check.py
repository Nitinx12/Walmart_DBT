"""Run non-destructive security checks for the Walmart ETL project.

The scanner reports file paths and line numbers only; it never displays a
potential credential value. Run with ``uv run python security_check.py``.
"""

from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

PROJECT_ROOT = Path(__file__).resolve().parent
MAX_FILE_SIZE_BYTES = 1_000_000
SENSITIVE_FILENAMES = {".env", ".envrc", "credentials.json", "service-account.json"}
SENSITIVE_SUFFIXES = {".key", ".pem", ".p12", ".pfx"}


class Status(StrEnum):
    """Severity for one security check result."""

    PASS = "PASS"
    WARN = "WARN"
    FAIL = "FAIL"
    SKIP = "SKIP"


@dataclass(frozen=True)
class CheckResult:
    """One security finding or successful control check."""

    control: str
    status: Status
    detail: str


@dataclass(frozen=True)
class SecretPattern:
    """A high-confidence secret signature that can be scanned safely."""

    name: str
    expression: re.Pattern[str]
    status: Status


SECRET_PATTERNS = (
    SecretPattern(
        "private key material",
        re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
        Status.FAIL,
    ),
    SecretPattern(
        "AWS access key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"), Status.FAIL
    ),
    SecretPattern(
        "GitHub access token",
        re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"),
        Status.FAIL,
    ),
    SecretPattern(
        "OpenAI API key",
        re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"),
        Status.FAIL,
    ),
    SecretPattern(
        "Slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), Status.FAIL
    ),
    SecretPattern(
        "connection URI with embedded password",
        re.compile(
            r"\b(?:mongodb(?:\+srv)?|postgres(?:ql)?|mysql)://[^/\s:@]+:[^/\s@]+@",
            re.IGNORECASE,
        ),
        Status.FAIL,
    ),
    SecretPattern(
        "hard-coded secret assignment",
        re.compile(
            r"(?i)\b(?:password|passwd|secret|token|api[_-]?key|private[_-]?key)\b\s*(?:=|:)\s*['\"](?![${<])[^'\"]{8,}['\"]"
        ),
        Status.WARN,
    ),
)


def run_git(*arguments: str) -> subprocess.CompletedProcess[str]:
    """Run a read-only Git command from the project root."""

    return subprocess.run(
        ("git", *arguments),
        capture_output=True,
        check=False,
        cwd=PROJECT_ROOT,
        text=True,
    )


def project_files() -> list[Path]:
    """Return tracked plus non-ignored worktree files, without ignored secrets."""

    result = run_git("ls-files", "-co", "--exclude-standard")
    if result.returncode != 0:
        return []
    return [PROJECT_ROOT / line for line in result.stdout.splitlines() if line]


def display_path(path: Path) -> str:
    """Return a project-relative path for findings."""

    return path.relative_to(PROJECT_ROOT).as_posix()


def is_text_file(path: Path) -> bool:
    """Return whether a small file appears to be UTF-8-compatible text."""

    try:
        if path.stat().st_size > MAX_FILE_SIZE_BYTES:
            return False
        return b"\0" not in path.read_bytes()
    except OSError:
        return False


def finding_for_match(
    pattern: SecretPattern, path: Path, text: str
) -> CheckResult | None:
    """Create a redacted finding for the first matching signature in a file."""

    match = pattern.expression.search(text)
    if match is None:
        return None
    line_number = text.count("\n", 0, match.start()) + 1
    line_start = text.rfind("\n", 0, match.start()) + 1
    line_end = text.find("\n", match.start())
    line = text[line_start : None if line_end == -1 else line_end].lstrip()
    is_comment = line.startswith(("#", "//", ";"))
    status = pattern.status
    detail = f"possible {pattern.name} in {display_path(path)}:{line_number} (value redacted)"
    if pattern.name == "connection URI with embedded password" and is_comment:
        status = Status.WARN
        detail = f"commented example URI includes credentials in {display_path(path)}:{line_number}; do not use it in deployment"
    return CheckResult(
        "Secret scan",
        status,
        detail,
    )


def check_secret_scan() -> list[CheckResult]:
    """Scan Git-visible text files for high-confidence secret signatures."""

    findings: list[CheckResult] = []
    scanned = 0
    for path in project_files():
        if not path.is_file() or not is_text_file(path):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        scanned += 1
        for pattern in SECRET_PATTERNS:
            finding = finding_for_match(pattern, path, text)
            if finding is not None:
                findings.append(finding)

    if not findings:
        findings.append(
            CheckResult(
                "Secret scan",
                Status.PASS,
                f"no signatures found in {scanned} Git-visible text files",
            )
        )
    return findings


def check_tracked_sensitive_files() -> CheckResult:
    """Fail if a common credential or private-key filename is tracked by Git."""

    result = run_git("ls-files")
    if result.returncode != 0:
        return CheckResult(
            "Sensitive files", Status.WARN, "could not inspect Git-tracked files"
        )
    tracked = [Path(line) for line in result.stdout.splitlines()]
    sensitive = [
        path.as_posix()
        for path in tracked
        if path.name.lower() in SENSITIVE_FILENAMES
        or path.suffix.lower() in SENSITIVE_SUFFIXES
    ]
    if sensitive:
        return CheckResult(
            "Sensitive files",
            Status.FAIL,
            f"tracked sensitive file(s): {', '.join(sensitive)}",
        )
    return CheckResult(
        "Sensitive files",
        Status.PASS,
        "no common credential or private-key files are tracked",
    )


def check_env_hygiene() -> list[CheckResult]:
    """Verify that environment files are ignored and safely excluded from image builds."""

    results: list[CheckResult] = []
    ignored = run_git("check-ignore", "-q", ".env").returncode == 0
    results.append(
        CheckResult(
            ".env Git protection",
            Status.PASS if ignored else Status.FAIL,
            ".env is ignored by Git" if ignored else ".env is not ignored by Git",
        )
    )

    dockerignore = PROJECT_ROOT / ".dockerignore"
    docker_text = (
        dockerignore.read_text(encoding="utf-8", errors="replace")
        if dockerignore.is_file()
        else ""
    )
    excluded = any(
        line.strip() in {".env", ".env.*"} for line in docker_text.splitlines()
    )
    results.append(
        CheckResult(
            ".env image protection",
            Status.PASS if excluded else Status.WARN,
            ".env is excluded from Docker build context"
            if excluded
            else ".env is not excluded by .dockerignore",
        )
    )

    example = PROJECT_ROOT / ".env.example"
    results.append(
        CheckResult(
            ".env example",
            Status.PASS if example.is_file() else Status.WARN,
            ".env.example is available"
            if example.is_file()
            else "add a placeholder-only .env.example for safe setup",
        )
    )
    return results


def check_airflow_defaults() -> list[CheckResult]:
    """Detect insecure Airflow credential fallbacks in the Compose definition."""

    compose_file = PROJECT_ROOT / "docker" / "compose.yml"
    if not compose_file.is_file():
        return [
            CheckResult(
                "Airflow defaults", Status.SKIP, "docker/compose.yml is not present"
            )
        ]
    text = compose_file.read_text(encoding="utf-8", errors="replace")
    checks = (
        ("AIRFLOW__API_AUTH__JWT_SECRET", "Airflow JWT secret has a default fallback"),
        (
            "POSTGRES_PASSWORD: airflow",
            "Airflow metadata Postgres uses the default password",
        ),
        (
            "_AIRFLOW_WWW_USER_PASSWORD:-airflow",
            "Airflow UI user has a default password fallback",
        ),
    )
    findings = [
        CheckResult("Airflow defaults", Status.WARN, description)
        for marker, description in checks
        if marker in text
    ]
    return findings or [
        CheckResult(
            "Airflow defaults", Status.PASS, "no known insecure default values found"
        )
    ]


def check_docker_users() -> list[CheckResult]:
    """Check whether each Dockerfile declares a non-root final user."""

    results: list[CheckResult] = []
    for path in (PROJECT_ROOT / "docker").glob("Dockerfile*"):
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        users = [
            line.split(maxsplit=1)[1].strip()
            for line in lines
            if re.match(r"^\s*USER\s+", line, re.IGNORECASE)
        ]
        last_user = users[-1] if users else "root (implicit)"
        status = (
            Status.PASS
            if last_user.lower() not in {"root", "0", "root (implicit)"}
            else Status.WARN
        )
        detail = f"{display_path(path)} final user: {last_user}"
        results.append(CheckResult("Docker runtime user", status, detail))
    return results or [
        CheckResult("Docker runtime user", Status.SKIP, "no Dockerfiles found")
    ]


def check_dependency_lock() -> CheckResult:
    """Confirm that the uv dependency lockfile is committed alongside project metadata."""

    pyproject = PROJECT_ROOT / "pyproject.toml"
    lockfile = PROJECT_ROOT / "uv.lock"
    if pyproject.is_file() and lockfile.is_file():
        return CheckResult(
            "Dependency lock", Status.PASS, "pyproject.toml and uv.lock are present"
        )
    return CheckResult(
        "Dependency lock",
        Status.WARN,
        "commit uv.lock with pyproject.toml to pin dependencies",
    )


def check_ci_scanning() -> CheckResult:
    """Report whether CI declares a secret, dependency, or container scanner."""

    workflows = list((PROJECT_ROOT / ".github" / "workflows").glob("*.yml"))
    text = "\n".join(
        path.read_text(encoding="utf-8", errors="replace") for path in workflows
    )
    scanners = ("gitleaks", "trivy", "bandit", "pip-audit")
    present = [scanner for scanner in scanners if scanner in text.lower()]
    if present:
        return CheckResult(
            "CI security scanning",
            Status.PASS,
            f"configured scanner(s): {', '.join(present)}",
        )
    return CheckResult(
        "CI security scanning",
        Status.WARN,
        "add Gitleaks, Bandit, pip-audit, or Trivy to CI",
    )


def render_report(results: list[CheckResult]) -> None:
    """Render the security report and a concise aggregate result with Rich."""

    console = Console()
    styles = {
        Status.PASS: "green",
        Status.WARN: "yellow",
        Status.FAIL: "red",
        Status.SKIP: "dim",
    }
    markers = {Status.PASS: "OK", Status.WARN: "!", Status.FAIL: "X", Status.SKIP: "-"}
    table = Table(title="Walmart Medallion Pipeline Security Check", show_lines=True)
    table.add_column("Control", style="bold cyan", no_wrap=True)
    table.add_column("Status", justify="center", no_wrap=True)
    table.add_column("Detail")
    for result in results:
        table.add_row(
            result.control,
            Text(
                f"{markers[result.status]} {result.status}", style=styles[result.status]
            ),
            result.detail,
        )
    console.print(table)

    counts = {
        status: sum(result.status == status for result in results) for status in Status
    }
    if counts[Status.FAIL]:
        headline, style = "SECURITY ACTION NEEDED", "bold red"
    elif counts[Status.WARN]:
        headline, style = "NO LEAKS FOUND; HARDENING RECOMMENDED", "bold yellow"
    else:
        headline, style = "SECURITY BASELINE PASSED", "bold green"
    summary = f"{headline}: {counts[Status.PASS]} passed, {counts[Status.WARN]} warning(s), {counts[Status.FAIL]} failed, {counts[Status.SKIP]} skipped"
    console.print(
        Panel(
            Text(summary, style=style),
            title="Overall summary",
            border_style=style.split()[-1],
        )
    )


def main() -> int:
    """Run project security controls and return non-zero when a leak is found."""

    parser = argparse.ArgumentParser(
        description="Check the local Walmart ETL project for common security risks."
    )
    parser.parse_args()
    results = [
        *check_secret_scan(),
        check_tracked_sensitive_files(),
        *check_env_hygiene(),
        *check_airflow_defaults(),
        *check_docker_users(),
        check_dependency_lock(),
        check_ci_scanning(),
    ]
    render_report(results)
    return 1 if any(result.status == Status.FAIL for result in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())

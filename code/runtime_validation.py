"""Shared runtime diagnostics for the fly-brain CLI surfaces."""

from __future__ import annotations

import contextlib
import importlib
import io
import platform
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Sequence, Tuple


class RuntimeDependencyError(RuntimeError):
    """Raised when an optional runtime surface is not installed correctly."""


@dataclass(frozen=True)
class RuntimeCheck:
    name: str
    available: bool
    summary: str
    details: Tuple[str, ...] = ()


def format_import_exception(exc: Exception) -> str:
    message = str(exc).strip()
    if not message:
        return exc.__class__.__name__
    return f"{exc.__class__.__name__}: {message}"


def evaluate_runtime(
    name: str,
    module_names: Sequence[str] = (),
    install_hint: Optional[str] = None,
    required_paths: Sequence[Tuple[Path, str]] = (),
) -> RuntimeCheck:
    module_failures = []
    module_successes = []
    path_failures = []
    path_successes = []

    for module_name in module_names:
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                importlib.import_module(module_name)
        except Exception as exc:  # pragma: no cover - import failures depend on local env
            module_failures.append(f"{module_name} ({format_import_exception(exc)})")
        else:
            module_successes.append(module_name)

    for path, label in required_paths:
        if path.exists():
            path_successes.append(f"{label}: {path}")
        else:
            path_failures.append(f"{label}: {path}")

    details = []
    if module_successes:
        details.append("Imported modules: " + ", ".join(module_successes))
    if path_successes:
        details.append("Found paths: " + ", ".join(path_successes))
    if module_failures:
        details.append("Missing modules: " + "; ".join(module_failures))
    if path_failures:
        details.append("Missing paths: " + "; ".join(path_failures))
    if install_hint:
        details.append("Install hint: " + install_hint)

    failures = []
    if module_failures:
        failures.append("modules unavailable")
    if path_failures:
        failures.append("required files missing")

    summary = "ready" if not failures else "; ".join(failures)
    return RuntimeCheck(
        name=name,
        available=not failures,
        summary=summary,
        details=tuple(details),
    )


def require_runtime(
    module_names: Sequence[str],
    install_hint: str,
    error_type: type[RuntimeDependencyError] = RuntimeDependencyError,
) -> None:
    check = evaluate_runtime(
        name="runtime",
        module_names=module_names,
        install_hint=install_hint,
    )
    if not check.available:
        reason = next(
            (detail for detail in check.details if detail.startswith("Missing modules:")),
            check.summary,
        )
        raise error_type(f"{reason}. {install_hint}")


def ready_runtime_check(name: str, detail: str) -> RuntimeCheck:
    return RuntimeCheck(name=name, available=True, summary="ready", details=(detail,))


def runtime_environment_lines() -> Tuple[str, ...]:
    return (
        f"Python: {sys.version.split()[0]} ({sys.executable})",
        f"Platform: {platform.platform()}",
    )


def format_runtime_report(title: str, checks: Sequence[RuntimeCheck]) -> str:
    lines = [title, *runtime_environment_lines(), ""]
    for check in checks:
        status = "ready" if check.available else "missing"
        lines.append(f"[{status}] {check.name}: {check.summary}")
        for detail in check.details:
            lines.append(f"  - {detail}")
        lines.append("")
    return "\n".join(lines).rstrip()

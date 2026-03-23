import sys
import csv
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "code"))

import benchmark  # noqa: E402
import main as main_cli  # noqa: E402
from runtime_validation import evaluate_runtime, format_runtime_report, ready_runtime_check  # noqa: E402


def test_evaluate_runtime_reports_missing_modules_and_paths(tmp_path):
    existing_path = tmp_path / "existing.txt"
    existing_path.write_text("ok", encoding="utf-8")

    check = evaluate_runtime(
        name="Demo runtime",
        module_names=("json", "definitely_missing_runtime_module_12345"),
        install_hint="Install the demo runtime.",
        required_paths=(
            (existing_path, "Existing file"),
            (tmp_path / "missing.txt", "Missing file"),
        ),
    )

    assert not check.available
    assert check.summary == "modules unavailable; required files missing"
    assert any("Imported modules: json" in detail for detail in check.details)
    assert any(
        "definitely_missing_runtime_module_12345" in detail
        for detail in check.details
    )
    assert any("Missing file" in detail for detail in check.details)

    report = format_runtime_report(
        "Demo validation",
        [check, ready_runtime_check("Ready runtime", "All dependencies are available.")],
    )
    assert "Demo validation" in report
    assert "[missing] Demo runtime: modules unavailable; required files missing" in report
    assert "[ready] Ready runtime: ready" in report


def test_build_backend_skip_results_expands_requested_matrix():
    results = benchmark.build_backend_skip_results(
        t_run_values=[0.1, 1.0],
        n_run_values=[1, 3],
        status="unavailable: test preflight",
    )

    assert len(results) == 4
    assert {(result["t_run_sec"], result["n_run"]) for result in results} == {
        (0.1, 1),
        (0.1, 3),
        (1.0, 1),
        (1.0, 3),
    }
    assert all(result["status"] == "unavailable: test preflight" for result in results)


def test_save_result_csv_preserves_legacy_rt_ratio_rows(tmp_path, monkeypatch):
    csv_path = tmp_path / "benchmark-results.csv"
    csv_path.write_text(
        "framework,n_run,t_run,setup_time,build_time,sim_time,total_time,rt_ratio,spikes,active_neurons,status,timestamp\n"
        "Legacy,1,0.1,1.0,0.0,2.0,3.0,0.5,10,5,success,2026-03-01 12:00:00\n",
        encoding="utf-8",
    )

    monkeypatch.setattr(benchmark, "csv_path", csv_path)
    monkeypatch.setattr(benchmark, "path_res", tmp_path / "results")

    benchmark.save_result_csv(
        "PyTorch",
        {
            "n_run": 2,
            "t_run_sec": 1.0,
            "timings": {
                "network_creation_total": 4.0,
                "device_build": 0.5,
                "simulation_total": 6.0,
                "total_elapsed": 10.5,
                "realtime_ratio": 0.75,
            },
            "n_spikes": 123,
            "n_active_neurons": 45,
            "status": "unavailable: modules unavailable",
        },
    )

    with csv_path.open("r", newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    assert rows[0]["framework"] == "Legacy"
    assert rows[0]["rt_ratio"] == "0.5"
    assert rows[1]["framework"] == "PyTorch"
    assert rows[1]["rt_ratio"] == "0.75"
    assert rows[1]["status"] == "unavailable: modules unavailable"


def test_main_validate_returns_zero_when_checks_are_ready(monkeypatch, capsys):
    checks = [
        ready_runtime_check("Benchmark data", "All required benchmark files are present."),
        ready_runtime_check("PyTorch", "Torch stack is available."),
    ]

    monkeypatch.setattr(
        main_cli.benchmark_runner,
        "collect_benchmark_runtime_checks",
        lambda backends: checks,
    )
    monkeypatch.setattr(
        main_cli.benchmark_runner,
        "format_benchmark_runtime_report",
        lambda backends: "Benchmark runtime validation\n[ready] PyTorch: ready",
    )

    exit_code = main_cli.main(["--validate", "--pytorch"])

    captured = capsys.readouterr()
    assert exit_code == 0
    assert "Benchmark runtime validation" in captured.out


def test_main_validate_returns_one_when_a_check_is_missing(monkeypatch, capsys):
    checks = [
        ready_runtime_check("Benchmark data", "All required benchmark files are present."),
        evaluate_runtime(
            name="PyTorch",
            module_names=("definitely_missing_runtime_module_67890",),
            install_hint="Install torch.",
        ),
    ]

    monkeypatch.setattr(
        main_cli.benchmark_runner,
        "collect_benchmark_runtime_checks",
        lambda backends: checks,
    )
    monkeypatch.setattr(
        main_cli.benchmark_runner,
        "format_benchmark_runtime_report",
        lambda backends: "Benchmark runtime validation\n[missing] PyTorch: modules unavailable",
    )

    exit_code = main_cli.main(["--validate", "--pytorch"])

    captured = capsys.readouterr()
    assert exit_code == 1
    assert "[missing] PyTorch" in captured.out

"""
Drosophila brain model benchmark runner.

Usage:
    # All backends, default experiment (Sugar GRNs 200 Hz)
    python3 main.py

    # Run the embodied MuJoCo/FlyGym bridge instead of the benchmark suite
    python3 main.py --embodied --steps 240 --packet-path ~/vision_pro_pose_packet.json

    # P9 forward-walking experiment instead
    python3 main.py --experiment p9

    # Specific durations and trial count
    python3 main.py --t_run 0.1 1 10 --n_run 1

    # Specific backends (combinable)
    python3 main.py --brian2-cpu                         # Brian2 CPU only
    python3 main.py --brian2cuda-gpu                     # Brian2CUDA GPU only
    python3 main.py --pytorch                            # PyTorch only
    python3 main.py --nestgpu                            # NEST GPU only
    python3 main.py --brian2-cpu --pytorch --nestgpu     # Brian2 CPU + PyTorch + NEST GPU

    # Background with log
    nohup python3 main.py > data/results/benchmarks.log 2>&1 &
"""

import os
os.environ['PYTHONUNBUFFERED'] = '1'

import warnings
warnings.filterwarnings('ignore', category=UserWarning)

import sys
import argparse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / 'code'))

import benchmark as benchmark_runner


def build_arg_parser():
    parser = argparse.ArgumentParser(description='Drosophila brain model benchmark')
    parser.add_argument('--t_run', type=float, nargs='+', default=None,
                        help='Simulation duration(s) in seconds. '
                             f'Allowed: {benchmark_runner.T_RUN_VALUES_SEC}. Default: all')
    parser.add_argument('--n_run', type=int, nargs='+', default=None,
                        help='Number of trials. Default: [1, 30]')
    parser.add_argument('--log_file', type=str, default='data/results/benchmarks.log',
                        help='Log file path. Default: data/results/benchmarks.log')
    parser.add_argument('--no_log_file', action='store_true',
                        help='Disable file logging (console only)')
    parser.add_argument('--validate', action='store_true',
                        help='Validate runtime dependencies and data files for the selected backends, then exit.')

    parser.add_argument('--experiment', type=str, default=None,
                        choices=list(benchmark_runner.EXPERIMENTS.keys()),
                        help='Experiment to run. '
                             f'Available: {list(benchmark_runner.EXPERIMENTS.keys())}. '
                             'Default: sugar')

    parser.add_argument('--brian2-cpu', action='store_true',
                        help='Run Brian2 C++ standalone (CPU)')
    parser.add_argument('--brian2cuda-gpu', action='store_true',
                        help='Run Brian2CUDA (GPU)')
    parser.add_argument('--pytorch', action='store_true',
                        help='Run PyTorch benchmark')
    parser.add_argument('--nestgpu', action='store_true',
                        help='Run NEST GPU benchmark')
    return parser


def resolve_backends(args):
    if not (args.brian2_cpu or args.brian2cuda_gpu or args.pytorch or args.nestgpu):
        return ['cpu', 'gpu', 'pytorch', 'nestgpu']

    backends = []
    if args.brian2_cpu:
        backends.append('cpu')
    if args.brian2cuda_gpu:
        backends.append('gpu')
    if args.pytorch:
        backends.append('pytorch')
    if args.nestgpu:
        backends.append('nestgpu')
    return backends


def validate_benchmark_runtime(backends):
    print(benchmark_runner.format_benchmark_runtime_report(backends))
    checks = benchmark_runner.collect_benchmark_runtime_checks(backends)
    return 0 if all(check.available for check in checks) else 1


def main(argv=None):
    argv = list(argv) if argv is not None else sys.argv[1:]

    if '--embodied' in argv:
        from embodied_simulation import main as embodied_main

        embodied_args = [arg for arg in argv if arg != '--embodied']
        return embodied_main(embodied_args)

    parser = build_arg_parser()
    args = parser.parse_args(argv)
    backends = resolve_backends(args)

    # Validate t_run values
    t_run_values = args.t_run
    if t_run_values:
        for val in t_run_values:
            if val not in benchmark_runner.T_RUN_VALUES_SEC:
                print(
                    f"Error: --t_run {val} is not in allowed values: "
                    f"{benchmark_runner.T_RUN_VALUES_SEC}"
                )
                return 1

    if args.validate:
        return validate_benchmark_runtime(backends)

    experiment = benchmark_runner.get_experiment(args.experiment)

    log_file = None if args.no_log_file else args.log_file
    logger = benchmark_runner.BenchmarkLogger(log_file=log_file)

    try:
        logger.log_raw("")
        logger.log("Starting benchmark suite")
        logger.log(
            f"Backends: {', '.join(benchmark_runner.BACKEND_NAMES[b] for b in backends)}"
        )
        t_run_display = t_run_values if t_run_values else benchmark_runner.T_RUN_VALUES_SEC
        logger.log(f"t_run values: {t_run_display}s")
        logger.log(f"n_run values: {args.n_run or [1, 30]}")
        logger.log(f"Log file: {log_file if log_file else 'disabled'}")

        results = benchmark_runner.run_benchmarks(
            backends=backends,
            t_run_values=t_run_values,
            n_run_values=args.n_run,
            experiment=experiment,
            logger=logger,
        )

    finally:
        logger.close()

    all_statuses = [
        result.get("status")
        for backend_results in results.values()
        for result in backend_results
    ]
    return 0 if all(status == "success" for status in all_statuses) else 1


if __name__ == '__main__':
    raise SystemExit(main())

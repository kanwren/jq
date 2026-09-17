#!/usr/bin/env python3
"""Benchmark reduce's conditional stack cleanup.

This is intentionally not part of `make check`.  It is a local benchmark for
changes around DUPN/LOADVN and the forkpoint reachability check.
"""

import argparse
import os
import statistics
import subprocess
import sys
import time


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def live_continuations(depth):
    parts = ["label $out"]
    for i in range(depth):
        parts.append(f"range(0;2) as $v{i}")
    return " | ".join(parts)


def stress_filter(depth, iterations, reduce_items):
    prefix = live_continuations(depth)
    # The outer range repeats a tiny reduce while the generated range
    # continuations remain live.  The final break prevents backtracking into
    # the exponential number of outer range combinations.
    return (
        f"{prefix} | "
        f"range(0;{iterations}) as $i | "
        f"(0 | reduce range(0;{reduce_items}) as $x (0; . + 1)) | "
        f"if $i == {iterations - 1} then break $out else empty end"
    )


def common_filter(iterations):
    return f"reduce range(0;{iterations}) as $x (0; . + 1)"


def regression_filter(iterations):
    return f"range(0;{iterations}) | ([1] | reduce .[] as $x (., .; .)) | empty"


def run_case(jq, name, filt, reps, warmups):
    cmd = [jq, "-n", filt]
    for _ in range(warmups):
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)

    times = []
    for _ in range(reps):
        start = time.perf_counter()
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        times.append(time.perf_counter() - start)

    return {
        "name": name,
        "best": min(times),
        "median": statistics.median(times),
        "all": times,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jq", default=os.path.join(repo_root(), "jq"))
    parser.add_argument("--reps", type=int, default=5)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--common-iters", type=int, default=200000)
    parser.add_argument("--stress-iters", type=int, default=20000)
    parser.add_argument("--reduce-items", type=int, default=1)
    parser.add_argument("--depths", default="0,10,50,100,250")
    parser.add_argument("--show-filters", action="store_true")
    args = parser.parse_args()

    depths = [int(d) for d in args.depths.split(",") if d]
    cases = [
        ("common_reduce", common_filter(args.common_iters)),
        ("reported_regression_loop", regression_filter(args.stress_iters)),
    ]
    for depth in depths:
        cases.append((
            f"stress_depth_{depth}",
            stress_filter(depth, args.stress_iters, args.reduce_items),
        ))

    print(f"jq: {args.jq}")
    print(f"reps: {args.reps}, warmups: {args.warmups}")
    print("case,best_s,median_s")
    for name, filt in cases:
        if args.show_filters:
            print(f"# {name}: {filt}", file=sys.stderr)
        try:
            result = run_case(args.jq, name, filt, args.reps, args.warmups)
            print(f"{result['name']},{result['best']:.6f},{result['median']:.6f}")
        except subprocess.CalledProcessError as e:
            print(f"{name},ERROR exit={e.returncode},ERROR exit={e.returncode}")


if __name__ == "__main__":
    main()

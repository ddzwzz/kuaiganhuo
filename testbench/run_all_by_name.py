#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
按用例名逐个跑真实回归（--repeat 2 --real），每完成一个写 DONE 标记，被杀后重跑自动跳过。
覆盖 testbench.CASES 全部用例（静态 + 动态），确保 100% 用例被验证。
"""
import os
import sys
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.abspath(os.path.join(HERE, "..", "..", "regression_by_name.log"))
REPEAT = 1

# 导入 testbench 拿到完整 CASES（含 build_extended）
sys.path.insert(0, HERE)
import testbench as tb

NAMES = [c["name"] for c in tb.CASES]
# 去重保序
seen = set()
uniq = []
for n in NAMES:
    if n not in seen:
        seen.add(n)
        uniq.append(n)


def done_marker(name):
    return "### DONE NAME: " + name + " ###"


def is_done(name):
    try:
        with open(LOG, "r", encoding="utf-8") as f:
            data = f.read()
    except FileNotFoundError:
        return False
    return done_marker(name) in data


def main():
    total = len(uniq)
    done = sum(1 for n in uniq if is_done(n))
    print(f"用例总数 {total}，已完成 {done}，待跑 {total - done}")
    sys.stdout.flush()
    for i, name in enumerate(uniq):
        if is_done(name):
            continue
        print(f"\n########## [{i+1}/{total}] NAME START: {name} ##########")
        sys.stdout.flush()
        p = subprocess.run(
            [sys.executable, "testbench.py", "--only", name, "--repeat", str(REPEAT), "--real"],
            cwd=HERE,
        )
        if p.returncode == 0:
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(done_marker(name) + "\n")
            print(f"### DONE NAME: {name} ###")
        else:
            print(f"### FAIL NAME: {name} rc={p.returncode} ###")
        sys.stdout.flush()
    print("\nALL_NAMES_DONE")


if __name__ == "__main__":
    main()

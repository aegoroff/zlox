#!/bin/bash

# Run Crafting Interpreters reference tests against zlox.
# Usage: ./test-lox.sh [filter]
#
# Exit codes are checked too: 65 for a failed compilation, 70 for a runtime
# error, 0 otherwise. A debug build maps every error to 1, so against such a
# binary the exact codes are skipped and only "failed at all" is required.
#
# Optional environment variables:
#   CRAFTING_INTERPRETERS - path to craftinginterpreters repo
#   ZLOX                  - path to zlox binary

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ZLOX="${ZLOX:-$ROOT/zig-out/bin/zlox}"
TEST_ROOT="${CRAFTING_INTERPRETERS:-/home/egr/code/craftinginterpreters}/test"
FILTER="${1:-}"

if [[ ! -x "$ZLOX" ]]; then
    echo "Error: zlox binary not found at '$ZLOX'. Run 'zig build' first." >&2
    exit 1
fi

if [[ ! -d "$TEST_ROOT" ]]; then
    echo "Error: test directory not found at '$TEST_ROOT'." >&2
    echo "Set CRAFTING_INTERPRETERS to the craftinginterpreters repo path." >&2
    exit 1
fi

export ROOT ZLOX TEST_ROOT FILTER

python3 - <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.environ["ROOT"])
ZLOX = os.environ["ZLOX"]
TEST_ROOT = Path(os.environ["TEST_ROOT"])
FILTER = os.environ.get("FILTER", "")

SKIP_PREFIXES = ("test/scanning", "test/expressions")
EXPECT_RE = re.compile(r"// expect: ?(.*)")
RUNTIME_ERR_RE = re.compile(r"// expect runtime error: (.+)")
# A compile error is marked either plainly or with the line it is reported
# at, which for some tests differs per implementation: "// [line 3] Error",
# "// [c line 3] Error".
COMPILE_ERR_RE = re.compile(r"// (\[[^\]]*line \d+\] )?Error")
NONTTEST_RE = re.compile(r"// nontest")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

EXIT_OK = 0
EXIT_COMPILE_ERROR = 65
EXIT_RUNTIME_ERROR = 70


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def checks_exit_codes() -> bool:
    """A debug build funnels every error to exit code 1, so the documented
    65 and 70 are only meaningful for a release binary. One failing program
    through stdin tells the two apart."""
    probe = subprocess.run([ZLOX], input="var\n", capture_output=True, text=True)
    return probe.returncode == EXIT_COMPILE_ERROR


def classify(path: Path):
    rel = path.relative_to(TEST_ROOT.parent).as_posix()
    if "benchmark" in rel:
        return "skip"
    for prefix in SKIP_PREFIXES:
        if rel.startswith(prefix):
            return "skip"
    if FILTER and not rel.removeprefix("test/").startswith(FILTER):
        return "skip"

    text = path.read_text()
    if NONTTEST_RE.search(text):
        return "skip"

    expects = EXPECT_RE.findall(text)
    runtime = RUNTIME_ERR_RE.search(text)
    compile_err = COMPILE_ERR_RE.search(text)

    # A test can print before it dies, so an expected runtime error travels
    # along with the output it is checked against.
    if expects:
        return ("output", expects, runtime.group(1) if runtime else None)
    if runtime:
        return ("runtime", runtime.group(1))
    if compile_err:
        return ("compile", None)
    return "skip"


def run(path: Path):
    result = subprocess.run([ZLOX, str(path)], capture_output=True, text=True)
    output = result.stdout.splitlines()
    if output and output[-1] == "":
        output = output[:-1]
    combined = strip_ansi(result.stdout + result.stderr)
    return result.returncode, output, combined.splitlines()


def exit_ok(code: int, expected: int) -> bool:
    if expected == EXIT_OK:
        return code == EXIT_OK
    return code == expected if strict_exits else code != EXIT_OK


strict_exits = checks_exit_codes()
passed = failed = skipped = 0
failures = []

for path in sorted(TEST_ROOT.rglob("*.lox")):
    kind = classify(path)
    if kind == "skip":
        skipped += 1
        continue

    rel = path.relative_to(TEST_ROOT.parent).as_posix()
    code, output, combined = run(path)

    if kind[0] == "output":
        expects, message = kind[1], kind[2]
        expected_code = EXIT_RUNTIME_ERROR if message else EXIT_OK
        reported = message is None or any(message in line for line in combined)
        if output == expects and reported and exit_ok(code, expected_code):
            passed += 1
        else:
            failed += 1
            failures.append((rel, "output", expects, output, f"exit {code}, expected {expected_code}"))
    elif kind[0] == "runtime":
        message = kind[1]
        if exit_ok(code, EXIT_RUNTIME_ERROR) and any(message in line for line in combined):
            passed += 1
        else:
            failed += 1
            failures.append((rel, "runtime", message, combined[:6], f"exit {code}, expected {EXIT_RUNTIME_ERROR}"))
    elif kind[0] == "compile":
        if exit_ok(code, EXIT_COMPILE_ERROR):
            passed += 1
        else:
            failed += 1
            failures.append((rel, "compile", "expected compile error", output, f"exit {code}, expected {EXIT_COMPILE_ERROR}"))

print("=== zlox reference tests ===")
if not strict_exits:
    print("Note: binary does not use release exit codes, checking only failure vs success.")
print(f"Passed:  {passed}")
print(f"Failed:  {failed}")
print(f"Skipped: {skipped}")
print()

if failures:
    print("Failures:")
    for rel, kind, *rest in failures:
        print(f"  {rel} [{kind}]")
        for item in rest:
            if isinstance(item, list):
                for line in item:
                    print(f"    {line}")
            else:
                print(f"    {item}")
    sys.exit(1)

print("All runnable reference tests passed.")
PY

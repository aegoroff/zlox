#!/bin/bash

# Benchmark script for comparing Lox implementations using poop
# Usage: ./bench.sh <lox_file>

if [ -z "$1" ]; then
    echo "Usage: $0 <lox_file>"
    exit 1
fi

LOX_FILE="$1"

if [ ! -f "$LOX_FILE" ]; then
    echo "Error: File '$LOX_FILE' not found"
    exit 1
fi

poop \
    "./zig-out/bin/zlox $LOX_FILE" \
    "/home/egr/code/rlox/target/release/rlox c $LOX_FILE" \
    "/home/egr/code/craftinginterpreters/build/clox $LOX_FILE"
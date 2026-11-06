#!/bin/bash

# Build j2me_api.jar for the iOS MiniJVM runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MINIJVM_RT="$ROOT_DIR/J2MEEmulator/Resources/jars/minijvm_rt.jar"
OUTPUT_DIR="$ROOT_DIR/J2MEEmulator/Resources/jars"

CLASSES_DIR="$SCRIPT_DIR/classes"
SOURCES_FILE="$SCRIPT_DIR/sources.txt"

if ! command -v javac >/dev/null 2>&1; then
    echo "ERROR: javac is required. Install JDK 17."
    exit 1
fi

if ! command -v jar >/dev/null 2>&1; then
    echo "ERROR: jar command is required. Install JDK 17."
    exit 1
fi

if [ ! -s "$MINIJVM_RT" ]; then
    echo "ERROR: MiniJVM runtime not found: $MINIJVM_RT"
    exit 1
fi

rm -rf "$CLASSES_DIR"

mkdir -p "$CLASSES_DIR"
mkdir -p "$OUTPUT_DIR"

find "$SCRIPT_DIR/src" \
    -type f \
    -name '*.java' \
    | sort > "$SOURCES_FILE"

if [ ! -s "$SOURCES_FILE" ]; then
    echo "ERROR: No Java sources found in $SCRIPT_DIR/src"
    exit 1
fi

echo "Compiling J2ME API sources against:"
echo "$MINIJVM_RT"

javac --release 8 \
    -encoding UTF-8 \
    -classpath "$MINIJVM_RT" \
    -d "$CLASSES_DIR" \
    @"$SOURCES_FILE"

jar cf "$OUTPUT_DIR/j2me_api.jar" \
    -C "$CLASSES_DIR" .

if [ ! -s "$OUTPUT_DIR/j2me_api.jar" ]; then
    echo "ERROR: j2me_api.jar was not generated."
    exit 1
fi

rm -f "$SOURCES_FILE"

echo "Built: $OUTPUT_DIR/j2me_api.jar"

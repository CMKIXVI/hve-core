#!/usr/bin/env bash
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT

set -euo pipefail

show_usage() {
  echo "Usage: ${0##*/} [OPTIONS]"
  echo "  --input, -i      Path to pr-reference.xml"
  echo "  --chunk, -c      Chunk number"
  echo "  --chunk-size, -s Lines per chunk (default: 500)"
  echo "  --lines, -l      Line range START,END or START-END"
  echo "  --file, -f       Extract diff for a file"
  echo "  --summary        Show diff summary"
  echo "  --info           Show chunk information"
  echo "  --help, -h       Show this help"
  exit 1
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
INPUT_FILE="${REPO_ROOT}/.copilot-tracking/pr/pr-reference.xml"
CHUNK_NUM=""
CHUNK_SIZE=500
LINE_RANGE=""
FILE_PATH=""
SHOW_SUMMARY=false
SHOW_INFO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input|-i) INPUT_FILE="$2"; shift 2 ;;
    --chunk|-c) CHUNK_NUM="$2"; shift 2 ;;
    --chunk-size|-s) CHUNK_SIZE="$2"; shift 2 ;;
    --lines|-l) LINE_RANGE="$2"; shift 2 ;;
    --file|-f) FILE_PATH="$2"; shift 2 ;;
    --summary) SHOW_SUMMARY=true; shift ;;
    --info) SHOW_INFO=true; shift ;;
    --help|-h) show_usage ;;
    *) echo "Unknown option: $1" >&2; show_usage ;;
  esac
done

if [[ ! -f "${INPUT_FILE}" ]]; then
  echo "Error: PR reference file not found: ${INPUT_FILE}" >&2
  echo "Run generate.sh first to create the PR reference." >&2
  exit 1
fi

TOTAL_LINES=$(wc -l < "${INPUT_FILE}" | awk '{print $1}')
TOTAL_CHUNKS=$(( (TOTAL_LINES + CHUNK_SIZE - 1) / CHUNK_SIZE ))

if [[ "${SHOW_INFO}" == "true" ]]; then
  echo "File: ${INPUT_FILE}"
  echo "Total lines: ${TOTAL_LINES}"
  echo "Chunk size: ${CHUNK_SIZE}"
  echo "Total chunks: ${TOTAL_CHUNKS}"
  echo ""
  echo "Chunk breakdown:"
  for ((i=1; i<=TOTAL_CHUNKS; i++)); do
    start=$(( (i - 1) * CHUNK_SIZE + 1 ))
    end=$(( i * CHUNK_SIZE )); [[ $end -gt $TOTAL_LINES ]] && end=$TOTAL_LINES
    echo "  Chunk ${i}: lines ${start}-${end}"
  done
  exit 0
fi

normalize_diff() {
  sed -E 's/^  (diff --git|--- |\+\+\+ |@@ |\+|-| )/\1/' "${INPUT_FILE}"
}

if [[ "${SHOW_SUMMARY}" == "true" ]]; then
  echo "Changed files:"
  awk '
    function flush() {
      if (path != "") printf "%s\t%d\t%d\n", path, added, removed
    }
    function clean(s) {
      sub(/^a\//, "", s); sub(/^b\//, "", s); return s
    }
    /^diff --git([[:space:]]|$)/ {
      if (seen++) flush()
      path=""; old=""; new=""; added=0; removed=0; in_hunk=0
      next
    }
    /^---[[:space:]]/ {
      if (old=="") { old=$0; sub(/^---[[:space:]]+/, "", old); old=clean(old) }
      next
    }
    /^\+\+\+[[:space:]]/ {
      if (new=="") { new=$0; sub(/^\+\+\+[[:space:]]+/, "", new); new=clean(new) }
      next
    }
    /^@@([[:space:]]|$)/ { in_hunk=1; next }
    in_hunk && /^\+/ { added++; next }
    in_hunk && /^-/ { removed++; next }
    END {
      if (new != "") path=new; else path=old
      flush()
    }
  ' < <(normalize_diff) |
  LC_ALL=C sort -t $'\t' -k1,1 |
  awk -F '\t' '{ printf "  %s (+%d/-%d)\n", $1, $2, $3 }'
  exit 0
fi

if [[ -n "${FILE_PATH}" ]]; then
  awk -v wanted="${FILE_PATH}" '
    function clean(s) { sub(/^a\//, "", s); sub(/^b\//, "", s); return s }
    /^diff --git([[:space:]]|$)/ {
      if (printing) exit
      printing=0; old=""; new=""; block=""
    }
    { block = block $0 ORS }
    /^---[[:space:]]/ { old=$0; sub(/^---[[:space:]]+/, "", old); old=clean(old) }
    /^\+\+\+[[:space:]]/ {
      new=$0; sub(/^\+\+\+[[:space:]]+/, "", new); new=clean(new)
      if (old==wanted || new==wanted) { printf "%s", block; printing=1 }
    }
  ' < <(normalize_diff)
  exit 0
fi

if [[ -n "${CHUNK_NUM}" ]]; then
  [[ "${CHUNK_NUM}" =~ ^[0-9]+$ ]] && [[ "${CHUNK_NUM}" -ge 1 ]] || { echo "Error: Invalid chunk number: ${CHUNK_NUM}" >&2; exit 1; }
  start=$(( (CHUNK_NUM - 1) * CHUNK_SIZE + 1 )); end=$(( CHUNK_NUM * CHUNK_SIZE ))
  if [[ $start -gt $TOTAL_LINES ]]; then echo "Error: Chunk ${CHUNK_NUM} exceeds file (only ${TOTAL_CHUNKS} chunks available)" >&2; exit 1; fi
  [[ $end -gt $TOTAL_LINES ]] && end=$TOTAL_LINES
  echo "# Chunk ${CHUNK_NUM}/${TOTAL_CHUNKS} (lines ${start}-${end} of ${TOTAL_LINES})"; echo ""; sed -n "${start},${end}p" "${INPUT_FILE}"; exit 0
fi

if [[ -n "${LINE_RANGE}" ]]; then
  LINE_RANGE="${LINE_RANGE//,/-}"
  [[ "${LINE_RANGE}" =~ ^[0-9]+-[0-9]+$ ]] || { echo "Error: Invalid line range format. Use START,END or START-END" >&2; exit 1; }
  start="${LINE_RANGE%%-*}"; end="${LINE_RANGE##*-}"
  [[ $start -le $TOTAL_LINES ]] || { echo "Error: Start line ${start} exceeds file length (${TOTAL_LINES} lines)" >&2; exit 1; }
  [[ $end -gt $TOTAL_LINES ]] && end=$TOTAL_LINES
  echo "# Lines ${start}-${end} of ${TOTAL_LINES}"; echo ""; sed -n "${start},${end}p" "${INPUT_FILE}"; exit 0
fi

echo "File: ${INPUT_FILE}"
echo "Total lines: ${TOTAL_LINES}"
echo "Total chunks: ${TOTAL_CHUNKS} (at ${CHUNK_SIZE} lines/chunk)"
echo ""
echo "Use --chunk N to read a specific chunk, --lines START,END for a range,"
echo "or --file PATH to extract a specific file's diff."

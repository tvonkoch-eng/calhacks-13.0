#!/bin/sh
# Offline checks on the question gate and the speculative fire/refire policy. No Xcode target, no
# simulator — the logic under test is pure Foundation, so it builds and runs in a couple of seconds.
#   sh Tests/run.sh
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
for test in QuestionGate Speculation; do
  mkdir -p "$out/$test"
  cp "Tests/${test}Tests.swift" "$out/$test/main.swift"
  cp App/Question.swift "$out/$test/"
  swiftc -O "$out/$test/main.swift" "$out/$test/Question.swift" -o "$out/$test/run"
  printf '%s: ' "$test"
  "$out/$test/run"
done
rm -rf "$out"

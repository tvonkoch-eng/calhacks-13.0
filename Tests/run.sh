#!/bin/sh
# Offline checks: the question gate, the speculative fire/refire policy, and the conversation aid's
# pure rules (lens slots, roles, text rules, coach JSON). No Xcode target, no simulator, no network.
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
mkdir -p "$out/Aid"
cp Tests/AidTests.swift "$out/Aid/main.swift"
swiftc -O "$out/Aid/main.swift" App/Question.swift App/Answer.swift App/Coach.swift App/Lens.swift App/Aid.swift App/Tools.swift -o "$out/Aid/run"
printf 'Aid: '
"$out/Aid/run"
rm -rf "$out"

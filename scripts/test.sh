#!/bin/zsh
# テストを実行する。
#
# Command Line Tools のみの環境では、テストファイルを変更した後の最初のコンパイルが
# "plugin for module 'TestingMacros' not found" で失敗することがある（`swift test` の末尾には
# "error: fatalError" とだけ出る）。ビルドし直せば通るので、数回まで再試行する。
set -uo pipefail
cd "$(dirname "$0")/.."
for attempt in 1 2 3; do
    if swift build --build-tests >/dev/null 2>&1; then break; fi
    if [[ $attempt == 3 ]]; then swift build --build-tests; exit 1; fi
done
swift test --skip-build "$@"

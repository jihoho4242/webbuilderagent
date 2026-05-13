# Repository Quality Gate

This repository intentionally has no Gemfile, npm package, RuboCop, Sorbet, or other external static-analysis dependency.

The formal quality gate is `ruby bin/check`. It is dependency-free and must remain runnable on a clean Ruby checkout.

The gate covers:

- Ruby syntax for executable Ruby files under `bin/`, `lib/`, and `test/`
- repository text hygiene for CRLF line endings and merge conflict markers
- load smoke via `require "aiweb"`
- full Minitest suite via `ruby -Itest test/all.rb`
- Git whitespace validation via `git diff --check`

GitHub Actions and local verification must use this same entrypoint. External lint/typecheck tools can be introduced later only as an explicit dependency decision with matching CI updates.

# Contributing

1. Read `CLAUDE.md` (change rules) and `MIGRATION.md` (what is ported).
2. Keep `forge/` stdlib-only and deterministic; put tools with third-party Python deps in `scripts/`.
3. Every change to the generator, runtime, schema or a gate comes with a focused test:
   Python tests in `forge/tests/`, Dart tests in `runtime/test/`.
4. Porting a piece means: Dart construction + test + a lab screenshot read back + the
   `MIGRATION.md` row moved, in one change.
5. Run before opening a PR:

   ```bash
   python3 -m unittest discover -s forge/tests -p 'test_*.py'
   (cd runtime && flutter test && flutter analyze)
   (cd lab && flutter analyze)
   ```

6. Format Dart with `dart format` (page width 120, set in each package's `analysis_options.yaml`).

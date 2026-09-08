# Agent Guide for in_app_purchase_storekit

This document provides guidance for AI agents to effectively contribute to the `in_app_purchase_storekit` package within `flutter/packages`.

## Core Workflows

- **Documentation Lookup**:
  - Exclusively reference offline Apple StoreKit documentation served by the `local-apple-docs-dart` MCP server (`search_docs`, `read_doc_file`). Do NOT make assumptions about Apple StoreKit 2 APIs or scrape external web pages unless information is absent from the MCP server.
- **Regenerate Code**:
  - **StoreKit 2 Pigeon**: Run after modifying `pigeons/sk2_pigeon.dart`:
    ```bash
    dart run pigeon --input pigeons/sk2_pigeon.dart
    ```
  - **StoreKit 1 Messages Pigeon**: Run after modifying `pigeons/messages.dart`:
    ```bash
    dart run pigeon --input pigeons/messages.dart
    ```
  - **Serialization & Mocks**: Run after modifying classes annotated with `@JsonSerializable()`:
    ```bash
    dart run build_runner build -d
    ```
- **Verify Tests**: All tests must pass before landing.
  - **Dart Unit Tests**:
    ```bash
    dart run $REPO_ROOT/script/tool/bin/flutter_plugin_tools.dart dart-test --packages in_app_purchase_storekit
    ```
    (Or `flutter test` from the package directory).
  - **Native Unit Tests (iOS/macOS)**:
    ```bash
    dart run $REPO_ROOT/script/tool/bin/flutter_plugin_tools.dart native-test --ios --packages in_app_purchase_storekit --no-integration
    ```
- **Code Hygiene & Validation**:
  - **Format**: Always format changes before committing:
    ```bash
    dart run $REPO_ROOT/script/tool/bin/flutter_plugin_tools.dart format --packages in_app_purchase_storekit
    ```
  - **Analyze**: Run static analysis to catch lint or typing issues:
    ```bash
    dart run $REPO_ROOT/script/tool/bin/flutter_plugin_tools.dart analyze --packages in_app_purchase_storekit
    ```

## Agent Guidelines & Invariants

- **Guardrail: Automated PR Diffs**: In automated issue-to-PR flows, NEVER modify `pubspec.yaml` or `CHANGELOG.md`. Release versioning and changelog entries are managed upstream or by human reviewers.
- **SWE-bench Verification Loop**:
  - **FAIL_TO_PASS**: Prior to making changes to production code, write a unit test on clean `main` that asserts the missing property or reproduces the reported issue, and verify that the test fails.
  - **PASS_TO_PASS**: Implement the fix/mapping and verify that the new test passes and no existing package tests regress.
- **Testing Requirements**:
  - **Dart Tests**: When modifying or adding non-generated files in `lib/` (excluding `.g.dart`), add or update corresponding tests in `test/` (e.g. `test/in_app_purchase_storekit_2_platform_test.dart`).
  - **Native Unit Tests**: When modifying Swift or Objective-C files under `darwin/` (excluding `.g.swift` and `.g.m`), add or update corresponding unit tests in `example/shared/RunnerTests/` (e.g. `StoreKit2TranslatorTests.swift` or `InAppPurchaseStoreKit2PluginTests.swift`).
- **Relative Paths**: When invoking subagents or generating prompts, NEVER provide absolute file paths. ALWAYS use relative paths to prevent breaking workspace isolation.
- **Comment Style**: Do NOT add trivial comments that merely narrate what the code does in English. Only add comments when explaining non-obvious design decisions or public API doc comments (`///`).
- **Scoped Validation**: Never run global `.ci/scripts/*` or `script/tool_runner.sh` to validate changes. Always use targeted commands scoped with `--packages in_app_purchase_storekit`.

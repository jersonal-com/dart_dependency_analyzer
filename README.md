# dart_dependency_analyzer

A command-line tool to analyze Dart/Flutter project dependencies and provide a health overview using a traffic light system.

## Features

-   **Dependency Analysis:** Scans `pubspec.yaml` and `pubspec.lock` to identify direct, dev, and transitive dependencies.
-   **Traffic Light System:** Assigns a color (Green, Yellow, Red, Grey) to each dependency based on its health:
    *   **🔴 Red:**
        *   Package is discontinued on pub.dev.
        *   Package has not been updated for more than a configurable number of months (`--stale-threshold-months`).
        *   A major version update is available.
    *   **🟡 Yellow:**
        *   A minor version update is available.
    *   **🟢 Green:**
        *   Package is up-to-date (only patch updates available, or no updates).
        *   Package is whitelisted.
    *   **⚪️ Grey:**
        *   Package is a git or path dependency, or its information could not be fetched from pub.dev.
-   **Configurable Staleness:** Use the `--stale-threshold-months` option to define what constitutes a "stale" package (default: 12 months).
-   **Whitelist:** Use the `--whitelist` option to specify a comma-separated list of packages that should always be considered "Green" (e.g., `flutter,cupertino_icons`).
-   **Blocker Identification:** Attempts to identify which direct dependency of your project is preventing a transitive dependency from upgrading to its latest version.
-   **Show Details:** Use the `--show-details` flag to display additional information for each package, including current and latest version, last update date, likes, and downloads.

## Installation

To install the `dart_dependency_analyzer` globally, navigate to the project root directory and run:

```bash
dart pub global activate --source path .
```

This will make the `dart_dependency_analyzer` command available in your terminal.

## Usage

To run the analyzer, navigate to the `dart_dependency_analyzer` directory and execute:

```bash
dart run bin/dart_dependency_analyzer.dart <path_to_your_dart_project> [options]
```

Alternatively, if you have globally activated the package, you can run:

```bash
dart_dependency_analyzer <path_to_your_dart_project> [options]
```

**Example:**

```bash
dart run bin/dart_dependency_analyzer.dart ../ai_helper --stale-threshold-months=6 --whitelist=flutter,cupertino_icons
```

Or, if globally activated:

```bash
dart_dependency_analyzer ../ai_helper --stale-threshold-months=6 --whitelist=flutter,cupertino_icons
```



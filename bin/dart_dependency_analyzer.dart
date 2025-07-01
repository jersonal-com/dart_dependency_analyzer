import 'package:args/args.dart';
import 'package:yaml/yaml.dart';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ansi_styles/ansi_styles.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:dart_dependency_analyzer/src/blocker_finder.dart';

const String version = '0.0.1';

class PackageReport {
  final String name;
  String status;
  String reason;
  int sortOrder;
  String? currentVersion;
  String? latestVersion;
  DateTime? lastUpdated;
  int? likes;
  int? downloads;
  int? grantedPoints;

  PackageReport(
    this.name,
    this.status,
    this.reason,
    this.sortOrder, {
    this.currentVersion,
    this.latestVersion,
    this.lastUpdated,
    this.likes,
    this.downloads,
    this.grantedPoints,
  });
}

ArgParser buildParser() {
  return ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Show additional command output.',
    )
    ..addFlag('version', negatable: false, help: 'Print the tool version.')
    ..addOption(
      'stale-threshold-months',
      defaultsTo: '12',
      help: 'The number of months after which a package is considered stale.',
    )
    ..addOption(
      'whitelist',
      help:
          'A comma-separated list of packages to ignore (they will always be green).',
      defaultsTo: 'flutter,cupertino_icons,flutter_test',
    )
    ..addFlag(
      'show-details',
      negatable: false,
      help:
          'Show detailed information for each package (current/latest version, last update, likes, downloads).',
    )
    ..addOption(
      'min-likes',
      defaultsTo: '100',
      help: 'The minimum number of likes for a package to be considered healthy.',
    )
    ..addOption(
      'min-downloads',
      defaultsTo: '10000',
      help: 'The minimum number of downloads for a package to be considered healthy.',
    );
}

void printUsage(ArgParser argParser) {
  print('Usage: dart dart_dependency_analyzer.dart <path_to_dart_project>');
  print(argParser.usage);
}

Future<Map<String, dynamic>?> getPackageInfo(
  String packageName,
  YamlMap pubspecLockYaml,
) async {
  final lockPackage = pubspecLockYaml['packages']?[packageName];
  final source = lockPackage?['source'];

  if (source == 'git') {
    // Don't try to fetch git dependencies from pub.dev
    return null;
  }

  final url = Uri.parse('https://pub.dev/api/packages/$packageName');
  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      print(
        'Error fetching package info for $packageName: Status code ${response.statusCode}, Body: ${response.body}',
      );
    }
  } catch (e) {
    // Silently ignore packages that can\'t be fetched, e.g. flutter from a git dependency
  }
  return null;
}

Future<Map<String, dynamic>?> getPackageScore(String packageName) async {
  final url = Uri.parse('https://pub.dev/api/packages/$packageName/score');
  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      print(
        'Error fetching package score for $packageName: Status code ${response.statusCode}, Body: ${response.body}',
      );
    }
  } catch (e) {
    // Silently ignore packages that can\'t be fetched
  }
  return null;
}

void main(List<String> arguments) async {
  final ArgParser argParser = buildParser();
  try {
    final ArgResults results = argParser.parse(arguments);
    bool verbose = false;

    if (results.flag('help')) {
      printUsage(argParser);
      return;
    }
    if (results.flag('version')) {
      print('dart_dependency_analyzer version: $version');
      return;
    }
    if (results.flag('verbose')) {
      verbose = true;
    }

    if (results.rest.isEmpty) {
      printUsage(argParser);
      exit(1);
    }

    final projectPath = results.rest.first;
    final staleThresholdMonths = int.parse(results['stale-threshold-months']);
    final whitelist = results['whitelist'].split(',');
    final showDetails = results.flag('show-details');
    final minLikes = int.parse(results['min-likes']);
    final minDownloads = int.parse(results['min-downloads']);

    await analyzeDependencies(
      projectPath,
      staleThresholdMonths,
      whitelist,
      showDetails,
      verbose,
      minLikes,
      minDownloads,
    );
  } on FormatException catch (e) {
    print(e.message);
    print('');
    printUsage(argParser);
  }
}

Future<void> analyzeDependencies(
  String projectPath,
  int staleThresholdMonths,
  List<String> whitelist,
  bool showDetails,
  bool verbose,
  int minLikes,
  int minDownloads,
) async {
  final outdatedResult = Process.runSync('dart', [
    'pub',
    'outdated',
    '--json',
  ], workingDirectory: projectPath);

  final outdatedPackages = (outdatedResult.exitCode == 0)
      ? (jsonDecode(outdatedResult.stdout)['packages'] as List?) ?? []
      : [];

  final depsResult = Process.runSync('dart', [
    'pub',
    'deps',
    '--json',
  ], workingDirectory: projectPath);

  final depsJson = (depsResult.exitCode == 0)
      ? jsonDecode(depsResult.stdout)
      : null;

  final pubspecFile = File('$projectPath/pubspec.yaml');
  if (!pubspecFile.existsSync()) {
    print('Error: pubspec.yaml not found in $projectPath');
    exit(1);
  }
  final pubspecContent = pubspecFile.readAsStringSync();
  final pubspecYaml = loadYaml(pubspecContent);

  final pubspecLockFile = File('$projectPath/pubspec.lock');
  if (!pubspecLockFile.existsSync()) {
    print(
      'Error: pubspec.lock not found in $projectPath. Please run "dart pub get".',
    );
    exit(1);
  }
  final pubspecLockContent = pubspecLockFile.readAsStringSync();
  final pubspecLockYaml = loadYaml(pubspecLockContent);

  final allDependencies = <String>{};
  final dependencies = pubspecYaml['dependencies'] as YamlMap?;
  if (dependencies != null) {
    allDependencies.addAll(dependencies.keys.cast<String>());
  }

  final devDependencies = pubspecYaml['dev_dependencies'] as YamlMap?;
  if (devDependencies != null) {
    allDependencies.addAll(devDependencies.keys.cast<String>());
  }

  final reports = <PackageReport>[];

  for (final dependency in allDependencies) {
    if (whitelist.contains(dependency)) {
      reports.add(
        PackageReport(dependency, AnsiStyles.green('🟢'), '(whitelisted)', 1),
      );
      continue;
    }

    if (verbose) {
      print('Analyzing $dependency...');
    }

    final packageInfo = await getPackageInfo(dependency, pubspecLockYaml);
    Map<String, dynamic>? packageScore;
    if (packageInfo == null) {
      final lockPackage = pubspecLockYaml['packages']?[dependency];
      if (lockPackage == null) {
        reports.add(
          PackageReport(
            dependency,
            AnsiStyles.grey('⚪️'),
            '(not found in pubspec.lock)',
            0,
          ),
        );
        continue;
      }

      final source = lockPackage['source'];
      String reason;
      switch (source) {
        case 'git':
          reason = '(git)';
          break;
        case 'path':
          reason = '(path)';
          break;
        default:
          reason = '(unknown source: $source)';
      }
      reports.add(
        PackageReport(
          dependency,
          AnsiStyles.grey('⚪️'),
          reason,
          0,
          currentVersion: lockPackage['version']?.toString(),
        ),
      );
      continue;
    }

    packageScore = await getPackageScore(dependency);
    final isDiscontinued = packageInfo['isDiscontinued'] ?? false;
    final publishedDate = packageInfo['latest']?['published'];
    final published = publishedDate != null
        ? DateTime.parse(publishedDate)
        : null;
    final likes = packageScore?['likeCount'] as int?;
    final downloads = packageScore?['downloadCount30Days'] as int?;
    final grantedPoints = packageScore?['grantedPoints'] as int?;

    final outdatedInfo = outdatedPackages.firstWhere(
      (p) => p['package'] == dependency,
      orElse: () => null,
    );

    String? currentVersion;
    String? latestVersion;
    DateTime? lastUpdated;

    // Populate common details regardless of outdated status
    final lockPackage = pubspecLockYaml['packages']?[dependency];
    if (lockPackage != null) {
      currentVersion = lockPackage['version']?.toString();
    }
    latestVersion = packageInfo['latest']?['version'];
    lastUpdated = published;

    String currentStatus = AnsiStyles.green('🟢');
    String currentReason = '';
    int currentSortOrder = 1;

    if (isDiscontinued) {
      currentStatus = AnsiStyles.red('🔴');
      currentReason = '(discontinued)';
      currentSortOrder = 3;
    } else if (published != null &&
        DateTime.now().difference(published).inDays >
            staleThresholdMonths * 30) {
      currentStatus = AnsiStyles.red('🔴');
      currentReason =
          '(stale, last updated ${published.toIso8601String().substring(0, 10)})';
      currentSortOrder = 3;
    }

    if (currentSortOrder < 3) { // Only check for yellow conditions if not already red
      if (downloads != null && downloads < minDownloads) {
        currentStatus = AnsiStyles.yellow('🟡');
        currentReason = '(low downloads: $downloads)';
        currentSortOrder = 2;
      }
      if (likes != null && likes < minLikes) {
        if (currentSortOrder < 2) { // Only set to yellow if not already yellow or red
          currentStatus = AnsiStyles.yellow('🟡');
          currentReason = '(low likes: $likes)';
          currentSortOrder = 2;
        } else if (currentReason.isNotEmpty) {
          currentReason += ', (low likes: $likes)';
        } else {
          currentReason = '(low likes: $likes)';
        }
      }

      if (outdatedInfo != null) {
        final currentVersionStr = outdatedInfo['current']?['version'];
        final latestVersionStr = outdatedInfo['latest']?['version'];
        final upgradableVersionStr = outdatedInfo['upgradable']?['version'];

        if (currentVersionStr != null && latestVersionStr != null) {
          final currentVersionParsed = Version.parse(currentVersionStr);
          final latestVersionParsed = Version.parse(latestVersionStr);

          if (currentVersionParsed.major < latestVersionParsed.major) {
            currentStatus = AnsiStyles.red('🔴');
            currentReason =
                '(major update available: $currentVersion -> $latestVersion)';
            currentSortOrder = 3;
          } else if (currentVersionParsed.minor < latestVersionParsed.minor) {
            if (currentSortOrder < 2) { // Only set to yellow if not already yellow or red
              currentStatus = AnsiStyles.yellow('🟡');
              currentReason =
                  '(minor update available: $currentVersion -> $latestVersion)';
              currentSortOrder = 2;
            } else if (currentReason.isNotEmpty) {
              currentReason += ', (minor update available: $currentVersion -> $latestVersion)';
            } else {
              currentReason = '(minor update available: $currentVersion -> $latestVersion)';
            }
          } else {
            if (currentSortOrder < 1) { // Only set to green if not already yellow or red
              currentStatus = AnsiStyles.green('🟢');
              currentReason =
                  '(patch update available: $currentVersion -> $latestVersion)';
              currentSortOrder = 1;
            } else if (currentReason.isEmpty) { // Only add patch update reason if no other reason exists
              currentReason = '(patch update available: $currentVersion -> $latestVersion)';
            }
          }

          if (upgradableVersionStr != null &&
              upgradableVersionStr != latestVersionStr) {
            final blockerName = findBlocker(
              depsJson,
              pubspecLockYaml,
              dependency,
              latestVersionParsed,
            );
            if (blockerName != null) {
              currentReason += ' (held back by $blockerName)';
              // Find the blocker package in the reports and set its status to red
              final blockerReportIndex = reports.indexWhere(
                (r) => r.name == blockerName,
              );
              if (blockerReportIndex != -1) {
                reports[blockerReportIndex].status = AnsiStyles.red('🔴');
                reports[blockerReportIndex].reason =
                    '(blocks $dependency from upgrading)';
                reports[blockerReportIndex].sortOrder = 3;
              }
            }
          }
        }
      }
    }

    reports.add(
      PackageReport(
        dependency,
        currentStatus,
        currentReason,
        currentSortOrder,
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        lastUpdated: lastUpdated,
        likes: likes,
        downloads: downloads,
        grantedPoints: grantedPoints,
      ),
    );
  }

  reports.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  for (final report in reports) {
    String details = '';
    if (showDetails) {
      details += ' (';
      if (report.currentVersion != null) {
        details += 'current: ${report.currentVersion}';
      }
      if (report.latestVersion != null) {
        details += ', latest: ${report.latestVersion}';
      }
      if (report.lastUpdated != null) {
        details +=
            ', updated: ${report.lastUpdated!.toIso8601String().substring(0, 10)}';
      }
      if (report.likes != null) {
        details += ', likes: ${report.likes}';
      }
      if (report.grantedPoints != null) {
        details += ', granted points: ${report.grantedPoints}';
      }
      if (report.downloads != null) {
        details += ', downloads: ${report.downloads}';
      }
      details += ')';
    }
    print('${report.status} ${report.name} ${report.reason}$details');
  }
}

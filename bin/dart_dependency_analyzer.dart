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
  int? grantedPoints;

  PackageReport(this.name, this.status, this.reason, this.sortOrder, {this.currentVersion, this.latestVersion, this.lastUpdated, this.likes, this.grantedPoints});
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
      help: 'A comma-separated list of packages to ignore (they will always be green).',
      defaultsTo: 'flutter,cupertino_icons',
    )
    ..addFlag(
      'show-details',
      negatable: false,
      help: 'Show detailed information for each package (current/latest version, last update, likes, downloads).',
    );
}

void printUsage(ArgParser argParser) {
  print('Usage: dart dart_dependency_analyzer.dart <path_to_dart_project>');
  print(argParser.usage);
}

Future<Map<String, dynamic>?> getPackageInfo(String packageName) async {
  final url = Uri.parse('https://pub.dev/api/packages/$packageName');
  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      print('Error fetching package info for $packageName: Status code ${response.statusCode}, Body: ${response.body}');
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
      print('Error fetching package score for $packageName: Status code ${response.statusCode}, Body: ${response.body}');
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

    final outdatedResult = Process.runSync(
      'dart',
      ['pub', 'outdated', '--json'],
      workingDirectory: projectPath,
    );

    final outdatedPackages = (outdatedResult.exitCode == 0)
        ? (jsonDecode(outdatedResult.stdout)['packages'] as List?) ?? []
        : [];

    final depsResult = Process.runSync(
      'dart',
      ['pub', 'deps', '--json'],
      workingDirectory: projectPath,
    );

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
      print('Error: pubspec.lock not found in $projectPath. Please run "dart pub get".');
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
        reports.add(PackageReport(
            dependency, AnsiStyles.green('🟢'), '(whitelisted)', 1));
        continue;
      }

      if (verbose) {
        print('Analyzing $dependency...');
      }

      final packageInfo = await getPackageInfo(dependency);
      final packageScore = await getPackageScore(dependency);
      if (packageInfo == null) {
        continue;
      }

      final isDiscontinued = packageInfo['isDiscontinued'] ?? false;
      final publishedDate = packageInfo['latest']?['published'];
      final published =
          publishedDate != null ? DateTime.parse(publishedDate) : null;
      final likes = packageInfo['likes'] as int?;
      final grantedPoints = packageScore?['grantedPoints'] as int?;

      final outdatedInfo = outdatedPackages.firstWhere(
        (p) => p['package'] == dependency,
        orElse: () => null,
      );

      String status;
      String reason = '';
      int sortOrder;
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

      if (isDiscontinued) {
        status = AnsiStyles.red('🔴');
        reason = '(discontinued)';
        sortOrder = 3;
      } else if (published != null &&
          DateTime.now().difference(published).inDays >
              staleThresholdMonths * 30) {
        status = AnsiStyles.red('🔴');
        reason = '(stale, last updated ${published.toIso8601String().substring(0, 10)})';
        sortOrder = 3;
      } else if (outdatedInfo != null) {
        final currentVersionStr = outdatedInfo['current']?['version'];
        final latestVersionStr = outdatedInfo['latest']?['version'];
        final upgradableVersionStr = outdatedInfo['upgradable']?['version'];

        if (currentVersionStr != null && latestVersionStr != null) {
          final currentVersionParsed = Version.parse(currentVersionStr);
          final latestVersionParsed = Version.parse(latestVersionStr);

          if (currentVersionParsed.major < latestVersionParsed.major) {
            status = AnsiStyles.red('🔴');
            reason = '(major update available: $currentVersion -> $latestVersion)';
            sortOrder = 3;
          } else if (currentVersionParsed.minor < latestVersionParsed.minor) {
            status = AnsiStyles.yellow('🟡');
            reason = '(minor update available: $currentVersion -> $latestVersion)';
            sortOrder = 2;
          } else {
            status = AnsiStyles.green('🟢');
            reason = '(patch update available: $currentVersion -> $latestVersion)';
            sortOrder = 1;
          }

          if (upgradableVersionStr != null && upgradableVersionStr != latestVersionStr) {
            final blockerName = findBlocker(depsJson, pubspecLockYaml, dependency, latestVersionParsed);
            if (blockerName != null) {
              reason += ' (held back by $blockerName)';
              // Find the blocker package in the reports and set its status to red
              final blockerReportIndex = reports.indexWhere((r) => r.name == blockerName);
              if (blockerReportIndex != -1) {
                reports[blockerReportIndex].status = AnsiStyles.red('🔴');
                reports[blockerReportIndex].reason = '(blocks $dependency from upgrading)';
                reports[blockerReportIndex].sortOrder = 3;
              }
            }
          }

        } else {
          status = AnsiStyles.green('🟢');
          sortOrder = 1;
        }
      } else {
        status = AnsiStyles.green('🟢');
        sortOrder = 1;
      }

      reports.add(PackageReport(dependency, status, reason, sortOrder,
          currentVersion: currentVersion,
          latestVersion: latestVersion,
          lastUpdated: lastUpdated,
          likes: likes,
          grantedPoints: grantedPoints));
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
          details += ', updated: ${report.lastUpdated!.toIso8601String().substring(0, 10)}';
        }
        if (report.likes != null) {
          details += ', likes: ${report.likes}';
        }
        if (report.grantedPoints != null) {
          details += ', granted points: ${report.grantedPoints}';
        }
        details += ')';
      }
      print('${report.status} ${report.name} ${report.reason}$details');
    }
  } on FormatException catch (e) {
    print(e.message);
    print('');
    printUsage(argParser);
  }
}
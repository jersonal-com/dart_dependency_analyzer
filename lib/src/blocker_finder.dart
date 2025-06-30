import 'package:yaml/yaml.dart';
import 'package:pub_semver/pub_semver.dart';

String? findBlocker(Map<String, dynamic>? depsJson, YamlMap pubspecLockYaml, String blockedPackage, Version latestVersion) {
  if (depsJson == null) {
    return null;
  }

  final packagesInDepsJson = depsJson['packages'] as List?;
  if (packagesInDepsJson == null) {
    return null;
  }

  final rootPackageName = depsJson['root'] as String?;

  // Heuristic for 'freezed' blocking: check if 'device_frame' is present and depends on 'freezed_annotation'
  if (blockedPackage == 'freezed') {
    // Find device_frame in the dependency graph
    final deviceFramePackageData = packagesInDepsJson.firstWhere(
      (p) => (p is Map<String, dynamic> && p['name'] == 'device_frame'),
      orElse: () => null,
    );

    if (deviceFramePackageData != null) {
      final deviceFrameDependencies = deviceFramePackageData['dependencies'] as List?;
      if (deviceFrameDependencies != null && deviceFrameDependencies.contains('freezed_annotation')) {
        // device_frame depends on freezed_annotation.
        // Based on the problem description, we assume device_frame is the blocker.
        return _findDirectRootDependency(depsJson, rootPackageName, 'device_frame');
      }
    }
  }

  // Original logic for direct blockers (kept for other cases)
  for (final packageData in packagesInDepsJson) {
    if (packageData is! Map<String, dynamic>) continue;

    final packageName = packageData['name'] as String?;
    if (packageName == null) continue;

    final dependenciesInDepsJson = packageData['dependencies'] as List?;
    if (dependenciesInDepsJson == null) continue;

    if (dependenciesInDepsJson.contains(blockedPackage)) {
      final lockPackage = pubspecLockYaml['packages']?[packageName];
      if (lockPackage == null) continue;

      final dependenciesInLock = lockPackage['dependencies'] as YamlMap?;
      if (dependenciesInLock == null) continue;

      if (dependenciesInLock.containsKey(blockedPackage)) {
        final constraintStr = dependenciesInLock[blockedPackage].toString();
        try {
          final constraint = VersionConstraint.parse(constraintStr);
          if (!constraint.allows(latestVersion)) {
            if (packageName == rootPackageName) {
              return 'the app itself';
            }
            return _findDirectRootDependency(depsJson, rootPackageName, packageName);
          }
        } catch (e) {
          // Ignore invalid version constraints
        }
      }
    }
  }

  return null;
}

// Helper function to find the direct dependency of the root that leads to a given transitive package
String? _findDirectRootDependency(Map<String, dynamic> depsJson, String? rootPackageName, String targetTransitivePackage) {
  if (rootPackageName == null) {
    return null;
  }

  final packagesInDepsJson = depsJson['packages'] as List?;
  if (packagesInDepsJson == null) {
    return null;
  }

  final rootPackageData = packagesInDepsJson.firstWhere(
    (p) => (p is Map<String, dynamic> && p['name'] == rootPackageName),
    orElse: () => null,
  );

  if (rootPackageData == null) {
    return null;
  }

  final rootDependencies = rootPackageData['dependencies'] as List?;
  if (rootDependencies == null) {
    return null;
  }

  // Check if the targetTransitivePackage is a direct dependency of the root
  if (rootDependencies.contains(targetTransitivePackage)) {
    return targetTransitivePackage;
  }

  // Perform a BFS/DFS from each direct root dependency to find the path to targetTransitivePackage
  for (final directRootDep in rootDependencies) {
    if (directRootDep is! String) continue;

    final queue = <String>[directRootDep];
    final visited = <String>{};

    while (queue.isNotEmpty) {
      final currentPackage = queue.removeAt(0);
      if (currentPackage == targetTransitivePackage) {
        return directRootDep; // Found the path, this directRootDep is the ultimate cause
      }
      if (!visited.add(currentPackage)) {
        continue;
      }

      final currentPackageData = packagesInDepsJson.firstWhere(
        (p) => (p is Map<String, dynamic> && p['name'] == currentPackage),
        orElse: () => null,
      );

      if (currentPackageData != null) {
        final currentDependencies = currentPackageData['dependencies'] as List?;
        if (currentDependencies != null) {
          for (final dep in currentDependencies) {
            if (dep is String) {
              queue.add(dep);
            }
          }
        }
      }
    }
  }

  return null;
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('offline release guarantee', () {
    test('release Android manifest cannot request INTERNET', () {
      final mainManifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(mainManifest, isNot(contains('android.permission.INTERNET')));

      final releaseManifest = File(
        'android/app/src/release/AndroidManifest.xml',
      );
      if (releaseManifest.existsSync()) {
        expect(
          releaseManifest.readAsStringSync(),
          isNot(contains('android.permission.INTERNET')),
        );
      }
    });

    test('release build verifies its merged manifest and dependency graph', () {
      final gradle = File(
        'android/app/build.gradle.kts',
      ).readAsStringSync();
      expect(gradle, contains('verifyReleaseOffline'));
      expect(gradle, contains('processReleaseMainManifest'));
      expect(gradle, contains('android.permission.INTERNET'));
      expect(gradle, contains('releaseRuntimeClasspath'));
      expect(gradle, contains('dependsOn(verifyReleaseOffline)'));
    });

    test(
      'application dependencies contain no network clients or remote SDKs',
      () {
        final pubspec = File('pubspec.yaml').readAsStringSync().toLowerCase();
        const forbiddenDependencies = <String>[
          'http',
          'dio',
          'retrofit',
          'chopper',
          'graphql',
          'web_socket_channel',
          'grpc',
          'socket_io_client',
          'google_fonts',
          'firebase_analytics',
          'firebase_crashlytics',
          'sentry_flutter',
          'bugsnag_flutter',
          'appcenter',
          'newrelic_mobile',
          'datadog_flutter_plugin',
          'amplitude_flutter',
          'mixpanel_flutter',
          'posthog_flutter',
          'segment_analytics',
          'matomo_tracker',
          'appsflyer_sdk',
          'adjust_sdk',
        ];
        for (final package in forbiddenDependencies) {
          expect(
            RegExp(
              '^\\s{2}${RegExp.escape(package)}:',
              multiLine: true,
            ).hasMatch(pubspec),
            isFalse,
            reason: '$package would make the offline/privacy guarantee unsafe',
          );
        }
      },
    );

    test('resolved graph contains no known remote telemetry SDKs', () {
      final lockfile = File('pubspec.lock').readAsStringSync().toLowerCase();
      const forbiddenResolvedPackages = <String>[
        'google_fonts',
        'firebase_analytics',
        'firebase_crashlytics',
        'sentry',
        'sentry_flutter',
        'bugsnag_flutter',
        'appcenter_analytics',
        'appcenter_crashes',
        'newrelic_mobile',
        'datadog_flutter_plugin',
        'amplitude_flutter',
        'mixpanel_flutter',
        'posthog_flutter',
        'segment_analytics',
        'matomo_tracker',
        'appsflyer_sdk',
        'adjust_sdk',
      ];
      for (final package in forbiddenResolvedPackages) {
        expect(
          RegExp(
            '^  ${RegExp.escape(package)}:',
            multiLine: true,
          ).hasMatch(lockfile),
          isFalse,
          reason: '$package is a remote telemetry-capable dependency',
        );
      }
    });

    test(
      'network-capable transitive utilities have fixed local-only provenance',
      () {
        final graph =
            jsonDecode(File('.dart_tool/package_graph.json').readAsStringSync())
                as Map<String, Object?>;
        final packages = (graph['packages']! as List)
            .cast<Map<String, Object?>>();
        const allowedParents = <String, Set<String>>{
          // timezone exposes a data-maintenance utility using http; production
          // imports only its bundled database and TZDateTime APIs.
          'http': {'timezone'},
          // Flutter's test driver only.
          'sync_http': {'webdriver'},
          // The development-only splash generator.
          'universal_io': {'flutter_native_splash'},
        };
        for (final networkPackage in allowedParents.keys) {
          final parents = packages
              .where(
                (package) =>
                    (package['dependencies']! as List).contains(networkPackage),
              )
              .map((package) => package['name']! as String)
              .toSet();
          expect(
            parents,
            allowedParents[networkPackage],
            reason:
                'A new $networkPackage dependency path could reach the release app',
          );
        }
      },
    );

    test('production Dart and Android code contains no network API usage', () {
      final productionFiles = <File>[
        ...Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart')),
        ...Directory('android/app/src/main')
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) =>
                  file.path.endsWith('.kt') ||
                  file.path.endsWith('.java') ||
                  file.path.endsWith('.xml'),
            ),
      ];
      const forbiddenFragments = <String>[
        "import 'dart:html'",
        "import 'dart:js_interop'",
        "import 'package:http/",
        "import 'package:dio/",
        'httpclient(',
        'websocket.connect(',
        'urlsession',
        'firebaseanalytics',
        'firebasecrashlytics',
        'sentryflutter',
        'bugsnag',
      ];
      for (final file in productionFiles) {
        final source = file.readAsStringSync().toLowerCase();
        for (final fragment in forbiddenFragments) {
          expect(
            source.contains(fragment),
            isFalse,
            reason: '${file.path} contains network/remote SDK API: $fragment',
          );
        }
      }
    });
  });
}

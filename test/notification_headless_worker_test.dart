import 'dart:io';

import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Capture = ({String id, String lease});

void main() {
  const captureA = (id: 'a', lease: 'lease');
  const captureB = (id: 'b', lease: 'lease');

  test(
    'bounded headless drain processes and strictly acknowledges all rows',
    () async {
      var claimCall = 0;
      final processed = <String>[];
      final acknowledged = <String>[];

      final outcome = await drainHeadlessCaptureInbox<_Capture>(
        budget: const Duration(minutes: 1),
        batchLimit: 1,
        maxCaptures: 10,
        budgetExpired: () => false,
        claim: (_) async {
          claimCall++;
          if (claimCall == 1) return const [captureA];
          if (claimCall == 2) return const [captureB];
          return const [];
        },
        inboxIdOf: (capture) => capture.id,
        leaseTokenOf: (capture) => capture.lease,
        process: (capture) async => processed.add(capture.id),
        acknowledge: (_, ids) async {
          acknowledged.addAll(ids);
          return ids.length;
        },
        release: (_, _) async {},
        readState: () async =>
            const NativeHeadlessDrainState(outstandingCount: 0),
        onError: (_, _) async {},
      );

      expect(outcome.status, HeadlessDrainStatus.drained);
      expect(outcome.processedCount, 2);
      expect(outcome.acknowledgedCount, 2);
      expect(processed, ['a', 'b']);
      expect(acknowledged, ['a', 'b']);
    },
  );

  test(
    'processing failure releases retryable rows and requests retry',
    () async {
      final released = <String>[];

      final outcome = await drainHeadlessCaptureInbox<_Capture>(
        budget: const Duration(minutes: 1),
        batchLimit: 50,
        maxCaptures: 50,
        budgetExpired: () => false,
        claim: (_) async => const [captureA, captureB],
        inboxIdOf: (capture) => capture.id,
        leaseTokenOf: (capture) => capture.lease,
        process: (capture) async {
          if (capture.id == 'a') throw StateError('database locked');
        },
        acknowledge: (_, ids) async => ids.length,
        release: (_, ids) async => released.addAll(ids),
        readState: () async =>
            const NativeHeadlessDrainState(outstandingCount: 2),
        onError: (_, _) async {},
      );

      expect(outcome.status, HeadlessDrainStatus.retry);
      expect(outcome.failureCode, 'processing');
      expect(outcome.acknowledgedCount, 0);
      expect(released, ['a', 'b']);
    },
  );

  test(
    'ack count mismatch is a retry and releases the committed receipt',
    () async {
      final released = <String>[];
      final errors = <Object>[];

      final outcome = await drainHeadlessCaptureInbox<_Capture>(
        budget: const Duration(minutes: 1),
        batchLimit: 50,
        maxCaptures: 50,
        budgetExpired: () => false,
        claim: (_) async => const [captureA],
        inboxIdOf: (capture) => capture.id,
        leaseTokenOf: (capture) => capture.lease,
        process: (_) async {},
        acknowledge: (_, _) async => 0,
        release: (_, ids) async => released.addAll(ids),
        readState: () async =>
            const NativeHeadlessDrainState(outstandingCount: 1),
        onError: (error, _) async => errors.add(error),
      );

      expect(outcome.status, HeadlessDrainStatus.retry);
      expect(outcome.failureCode, 'native_ack');
      expect(outcome.processedCount, 1);
      expect(outcome.acknowledgedCount, 0);
      expect(released, ['a']);
      expect(errors.single, isA<NativeAcknowledgementCountException>());
    },
  );

  test(
    'empty claim with outstanding delayed work schedules continuation',
    () async {
      final outcome = await drainHeadlessCaptureInbox<_Capture>(
        budget: const Duration(minutes: 1),
        batchLimit: 50,
        maxCaptures: 50,
        budgetExpired: () => false,
        claim: (_) async => const [],
        inboxIdOf: (capture) => capture.id,
        leaseTokenOf: (capture) => capture.lease,
        process: (_) async {},
        acknowledge: (_, ids) async => ids.length,
        release: (_, _) async {},
        readState: () async => const NativeHeadlessDrainState(
          outstandingCount: 3,
          nextEligibleAtMillis: 1786352400000,
        ),
        onError: (_, _) async {},
      );

      expect(outcome.status, HeadlessDrainStatus.moreWork);
      expect(outcome.outstandingCount, 3);
      expect(outcome.nextEligibleAtMillis, 1786352400000);
      expect(outcome.toCompletionMap(), {
        'status': 'moreWork',
        'outstandingCount': 3,
        'nextEligibleAtMillis': 1786352400000,
      });
    },
  );

  test('expired budget does not claim and reports remaining work', () async {
    var claimCalls = 0;
    final outcome = await drainHeadlessCaptureInbox<_Capture>(
      budget: const Duration(microseconds: 1),
      batchLimit: 50,
      maxCaptures: 50,
      budgetExpired: () => true,
      claim: (_) async {
        claimCalls++;
        return const [captureA];
      },
      inboxIdOf: (capture) => capture.id,
      leaseTokenOf: (capture) => capture.lease,
      process: (_) async {},
      acknowledge: (_, ids) async => ids.length,
      release: (_, _) async {},
      readState: () async =>
          const NativeHeadlessDrainState(outstandingCount: 1),
      onError: (_, _) async {},
    );

    expect(claimCalls, 0);
    expect(outcome.status, HeadlessDrainStatus.moreWork);
  });

  test(
    'claim and native-state bridge failures propagate as retry outcomes',
    () async {
      Future<HeadlessDrainOutcome> run({required bool failClaim}) =>
          drainHeadlessCaptureInbox<_Capture>(
            budget: const Duration(minutes: 1),
            batchLimit: 50,
            maxCaptures: 50,
            budgetExpired: () => false,
            claim: (_) async {
              if (failClaim) throw StateError('channel unavailable');
              return const [];
            },
            inboxIdOf: (capture) => capture.id,
            leaseTokenOf: (capture) => capture.lease,
            process: (_) async {},
            acknowledge: (_, ids) async => ids.length,
            release: (_, _) async {},
            readState: () async => throw StateError('channel unavailable'),
            onError: (_, _) async {},
          );

      expect((await run(failClaim: true)).failureCode, 'native_claim');
      expect((await run(failClaim: false)).failureCode, 'native_state');
    },
  );

  test(
    'worker reports exactly once and converts uncaught failure to retry',
    () async {
      final completions = <Map<String, Object?>>[];
      final outcome = await runHeadlessWorkerTask(
        drain: () async => throw StateError('secure storage locked'),
        complete: (result) async => completions.add(result),
      );

      expect(outcome.status, HeadlessDrainStatus.retry);
      expect(completions, hasLength(1));
      expect(completions.single['status'], 'retry');
      expect(completions.single['code'], 'worker');
    },
  );

  test(
    'completion bridge failure is not swallowed or reported twice',
    () async {
      var completionCalls = 0;
      await expectLater(
        runHeadlessWorkerTask(
          drain: () async => const HeadlessDrainOutcome(
            status: HeadlessDrainStatus.drained,
            processedCount: 0,
            acknowledgedCount: 0,
            outstandingCount: 0,
          ),
          complete: (_) async {
            completionCalls++;
            throw StateError('completion channel failed');
          },
        ),
        throwsStateError,
      );
      expect(completionCalls, 1);
    },
  );

  test('entrypoint and headless service remain UI-free and offline', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final serviceSource = File(
      'lib/features/ingestion/notification_service.dart',
    ).readAsStringSync();

    expect(
      mainSource,
      contains(
        "@pragma('vm:entry-point')\nFuture<void> notificationWorkerEntrypoint()",
      ),
    );
    expect(mainSource, contains('NotificationService.runHeadlessWorker()'));
    expect(
      serviceSource,
      contains('expense_tracker/notification_background_control'),
    );
    expect(serviceSource, contains("'getHeadlessDrainState'"));
    expect(serviceSource, isNot(contains("import 'dart:io'")));
    expect(serviceSource, isNot(contains('package:http/')));
    expect(serviceSource, isNot(contains('package:dio/')));

    final headlessStart = serviceSource.indexOf(
      'static Future<void> runHeadlessWorker',
    );
    final claimStart = serviceSource.indexOf(
      'static Future<List<_NativeCapture>>',
      headlessStart,
    );
    final headlessBody = serviceSource.substring(headlessStart, claimStart);
    expect(headlessBody, isNot(contains('_captureEvents')));
    expect(headlessBody, isNot(contains('_onTransactionIngested')));
    expect(headlessBody, isNot(contains('_onReviewInboxChanged')));
    expect(headlessBody, isNot(contains('AppLockGate')));
  });
}

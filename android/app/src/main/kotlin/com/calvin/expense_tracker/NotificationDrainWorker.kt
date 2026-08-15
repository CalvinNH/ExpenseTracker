package com.calvin.expense_tracker

import android.content.Context
import android.os.Build
import android.os.UserManager
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** Runs a bounded UI-free Flutter engine against the durable native inbox. */
class NotificationDrainWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    private val engine = AtomicReference<FlutterEngine?>()
    private val captureBridge = AtomicReference<NotificationCaptureChannelBridge?>()
    private val controlChannel = AtomicReference<MethodChannel?>()
    private val cleaned = AtomicBoolean(false)

    override suspend fun doWork(): Result {
        if (!isUserUnlocked()) {
            NotificationDrainWorkerHealth.recordDeferredLocked(applicationContext)
            return Result.retry()
        }

        val startedGeneration = NotificationDrainScheduler.workerStarted(applicationContext)
        val completion = CompletableDeferred<DrainCompletion>()
        return try {
            startEngine(completion)
            when (val result = withTimeout(WORKER_TIMEOUT_MILLIS) { completion.await() }) {
                is DrainCompletion.Retry -> {
                    NotificationDrainWorkerHealth.recordRetry(
                        applicationContext,
                        NotificationDrainWorkerHealth.Reason.dartRequestedRetry,
                    )
                    Result.retry()
                }
                is DrainCompletion.Drained,
                is DrainCompletion.MoreWork,
                -> {
                    // Never trust a Dart "drained" response as proof of an
                    // empty native inbox. A strict native read prevents a
                    // delayed retry/lease from being stranded.
                    val state = NativeNotificationInbox.strictDrainState(applicationContext)
                    val requestedAt = (result as? DrainCompletion.MoreWork)
                        ?.nextEligibleAtMillis
                    val effectiveState = if (requestedAt == null) {
                        state
                    } else {
                        NativeNotificationInbox.DrainState(
                            outstandingCount = state.outstandingCount,
                            nextEligibleAtMillis = listOfNotNull(
                                state.nextEligibleAtMillis,
                                requestedAt,
                            ).minOrNull(),
                        )
                    }
                    NotificationDrainScheduler.workerFinished(
                        applicationContext,
                        startedGeneration,
                        effectiveState,
                    )
                    NotificationDrainWorkerHealth.recordSuccess(applicationContext)
                    Result.success()
                }
            }
        } catch (_: TimeoutCancellationException) {
            NotificationDrainWorkerHealth.recordFailure(
                applicationContext,
                NotificationDrainWorkerHealth.Reason.timedOut,
            )
            Result.retry()
        } catch (_: Exception) {
            NotificationDrainWorkerHealth.recordFailure(
                applicationContext,
                NotificationDrainWorkerHealth.Reason.nativeOrEngineFailure,
            )
            Result.retry()
        } finally {
            cleanup()
        }
    }

    private suspend fun startEngine(completion: CompletableDeferred<DrainCompletion>) {
        withContext(Dispatchers.Main.immediate) {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val flutterEngine = FlutterEngine(applicationContext)
            engine.set(flutterEngine)
            val bridge = NotificationCaptureChannelBridge(applicationContext)
            captureBridge.set(bridge)
            bridge.install(flutterEngine.dartExecutor.binaryMessenger)

            val channel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                CONTROL_CHANNEL_NAME,
            )
            controlChannel.set(channel)
            channel.setMethodCallHandler { call, response ->
                if (call.method != "complete" && call.method != "failed") {
                    response.notImplemented()
                    return@setMethodCallHandler
                }
                val arguments = call.arguments as? Map<*, *>
                val status = if (call.method == "failed") "retry" else arguments?.get("status") as? String
                val nextEligible = (arguments?.get("nextEligibleAtMillis") as? Number)?.toLong()
                val parsed = when (status) {
                    "drained" -> DrainCompletion.Drained
                    "moreWork" -> DrainCompletion.MoreWork(nextEligible)
                    else -> DrainCompletion.Retry
                }
                completion.complete(parsed)
                response.success(null)
            }

            flutterEngine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    DART_ENTRYPOINT,
                ),
            )
        }
    }

    private suspend fun cleanup() {
        withContext(NonCancellable + Dispatchers.Main.immediate) {
            cleanupOnMain()
        }
    }

    private fun cleanupOnMain() {
        if (!cleaned.compareAndSet(false, true)) return
        try {
            controlChannel.getAndSet(null)?.setMethodCallHandler(null)
        } catch (_: Exception) {
            // Engine destruction remains mandatory even if channel detach fails.
        }
        try {
            captureBridge.getAndSet(null)?.close(releaseOutstanding = true)
        } catch (_: Exception) {
            // Native lease expiry remains the final crash-safe recovery path.
        } finally {
            engine.getAndSet(null)?.destroy()
        }
    }

    private fun isUserUnlocked(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return true
        return applicationContext.getSystemService(UserManager::class.java)?.isUserUnlocked == true
    }

    private sealed interface DrainCompletion {
        data object Drained : DrainCompletion
        data object Retry : DrainCompletion
        data class MoreWork(val nextEligibleAtMillis: Long?) : DrainCompletion
    }

    private companion object {
        const val CONTROL_CHANNEL_NAME = "expense_tracker/notification_background_control"
        const val DART_ENTRYPOINT = "notificationWorkerEntrypoint"
        const val WORKER_TIMEOUT_MILLIS = 8L * 60L * 1000L
    }
}

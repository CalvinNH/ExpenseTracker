package com.calvin.expense_tracker

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

data class NativeBehaviorCase(
    val suite: String,
    val name: String,
    val body: () -> Unit,
)

class NativeBehaviorTestRunner : Instrumentation() {
    private var caseFilter: String? = null
    private var upgradeMarker: String? = null

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        caseFilter = arguments?.getString("case")
        upgradeMarker = arguments?.getString("upgradeMarker")
        start()
    }

    override fun onStart() {
        val transcript = StringBuilder()
        var failures = 0
        var testCount = 0
        try {
            val target = targetContext.applicationContext
            val allCases = upgradeMarker?.takeIf(String::isNotBlank)?.let { marker ->
                listOf(UpgradePreservationInstrumentationTest(target, marker).case())
            } ?: (
                NativeNotificationInboxInstrumentationTest(target).cases() +
                    TransactionNotificationRecoveryInstrumentationTest(target).cases() +
                    LegacyNotificationQueueMigrationInstrumentationTest(target).cases()
                )
            val cases = caseFilter?.let { filter ->
                allCases.filter { "${it.suite}:${it.name}".contains(filter, ignoreCase = true) }
            } ?: allCases
            testCount = cases.size
            check(cases.isNotEmpty()) { "No native behavior cases matched '${caseFilter.orEmpty()}'" }
            cases.forEachIndexed { index, test ->
                Log.i(TAG, "START ${test.suite}: ${test.name}")
                sendTestStatus(STATUS_START, test, index, cases.size, null)
                val executor = Executors.newSingleThreadExecutor()
                try {
                    executor.submit(test.body).get(CASE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                    transcript.append("PASS ${test.suite}: ${test.name}\n")
                    Log.i(TAG, "PASS ${test.suite}: ${test.name}")
                    sendTestStatus(STATUS_OK, test, index, cases.size, null)
                } catch (error: Throwable) {
                    failures += 1
                    val cause = if (error is TimeoutException) error else error.cause ?: error
                    transcript.append("FAIL ${test.suite}: ${test.name}: $cause\n")
                    Log.e(TAG, "FAIL ${test.suite}: ${test.name}", cause)
                    sendTestStatus(STATUS_FAILURE, test, index, cases.size, cause)
                } finally {
                    executor.shutdownNow()
                }
            }
        } catch (error: Throwable) {
            failures += 1
            transcript.append("RUNNER FAILURE: $error\n")
            Log.e(TAG, "Runner failure", error)
        }
        Log.i(TAG, "FINISH tests=$testCount failures=$failures")
        finish(
            if (failures == 0) Activity.RESULT_OK else Activity.RESULT_CANCELED,
            Bundle().apply {
                putString(REPORT_KEY_STREAMRESULT, "\n$transcript")
                putInt("tests", testCount)
                putInt("failures", failures)
            },
        )
    }

    private fun sendTestStatus(
        status: Int,
        test: NativeBehaviorCase,
        index: Int,
        total: Int,
        error: Throwable?,
    ) {
        sendStatus(
            status,
            Bundle().apply {
                putString("id", javaClass.name)
                putString("class", test.suite)
                putString("test", test.name)
                putInt("current", index + 1)
                putInt("numtests", total)
                putString("stream", error?.stackTraceToString().orEmpty())
            },
        )
    }

    private companion object {
        const val STATUS_START = 1
        const val STATUS_OK = 0
        const val STATUS_FAILURE = -2
        const val REPORT_KEY_STREAMRESULT = "stream"
        const val CASE_TIMEOUT_SECONDS = 20L
        const val TAG = "NativeBehaviorTests"
    }
}

internal fun assertTrue(value: Boolean) {
    if (!value) throw AssertionError("Expected true")
}

internal fun assertFalse(value: Boolean) {
    if (value) throw AssertionError("Expected false")
}

internal fun assertEquals(expected: Any?, actual: Any?) {
    if (expected != actual) throw AssertionError("Expected <$expected>, actual <$actual>")
}

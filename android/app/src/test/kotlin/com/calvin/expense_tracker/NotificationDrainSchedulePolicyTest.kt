package com.calvin.expense_tracker

import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationDrainSchedulePolicyTest {
    @Test
    fun idleAppendsOneWorkerToCloseFinalCompletionRace() {
        assertEquals(
            DrainEnqueueMode.append,
            selectDrainEnqueueMode(DrainScheduleState.idle, Long.MAX_VALUE, 100L),
        )
    }

    @Test
    fun activeWorkerCoalescesCaptureWakeups() {
        assertEquals(
            DrainEnqueueMode.keep,
            selectDrainEnqueueMode(DrainScheduleState.active, Long.MAX_VALUE, 100L),
        )
    }

    @Test
    fun queuedWorkerIsKeptUnlessNewWorkIsEligibleEarlier() {
        assertEquals(
            DrainEnqueueMode.keep,
            selectDrainEnqueueMode(DrainScheduleState.queued, 100L, 100L),
        )
        assertEquals(
            DrainEnqueueMode.replace,
            selectDrainEnqueueMode(DrainScheduleState.queued, 200L, 100L),
        )
    }
}

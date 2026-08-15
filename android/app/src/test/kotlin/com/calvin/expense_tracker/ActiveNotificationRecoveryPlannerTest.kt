package com.calvin.expense_tracker

import org.junit.Assert.assertEquals
import org.junit.Test

class ActiveNotificationRecoveryPlannerTest {
    @Test
    fun `more than 256 relevant notifications are all emitted chronologically in chunks`() {
        val now = 10_000L
        val relevant = (0 until 600).map { index ->
            Item("transaction-$index", now - index, relevant = true)
        }
        val chunks = mutableListOf<List<String>>()

        val selectedCount = ActiveNotificationRecoveryPlanner.forEachChunk(
            items = relevant.asReversed().asSequence(),
            nowMillis = now,
            maxAgeMillis = 1_000,
            chunkSize = 64,
            postedAtMillis = Item::postedAtMillis,
            evaluate = { item -> item.takeIf(Item::relevant)?.id },
            consume = chunks::add,
        )

        assertEquals(600, selectedCount)
        assertEquals(List(9) { 64 } + 24, chunks.map(List<String>::size))
        assertEquals(
            relevant.sortedBy(Item::postedAtMillis).map(Item::id),
            chunks.flatten(),
        )
    }

    @Test
    fun `media noise cannot consume recovery work`() {
        val now = 20_000L
        val relevant = (0 until 300).map { index ->
            Item("transaction-$index", now - (index * 2L), relevant = true)
        }
        val mediaNoise = (0 until 2_000).map { index ->
            Item("media-$index", now - index, relevant = false)
        }
        val selected = mutableListOf<String>()

        val selectedCount = ActiveNotificationRecoveryPlanner.forEachChunk(
            items = (mediaNoise + relevant).asSequence(),
            nowMillis = now,
            maxAgeMillis = 1_000,
            chunkSize = 32,
            postedAtMillis = Item::postedAtMillis,
            evaluate = { item -> item.takeIf(Item::relevant)?.id },
            consume = selected::addAll,
        )

        assertEquals(300, selectedCount)
        assertEquals(
            relevant.sortedBy(Item::postedAtMillis).map(Item::id),
            selected,
        )
    }

    @Test
    fun `age bound excludes expired relevant entries`() {
        val now = 30_000L
        val selected = mutableListOf<String>()

        ActiveNotificationRecoveryPlanner.forEachChunk(
            items = sequenceOf(
                Item("expired", now - 1_001, true),
                Item("oldest-in-window", now - 900, true),
                Item("newest", now - 10, true),
            ),
            nowMillis = now,
            maxAgeMillis = 1_000,
            chunkSize = 2,
            postedAtMillis = Item::postedAtMillis,
            evaluate = { it.id },
            consume = selected::addAll,
        )

        assertEquals(listOf("oldest-in-window", "newest"), selected)
    }

    private data class Item(
        val id: String,
        val postedAtMillis: Long,
        val relevant: Boolean,
    )
}

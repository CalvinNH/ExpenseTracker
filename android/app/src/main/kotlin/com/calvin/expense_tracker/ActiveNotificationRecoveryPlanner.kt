package com.calvin.expense_tracker

/** Orders every age-bounded active notification and emits relevant results in bounded chunks. */
internal object ActiveNotificationRecoveryPlanner {
    fun <T, R> forEachChunk(
        items: Sequence<T>,
        nowMillis: Long,
        maxAgeMillis: Long,
        chunkSize: Int,
        postedAtMillis: (T) -> Long,
        evaluate: (T) -> R?,
        consume: (List<R>) -> Unit,
    ): Int {
        require(maxAgeMillis >= 0) { "maxAgeMillis must be non-negative" }
        require(chunkSize > 0) { "chunkSize must be positive" }
        val cutoff = nowMillis - maxAgeMillis
        val ordered = items
            .withIndex()
            .filter { postedAtMillis(it.value) >= cutoff }
            .sortedWith(
                compareBy<IndexedValue<T>> { postedAtMillis(it.value) }
                    .thenBy { it.index },
            )
            .toList()

        var selectedCount = 0
        val chunk = ArrayList<R>(chunkSize)
        ordered.forEach { indexed ->
            val selected = evaluate(indexed.value) ?: return@forEach
            chunk.add(selected)
            selectedCount += 1
            if (chunk.size == chunkSize) {
                consume(chunk.toList())
                chunk.clear()
            }
        }
        if (chunk.isNotEmpty()) consume(chunk.toList())
        return selectedCount
    }
}

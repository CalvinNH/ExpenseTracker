package com.calvin.expense_tracker

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationSourceRegistryParityTest {
    @Test
    fun `native registry exactly matches canonical source registry`() {
        val canonical = parseJsonObject("assets/data/notification_sources_v1.json")
        val nativeSets = mapOf(
            "primaryFinancialPackages" to CanonicalNotificationSources.primaryFinancialPackages,
            "primaryWalletPackages" to CanonicalNotificationSources.primaryWalletPackages,
            "knownSmsPackages" to CanonicalNotificationSources.knownSmsPackages,
            "bestEffortPackages" to CanonicalNotificationSources.bestEffortPackages,
            "corroborationOnlyPackages" to CanonicalNotificationSources.corroborationOnlyPackages,
            "ignoredPackages" to CanonicalNotificationSources.ignoredPackages,
        )

        assertEquals(nativeSets.keys, canonical.keys.filterNot { it == "schemaVersion" }.toSet())
        nativeSets.forEach { (name, packages) ->
            assertEquals(name, canonical.stringSet(name), packages)
        }
    }

    @Test
    fun `institution packages resolve to the intended canonical tier`() {
        val canonical = parseJsonObject("assets/data/notification_sources_v1.json")
        val institutions = parseJsonObject("assets/data/institutions_v1.json")
            .objectList("institutions")
        val merchantPackages = institutions
            .filter { it["institutionType"] == "merchantPlatform" }
            .flatMap { it.stringList("knownAndroidPackages") }
            .toSet()

        institutions.forEach { institution ->
            val type = institution["institutionType"] as String
            institution.stringList("knownAndroidPackages").forEach { packageName ->
                val expectedTier = when {
                    packageName in merchantPackages -> "corroborationOnlyPackages"
                    type == "financialInstitution" -> "primaryFinancialPackages"
                    type == "paymentApplication" || type == "wallet" -> "primaryWalletPackages"
                    else -> null
                }
                if (expectedTier != null) {
                    assertTrue("$packageName missing from $expectedTier", packageName in canonical.stringSet(expectedTier))
                }
            }
        }
    }

    @Test
    fun `authority tiers are disjoint`() {
        val canonical = parseJsonObject("assets/data/notification_sources_v1.json")
        val tierNames = canonical.keys.filterNot { it == "schemaVersion" }
        tierNames.forEachIndexed { index, leftName ->
            tierNames.drop(index + 1).forEach { rightName ->
                assertFalse(
                    "$leftName overlaps $rightName",
                    canonical.stringSet(leftName).any(canonical.stringSet(rightName)::contains),
                )
            }
        }
    }

    private fun parseJsonObject(path: String): Map<String, Any?> =
        StrictJsonParser(repoFile(path).readText()).parse() as Map<String, Any?>

    private fun Map<String, Any?>.stringSet(name: String): Set<String> = stringList(name).toSet()

    @Suppress("UNCHECKED_CAST")
    private fun Map<String, Any?>.stringList(name: String): List<String> = getValue(name) as List<String>

    @Suppress("UNCHECKED_CAST")
    private fun Map<String, Any?>.objectList(name: String): List<Map<String, Any?>> =
        getValue(name) as List<Map<String, Any?>>

    private fun repoFile(path: String): File {
        var directory = File(System.getProperty("user.dir")).absoluteFile
        repeat(6) {
            File(directory, path).takeIf(File::isFile)?.let { return it }
            directory = directory.parentFile ?: error("Cannot locate repository file: $path")
        }
        error("Cannot locate repository file: $path")
    }
}

/** Small dependency-free JSON parser used only by offline JVM contract tests. */
private class StrictJsonParser(private val source: String) {
    private var index = 0

    fun parse(): Any? {
        val value = value()
        whitespace()
        check(index == source.length) { "Unexpected trailing JSON at $index" }
        return value
    }

    private fun value(): Any? {
        whitespace()
        return when (source.getOrNull(index)) {
            '{' -> objectValue()
            '[' -> arrayValue()
            '"' -> stringValue()
            't' -> literal("true", true)
            'f' -> literal("false", false)
            'n' -> literal("null", null)
            else -> numberValue()
        }
    }

    private fun objectValue(): Map<String, Any?> {
        expect('{')
        val result = linkedMapOf<String, Any?>()
        whitespace()
        if (consume('}')) return result
        while (true) {
            val key = stringValue()
            whitespace()
            expect(':')
            check(result.put(key, value()) == null) { "Duplicate JSON key: $key" }
            whitespace()
            if (consume('}')) return result
            expect(',')
            whitespace()
        }
    }

    private fun arrayValue(): List<Any?> {
        expect('[')
        val result = mutableListOf<Any?>()
        whitespace()
        if (consume(']')) return result
        while (true) {
            result += value()
            whitespace()
            if (consume(']')) return result
            expect(',')
        }
    }

    private fun stringValue(): String {
        expect('"')
        val result = StringBuilder()
        while (true) {
            val character = source.getOrNull(index++) ?: error("Unterminated JSON string")
            when (character) {
                '"' -> return result.toString()
                '\\' -> {
                    val escaped = source.getOrNull(index++) ?: error("Unterminated JSON escape")
                    result.append(
                        when (escaped) {
                            '"', '\\', '/' -> escaped
                            'b' -> '\b'
                            'f' -> '\u000c'
                            'n' -> '\n'
                            'r' -> '\r'
                            't' -> '\t'
                            'u' -> source.substring(index, index + 4).toInt(16).toChar().also { index += 4 }
                            else -> error("Invalid JSON escape: $escaped")
                        },
                    )
                }
                else -> result.append(character)
            }
        }
    }

    private fun numberValue(): Number {
        val start = index
        while (source.getOrNull(index)?.let { it in "-+0123456789.eE" } == true) index++
        check(index > start) { "Expected JSON value at $index" }
        val text = source.substring(start, index)
        return text.toLongOrNull() ?: text.toDouble()
    }

    private fun <T> literal(text: String, value: T): T {
        check(source.startsWith(text, index)) { "Expected $text at $index" }
        index += text.length
        return value
    }

    private fun whitespace() {
        while (source.getOrNull(index)?.isWhitespace() == true) index++
    }

    private fun expect(character: Char) {
        check(consume(character)) { "Expected $character at $index" }
    }

    private fun consume(character: Char): Boolean {
        if (source.getOrNull(index) != character) return false
        index++
        return true
    }
}

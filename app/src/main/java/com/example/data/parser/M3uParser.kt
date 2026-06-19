package com.example.data.parser

import com.example.data.model.IptvChannel
import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader

object M3uParser {
    fun parse(inputStream: InputStream, playlistId: Int): List<IptvChannel> {
        val channels = mutableListOf<IptvChannel>()
        try {
            val reader = BufferedReader(InputStreamReader(inputStream))
            var line: String?
            var currentExtInf: String? = null

            while (reader.readLine().also { line = it } != null) {
                val trimmed = line?.trim() ?: continue
                if (trimmed.isEmpty()) continue

                if (trimmed.startsWith("#EXTINF:")) {
                    currentExtInf = trimmed
                } else if (!trimmed.startsWith("#")) {
                    // This is the URL line
                    if (currentExtInf != null) {
                        val channel = parseExtInfLine(currentExtInf, trimmed, playlistId)
                        channels.add(channel)
                        currentExtInf = null
                    } else {
                        // Standard URL without EXTINF info
                        channels.add(
                            IptvChannel(
                                name = trimmed.substringAfterLast("/").substringBeforeLast("."),
                                streamUrl = trimmed,
                                category = "Diğer",
                                playlistId = playlistId
                            )
                        )
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return channels
    }

    private fun parseExtInfLine(extInf: String, url: String, playlistId: Int): IptvChannel {
        // Example: #EXTINF:-1 tvg-logo="logoUrl" group-title="Category",Channel Name
        var logoUrl = ""
        var category = "Diğer"
        var name = ""

        // Extract logo
        val logoRegex = """tvg-logo="([^"]*)"""".toRegex()
        val logoMatch = logoRegex.find(extInf)
        if (logoMatch != null) {
            logoUrl = logoMatch.groupValues[1]
        }

        // Extract category/group
        val groupRegex = """group-title="([^"]*)"""".toRegex()
        val groupMatch = groupRegex.find(extInf)
        if (groupMatch != null) {
            category = groupMatch.groupValues[1]
        }

        // Extract name (after comma)
        val commaIndex = extInf.lastIndexOf(',')
        if (commaIndex != -1 && commaIndex < extInf.length - 1) {
            name = extInf.substring(commaIndex + 1).trim()
        }

        if (name.isEmpty()) {
            val nameRegex = """tvg-name="([^"]*)"""".toRegex()
            val nameMatch = nameRegex.find(extInf)
            name = if (nameMatch != null) {
                nameMatch.groupValues[1]
            } else {
                url.substringAfterLast("/").substringBeforeLast(".")
            }
        }

        return IptvChannel(
            name = name,
            streamUrl = url,
            logoUrl = logoUrl,
            category = category.ifEmpty { "Diğer" },
            playlistId = playlistId
        )
    }
}

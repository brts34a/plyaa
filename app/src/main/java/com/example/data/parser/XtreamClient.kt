package com.example.data.parser

import com.example.data.model.IptvChannel
import com.example.data.model.IptvPlaylist
import com.example.data.model.IptvAccountInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

object XtreamClient {
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    suspend fun testCredentials(playlist: IptvPlaylist): Boolean = withContext(Dispatchers.IO) {
        try {
            // Trim any trailing slashes from server URL
            val serverUrl = playlist.url.trimEnd('/')
            val url = "$serverUrl/player_api.php?username=${playlist.username}&password=${playlist.password}"
            val request = Request.Builder().url(url).build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@withContext false
                val body = response.body?.string() ?: return@withContext false
                val json = JSONObject(body)
                val userInfo = json.optJSONObject("user_info")
                if (userInfo != null) {
                    val status = userInfo.optString("status")
                    return@withContext status != "Expired"
                }
                return@withContext true
            }
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    suspend fun fetchAccountDetails(playlist: IptvPlaylist): IptvAccountInfo = withContext(Dispatchers.IO) {
        if (playlist.type == "m3u") {
            return@withContext IptvAccountInfo(
                username = "M3U Listesi",
                status = "Aktif",
                expiryDate = "Süresiz / Bağımsız",
                remainingDaysOrMonths = "Süresiz Üyelik",
                maxConnections = "Sınırsız",
                activeConnections = "0",
                serverUrl = playlist.url
            )
        }
        try {
            val serverUrl = playlist.url.trimEnd('/')
            val url = "$serverUrl/player_api.php?username=${playlist.username}&password=${playlist.password}"
            val request = Request.Builder().url(url).build()
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) {
                    val body = response.body?.string()
                    if (!body.isNullOrEmpty() && body.trim().startsWith("{")) {
                        val json = JSONObject(body)
                        val userInfo = json.optJSONObject("user_info")
                        if (userInfo != null) {
                            val username = userInfo.optString("username", playlist.username)
                            val status = userInfo.optString("status", "Active")
                            val expDateRaw = userInfo.optString("exp_date", "")
                            
                            var expiryDateStr = "Süresiz"
                            var remainingStr = "Süresiz Üyelik"
                            
                            if (expDateRaw.isNotEmpty() && expDateRaw != "null") {
                                try {
                                    val timestamp = expDateRaw.toLong() * 1000
                                    val sdf = java.text.SimpleDateFormat("dd/MM/yyyy", java.util.Locale.getDefault())
                                    expiryDateStr = sdf.format(java.util.Date(timestamp))
                                    
                                    val diffMs = timestamp - System.currentTimeMillis()
                                    remainingStr = if (diffMs <= 0) {
                                        "Süresi Doldu"
                                    } else {
                                        val days = diffMs / (1000 * 60 * 60 * 24)
                                        val months = days / 30
                                        val remainingDays = days % 30
                                        if (months > 0) {
                                            "$months Ay $remainingDays Gün Kaldı"
                                        } else {
                                            "$remainingDays Gün Kaldı"
                                        }
                                    }
                                } catch (e: Exception) {
                                    expiryDateStr = expDateRaw
                                    remainingStr = "Süre Hesaplanamadı"
                                }
                            }
                            
                            val maxConnections = userInfo.optString("max_connections", "1")
                            val activeConnections = userInfo.optString("active_cons", "0")
                            
                            return@withContext IptvAccountInfo(
                                username = username,
                                status = if (status.lowercase() == "active") "Aktif" else status,
                                expiryDate = expiryDateStr,
                                remainingDaysOrMonths = remainingStr,
                                maxConnections = maxConnections,
                                activeConnections = activeConnections,
                                serverUrl = serverUrl
                            )
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return@withContext IptvAccountInfo(
            username = playlist.username,
            status = "Bağlanılamadı",
            expiryDate = "Bilinmiyor",
            remainingDaysOrMonths = "Bağlantı Hatası",
            maxConnections = "1",
            activeConnections = "0",
            serverUrl = playlist.url
        )
    }

    suspend fun fetchChannels(playlist: IptvPlaylist): List<IptvChannel> = withContext(Dispatchers.IO) {
        val channels = mutableListOf<IptvChannel>()
        try {
            val serverUrl = playlist.url.trimEnd('/')
            
            // 1. Get Categories
            val categoriesUrl = "$serverUrl/player_api.php?username=${playlist.username}&password=${playlist.password}&action=get_live_categories"
            val catRequest = Request.Builder().url(categoriesUrl).build()
            val categoryMap = mutableMapOf<String, String>() // category_id -> category_name
            
            try {
                client.newCall(catRequest).execute().use { response ->
                    if (response.isSuccessful) {
                        val body = response.body?.string()
                        if (!body.isNullOrEmpty() && body.trim().startsWith("[")) {
                            val jsonArr = JSONArray(body)
                            for (i in 0 until jsonArr.length()) {
                                val obj = jsonArr.getJSONObject(i)
                                val catId = obj.optString("category_id")
                                val catName = obj.optString("category_name")
                                if (catId.isNotEmpty() && catName.isNotEmpty()) {
                                    categoryMap[catId] = catName
                                }
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }

            // 2. Get Streams
            val streamsUrl = "$serverUrl/player_api.php?username=${playlist.username}&password=${playlist.password}&action=get_live_streams"
            val streamRequest = Request.Builder().url(streamsUrl).build()
            client.newCall(streamRequest).execute().use { response ->
                if (response.isSuccessful) {
                    val body = response.body?.string()
                    if (!body.isNullOrEmpty() && body.trim().startsWith("[")) {
                        val jsonArr = JSONArray(body)
                        for (i in 0 until jsonArr.length()) {
                            val obj = jsonArr.getJSONObject(i)
                            val name = obj.optString("name")
                            val streamId = obj.optInt("stream_id")
                            val iconUrl = obj.optString("stream_icon")
                            val catId = obj.optString("category_id")
                            val ext = obj.optString("container_extension", "ts")

                            val categoryName = categoryMap[catId] ?: "Diğer"
                            // http://<server_url>/live/<username>/<password>/<stream_id>.<extension>
                            val streamUrl = "$serverUrl/live/${playlist.username}/${playlist.password}/$streamId.$ext"

                            channels.add(
                                IptvChannel(
                                    name = name,
                                    streamUrl = streamUrl,
                                    logoUrl = iconUrl,
                                    category = categoryName,
                                    playlistId = playlist.id,
                                    xtreamStreamId = streamId
                                )
                            )
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return@withContext channels
    }

    private fun decodeBase64Safely(input: String): String {
        if (input.isNullOrBlank()) return ""
        if (input.contains(" ") || input.contains("\n") || input.contains("\r")) return input
        try {
            val decodedBytes = android.util.Base64.decode(input, android.util.Base64.DEFAULT)
            val decodedStr = String(decodedBytes, Charsets.UTF_8)
            
            // Check for control characters or Unicode replacement char indicating failed/corrupted decode
            var hasControlChars = false
            for (char in decodedStr) {
                val code = char.code
                if (code in 0..31 && code != 9 && code != 10 && code != 13) {
                    hasControlChars = true
                    break
                }
                if (code == 65533) {
                    hasControlChars = true
                    break
                }
            }
            if (!hasControlChars && decodedStr.isNotEmpty()) {
                return decodedStr
            }
        } catch (e: Exception) {
            // keep original on any parsing exception
        }
        return input
    }

    suspend fun fetchShortEpg(playlist: IptvPlaylist, streamId: Int): List<com.example.data.model.EpgProgram> = withContext(Dispatchers.IO) {
        val programs = mutableListOf<com.example.data.model.EpgProgram>()
        try {
            val serverUrl = playlist.url.trimEnd('/')
            val url = "$serverUrl/player_api.php?username=${playlist.username}&password=${playlist.password}&action=get_short_epg&stream_id=$streamId"
            val request = Request.Builder().url(url).build()
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) {
                    val body = response.body?.string()
                    if (!body.isNullOrEmpty() && body.trim().startsWith("{")) {
                        val jsonObj = JSONObject(body)
                        val listings = jsonObj.optJSONArray("epg_listings")
                        if (listings != null) {
                            for (i in 0 until listings.length()) {
                                val item = listings.getJSONObject(i)
                                val titleRaw = item.optString("title")
                                val title = decodeBase64Safely(titleRaw)

                                val descriptionRaw = item.optString("description")
                                val description = decodeBase64Safely(descriptionRaw)

                                val startTimestamp = item.optLong("start_timestamp", 0L)
                                val endTimestamp = item.optLong("end_timestamp", 0L)
                                val startStr = item.optString("start")
                                val endStr = item.optString("end")

                                val startMs = if (startTimestamp > 0L) {
                                    if (startTimestamp < 1000000000000L) startTimestamp * 1000L else startTimestamp
                                } else 0L
                                val endMs = if (endTimestamp > 0L) {
                                    if (endTimestamp < 1000000000000L) endTimestamp * 1000L else endTimestamp
                                } else 0L

                                val sdf = java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
                                val startStrFormatted = if (startMs > 0L) sdf.format(java.util.Date(startMs)) else startStr
                                val endStrFormatted = if (endMs > 0L) sdf.format(java.util.Date(endMs)) else endStr

                                if (title.isNotEmpty()) {
                                    programs.add(
                                        com.example.data.model.EpgProgram(
                                            title = title,
                                            description = description,
                                            startTimestamp = startTimestamp,
                                            endTimestamp = endTimestamp,
                                            startStr = startStrFormatted,
                                            endStr = endStrFormatted
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return@withContext programs
    }
}

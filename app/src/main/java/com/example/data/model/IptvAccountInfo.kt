package com.example.data.model

data class IptvAccountInfo(
    val username: String = "",
    val status: String = "Bilinmiyor",
    val expiryDate: String = "Belirsiz",
    val remainingDaysOrMonths: String = "Süresiz / Belirsiz",
    val maxConnections: String = "1",
    val activeConnections: String = "0",
    val liveChannelsCount: Int = 0,
    val moviesCount: Int = 0,
    val seriesCount: Int = 0,
    val serverUrl: String = ""
)

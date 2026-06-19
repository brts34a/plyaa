package com.example.data.model

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "playlists")
data class IptvPlaylist(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val name: String,
    val type: String, // "m3u", "xtream"
    val url: String = "", // M3U URL or Xtream Server URL
    val username: String = "",
    val password: String = "",
    val createdAt: Long = System.currentTimeMillis()
)

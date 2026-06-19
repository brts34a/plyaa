package com.example.data.model

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "favorites")
data class IptvFavorite(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val playlistId: Int,
    val name: String,
    val streamUrl: String,
    val logoUrl: String = "",
    val category: String = "",
    val addedAt: Long = System.currentTimeMillis()
)

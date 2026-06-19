package com.example.data.model

data class IptvChannel(
    val name: String,
    val streamUrl: String,
    val logoUrl: String = "",
    val category: String = "Diğer",
    val playlistId: Int = 0,
    val xtreamStreamId: Int? = null,
    val isFavorite: Boolean = false
)

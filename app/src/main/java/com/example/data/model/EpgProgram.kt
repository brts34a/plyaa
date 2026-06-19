package com.example.data.model

data class EpgProgram(
    val title: String,
    val description: String = "",
    val startTimestamp: Long = 0L,
    val endTimestamp: Long = 0L,
    val startStr: String = "",
    val endStr: String = ""
)

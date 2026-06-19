package com.example.data.database

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.example.data.model.IptvFavorite
import kotlinx.coroutines.flow.Flow

@Dao
interface FavoriteDao {
    @Query("SELECT * FROM favorites ORDER BY addedAt DESC")
    fun getAllFavorites(): Flow<List<IptvFavorite>>

    @Query("SELECT * FROM favorites WHERE playlistId = :playlistId")
    fun getFavoritesForPlaylist(playlistId: Int): Flow<List<IptvFavorite>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertFavorite(favorite: IptvFavorite)

    @Query("DELETE FROM favorites WHERE playlistId = :playlistId AND streamUrl = :streamUrl")
    suspend fun deleteFavorite(playlistId: Int, streamUrl: String)

    @Query("SELECT EXISTS(SELECT 1 FROM favorites WHERE playlistId = :playlistId AND streamUrl = :streamUrl LIMIT 1)")
    suspend fun isFavorite(playlistId: Int, streamUrl: String): Boolean
}

package com.example.ui.screens

import android.content.res.Configuration
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import coil.compose.AsyncImage
import com.example.R
import com.example.data.model.IptvChannel
import com.example.data.model.IptvPlaylist
import com.example.ui.components.VideoPlayer
import com.example.ui.viewmodel.IptvViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// Premium iOS Dion Palette Constants
private val IosDeepBlack = Color(0xFF070709)
private val IosDarkBg = Color(0xFF0F0F12)
private val IosGrayBg = Color(0xFF16161B)
private val IosTabSelected = Color(0xFF0A84FF) // Neon Blue
private val IosGoldAccent = Color(0xFFFF9F0A) // Premium Orange-Gold
private val IosPinkAccent = Color(0xFFBF5AF2) // Violet-Pink Fusion
private val IosGreenAccent = Color(0xFF30D158) // Vivid Emerald
private val IosRedAccent = Color(0xFFFF453A) // Neon Red
private val IosWhite = Color(0xFFFFFFFF)
private val IosDusty = Color(0xFF8E8E93)
private val IosBorder = Color(0xFF24242B)

enum class Tab {
    Discover,
    LiveTv,
    Favorites,
    Settings
}

data class VideoQualityOption(
    val name: String,
    val mediaTrackGroup: androidx.media3.common.TrackGroup?,
    val trackIndex: Int?,
    val isSelected: Boolean = false
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    viewModel: IptvViewModel,
    modifier: Modifier = Modifier
) {
    val playlists by viewModel.playlists.collectAsStateWithLifecycle()
    val isLandscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val favorites by viewModel.favorites.collectAsStateWithLifecycle()
    val selectedPlaylist by viewModel.selectedPlaylist.collectAsStateWithLifecycle()
    val loadingChannels by viewModel.loadingChannels.collectAsStateWithLifecycle()
    val channelsError by viewModel.channelsError.collectAsStateWithLifecycle()
    val filteredChannels by viewModel.filteredChannels.collectAsStateWithLifecycle()
    val searchQuery by viewModel.searchQuery.collectAsStateWithLifecycle()
    val selectedCategory by viewModel.selectedCategory.collectAsStateWithLifecycle()
    val categories by viewModel.categories.collectAsStateWithLifecycle()
    val currentChannel by viewModel.currentChannel.collectAsStateWithLifecycle()
    val currentChannelEpg by viewModel.currentChannelEpg.collectAsStateWithLifecycle()
    val loadingEpg by viewModel.loadingEpg.collectAsStateWithLifecycle()
    val channelsActiveEpg by viewModel.channelsActiveEpg.collectAsStateWithLifecycle()

    var currentTab by rememberSaveable { mutableStateOf(Tab.Discover) }

    var videoWidth by remember { mutableStateOf(0) }
    var videoHeight by remember { mutableStateOf(0) }
    var currentFps by remember { mutableStateOf("") }
    var currentBitrate by remember { mutableStateOf("") }
    var currentResolution by remember { mutableStateOf("") }
    var showQualitySelector by remember { mutableStateOf(false) }

    var showAddPlaylistForm by remember { mutableStateOf(false) }
    var playlistType by remember { mutableStateOf("m3u") } // "m3u" or "xtream"
    var pName by remember { mutableStateOf("") }
    var pUrl by remember { mutableStateOf("") }
    var pUser by remember { mutableStateOf("") }
    var pPass by remember { mutableStateOf("") }
    var validationError by remember { mutableStateOf<String?>(null) }

    // Player Options State
    var selectedResizeMode by rememberSaveable { mutableIntStateOf(AspectRatioFrameLayout.RESIZE_MODE_FIT) }
    var isPlayerPlaying by rememberSaveable { mutableStateOf(true) }
    var playerErrorMsg by rememberSaveable { mutableStateOf<String?>(null) }
    var showPlayerControls by rememberSaveable { mutableStateOf(true) }
    var isPlayerMinimized by rememberSaveable { mutableStateOf(false) }

    // Quick channel drawer state in player overlay
    var showPlayerChannelList by rememberSaveable { mutableStateOf(false) }

    BackHandler(enabled = currentChannel != null) {
        if (showPlayerChannelList) {
            showPlayerChannelList = false
        } else if (!isPlayerMinimized) {
            isPlayerMinimized = true
        } else {
            viewModel.selectChannel(null)
        }
    }

    val coroutineScope = rememberCoroutineScope()
    var retryJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    var retryCount by rememberSaveable { mutableIntStateOf(0) }
    var isAutoRetrying by rememberSaveable { mutableStateOf(false) }
    val maxRetries = 5

    val context = LocalContext.current

    // Immersive display & Status Bar toggle
    DisposableEffect(currentChannel, isPlayerMinimized, showPlayerControls) {
        val activity = context as? android.app.Activity
        val window = activity?.window
        if (window != null) {
            val insetsController = androidx.core.view.WindowCompat.getInsetsController(window, window.decorView)
            insetsController.systemBarsBehavior = androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            if (currentChannel != null && !isPlayerMinimized && !showPlayerControls) {
                insetsController.hide(androidx.core.view.WindowInsetsCompat.Type.systemBars())
            } else {
                insetsController.show(androidx.core.view.WindowInsetsCompat.Type.systemBars())
            }
        }
        onDispose {
            activity?.window?.let { win ->
                val ic = androidx.core.view.WindowCompat.getInsetsController(win, win.decorView)
                ic.show(androidx.core.view.WindowInsetsCompat.Type.systemBars())
            }
        }
    }

    // Auto-hide controls after 5 seconds of inactivity
    LaunchedEffect(showPlayerControls, isPlayerPlaying, showPlayerChannelList) {
        if (showPlayerControls && isPlayerPlaying && !showPlayerChannelList) {
            delay(5000)
            showPlayerControls = false
        }
    }

    val exoPlayer = remember {
        val trackSelector = androidx.media3.exoplayer.trackselection.DefaultTrackSelector(context).apply {
            setParameters(
                buildUponParameters()
                    .setMaxVideoSize(Int.MAX_VALUE, Int.MAX_VALUE)
                    .setMaxVideoFrameRate(60)
                    .setForceHighestSupportedBitrate(true)
            )
        }
        ExoPlayer.Builder(context)
            .setTrackSelector(trackSelector)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                    .build(),
                true
            )
            .setVideoChangeFrameRateStrategy(C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS)
            .build().apply {
                playWhenReady = isPlayerPlaying
                repeatMode = Player.REPEAT_MODE_OFF
            }
    }

    DisposableEffect(exoPlayer) {
        val listener = object : Player.Listener {
            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                playerErrorMsg = error.localizedMessage ?: "Bağlantı kesildi"
                
                if (retryCount < maxRetries) {
                    isAutoRetrying = true
                    retryCount++
                    val retryDelayMs = (retryCount * 3000L).coerceAtMost(12000L)
                    
                    retryJob?.cancel()
                    retryJob = coroutineScope.launch {
                        delay(retryDelayMs)
                        if (isAutoRetrying) {
                            playerErrorMsg = "Yeniden bağlanılıyor... (Deneme $retryCount/$maxRetries)"
                            exoPlayer.prepare()
                            exoPlayer.play()
                        }
                    }
                } else {
                    isAutoRetrying = false
                    playerErrorMsg = "Yayın koptu. Lütfen kanalı/bağlantınızı kontrol edip Yenile butonuna basın."
                }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_READY) {
                    retryCount = 0
                    isAutoRetrying = false
                    playerErrorMsg = null
                    retryJob?.cancel()
                    retryJob = null
                } else if (playbackState == Player.STATE_ENDED) {
                    if (retryCount < maxRetries) {
                        isAutoRetrying = true
                        retryCount++
                        retryJob?.cancel()
                        retryJob = coroutineScope.launch {
                            delay(3000L)
                            if (isAutoRetrying) {
                                playerErrorMsg = "Yayın bitti, tekrar bağlanılıyor... (Deneme $retryCount/$maxRetries)"
                                exoPlayer.prepare()
                                exoPlayer.play()
                            }
                        }
                    }
                }
            }

            override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                val w = videoSize.width
                val h = videoSize.height
                videoWidth = w
                videoHeight = h
                currentResolution = if (w > 0 && h > 0) {
                    when {
                        w >= 3840 -> "4K UHD"
                        w >= 1920 -> "FHD 1080p"
                        w >= 1280 -> "HD 720p"
                        else -> "SD ${h}p"
                    }
                } else {
                    ""
                }
            }

            override fun onTracksChanged(tracks: androidx.media3.common.Tracks) {
                val videoGroup = tracks.groups.firstOrNull { it.type == C.TRACK_TYPE_VIDEO && it.isSelected }
                if (videoGroup != null) {
                    for (i in 0 until videoGroup.length) {
                        if (videoGroup.isTrackSelected(i)) {
                            val format = videoGroup.getTrackFormat(i)
                            val w = format.width
                            val h = format.height
                            videoWidth = w
                            videoHeight = h
                            currentResolution = when {
                                w >= 3840 -> "4K UHD"
                                w >= 1920 -> "FHD 1080p"
                                w >= 1280 -> "HD 720p"
                                h > 0 -> "SD ${h}p"
                                else -> "Otomatik"
                            }
                            val fps = format.frameRate
                            currentFps = if (fps > 0f) {
                                "${fps.toInt()} FPS"
                            } else {
                                when {
                                    h >= 1080 -> "50 FPS"
                                    h >= 720 -> "50 FPS"
                                    h > 0 -> "25 FPS"
                                    else -> "50 FPS"
                                }
                            }

                            val br = format.bitrate
                            currentBitrate = if (br > 0) {
                                val mbps = br.toFloat() / 1_000_000f
                                if (mbps >= 0.1f) String.format("%.1f Mbps", mbps) else "${br / 1000} Kbps"
                            } else {
                                ""
                            }
                            break
                        }
                    }
                } else {
                    videoWidth = 0
                    videoHeight = 0
                    currentResolution = "CANLI"
                    currentFps = ""
                    currentBitrate = ""
                }
            }
        }
        exoPlayer.addListener(listener)
        onDispose {
            exoPlayer.removeListener(listener)
            exoPlayer.stop()
            exoPlayer.release()
        }
    }

    LaunchedEffect(currentChannel, exoPlayer) {
        retryCount = 0
        isAutoRetrying = false
        playerErrorMsg = null
        retryJob?.cancel()
        retryJob = null

        val streamUrl = currentChannel?.streamUrl
        if (!streamUrl.isNullOrBlank()) {
            playerErrorMsg = null
            try {
                val mediaItem = MediaItem.fromUri(streamUrl)
                exoPlayer.setMediaItem(mediaItem)
                exoPlayer.prepare()
                exoPlayer.play()
            } catch (e: Exception) {
                playerErrorMsg = e.localizedMessage ?: "Yayın başlatılamadı."
            }
        } else {
            exoPlayer.stop()
            exoPlayer.clearMediaItems()
        }
    }

    LaunchedEffect(isPlayerPlaying) {
        exoPlayer.playWhenReady = isPlayerPlaying
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(IosDeepBlack)
    ) {
        // Main Container Flow
        if (playlists.isEmpty() || showAddPlaylistForm) {
            // Setup & Login Screen / Preset loader
            OnboardingAndAddPlaylistForm(
                playlists = playlists,
                playlistType = playlistType,
                pName = pName,
                pUrl = pUrl,
                pUser = pUser,
                pPass = pPass,
                validationError = validationError,
                loadingChannels = loadingChannels,
                onBack = {
                    showAddPlaylistForm = false
                    validationError = null
                },
                onTypeChange = { playlistType = it },
                onNameChange = { pName = it },
                onUrlChange = { pUrl = it },
                onUserChange = { pUser = it },
                onPassChange = { pPass = it },
                onLoadTurkPreroll = {
                    viewModel.addPlaylist(
                        name = "TR Kamu Kanalları",
                        type = "m3u",
                        url = "https://iptv-org.github.io/iptv/countries/tr.m3u",
                        onSuccess = {
                            showAddPlaylistForm = false
                        },
                        onError = { validationError = it }
                    )
                },
                onSave = {
                    if (pName.trim().isEmpty() || pUrl.trim().isEmpty()) {
                        validationError = "Ad ve Link alanları zorunludur."
                    } else {
                        validationError = null
                        viewModel.addPlaylist(
                            name = pName,
                            type = playlistType,
                            url = pUrl,
                            username = pUser,
                            password = pPass,
                            onSuccess = {
                                showAddPlaylistForm = false
                                pName = ""
                                pUrl = ""
                                pUser = ""
                                pPass = ""
                            },
                            onError = { validationError = it }
                        )
                    }
                }
            )
        } else {
            // Main App Workspace divided into Tab Content Screens
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .windowInsetsPadding(WindowInsets.safeDrawing)
            ) {
                // Screen Headers
                HeaderTopBar(
                    selectedPlaylist = selectedPlaylist,
                    playlists = playlists,
                    viewModel = viewModel,
                    onAddNewTrigger = { showAddPlaylistForm = true },
                    onNavigateToSettings = { currentTab = Tab.Settings }
                )

                // Navigation Workspace
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                ) {
                    when (currentTab) {
                        Tab.Discover -> DiscoverTabContent(
                            viewModel = viewModel,
                            filteredChannels = filteredChannels,
                            favorites = favorites,
                            onSelectChannel = {
                                viewModel.selectChannel(it)
                                isPlayerMinimized = false
                            },
                            onTabSwitch = { currentTab = it }
                        )

                        Tab.LiveTv -> LiveTvTabContent(
                            viewModel = viewModel,
                            filteredChannels = filteredChannels,
                            categories = categories,
                            selectedCategory = selectedCategory,
                            searchQuery = searchQuery,
                            loadingChannels = loadingChannels,
                            channelsError = channelsError,
                            currentChannel = currentChannel,
                            onSelectChannel = {
                                viewModel.selectChannel(it)
                                isPlayerMinimized = false
                            }
                        )

                        Tab.Favorites -> FavoritesTabContent(
                            viewModel = viewModel,
                            favorites = favorites,
                            filteredChannels = filteredChannels,
                            onSelectChannel = {
                                viewModel.selectChannel(it)
                                isPlayerMinimized = false
                            }
                        )

                        Tab.Settings -> SettingsTabContent(
                            viewModel = viewModel,
                            playlists = playlists,
                            selectedPlaylist = selectedPlaylist,
                            onTriggerAdd = { showAddPlaylistForm = true }
                        )
                    }

                    // Mini Player overlay sitting right above our glassy bar
                    currentChannel?.let { playing ->
                        if (isPlayerMinimized) {
                            MiniPlayerDocked(
                                playing = playing,
                                isPlaying = isPlayerPlaying,
                                exoPlayer = exoPlayer,
                                onTogglePlay = { isPlayerPlaying = !isPlayerPlaying },
                                onClose = { viewModel.selectChannel(null) },
                                onRestore = { isPlayerMinimized = false },
                                modifier = Modifier
                                    .align(Alignment.BottomCenter)
                                    .padding(bottom = 85.dp)
                            )
                        }
                    }
                }
            }

            // Glassmorphic Floating Bottom Bar
            GlassyBottomBar(
                currentTab = currentTab,
                onTabSelect = { currentTab = it },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
            )
        }

        // Fullscreen Active Player screen with advanced controls Overlay
        currentChannel?.let { playing ->
            AnimatedVisibility(
                visible = !isPlayerMinimized,
                enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
                exit = slideOutVertically(targetOffsetY = { it }) + fadeOut()
            ) {
                FullScreenPlayerOverlay(
                    playing = playing,
                    isLandscape = isLandscape,
                    exoPlayer = exoPlayer,
                    isPlayerPlaying = isPlayerPlaying,
                    currentResolution = currentResolution,
                    currentFps = currentFps,
                    currentBitrate = currentBitrate,
                    playerErrorMsg = playerErrorMsg,
                    showPlayerControls = showPlayerControls,
                    showPlayerChannelList = showPlayerChannelList,
                    selectedResizeMode = selectedResizeMode,
                    filteredChannels = filteredChannels,
                    categories = categories,
                    selectedCategory = selectedCategory,
                    viewModel = viewModel,
                    onTogglePlay = { isPlayerPlaying = !isPlayerPlaying },
                    onToggleResize = {
                        selectedResizeMode = when (selectedResizeMode) {
                            AspectRatioFrameLayout.RESIZE_MODE_FIT -> AspectRatioFrameLayout.RESIZE_MODE_FILL
                            AspectRatioFrameLayout.RESIZE_MODE_FILL -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                            else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
                        }
                    },
                    onToggleFav = { viewModel.toggleFavorite(playing) },
                    onRefresh = {
                        playerErrorMsg = null
                        retryCount = 0
                        isAutoRetrying = false
                        viewModel.selectChannel(playing)
                    },
                    onToggleControls = { showPlayerControls = !showPlayerControls },
                    onMinimize = { isPlayerMinimized = true },
                    onClose = { viewModel.selectChannel(null) },
                    onToggleChannelList = { showPlayerChannelList = !showPlayerChannelList },
                    onSelectChannelFromList = { viewModel.selectChannel(it) },
                    onSelectCategoryFromList = { viewModel.setSelectedCategory(it) }
                )
            }
        }
    }
}

// ======================== SUBCOMPONENTS ========================

@Composable
fun HeaderTopBar(
    selectedPlaylist: IptvPlaylist?,
    playlists: List<IptvPlaylist>,
    viewModel: IptvViewModel,
    onAddNewTrigger: () -> Unit,
    onNavigateToSettings: () -> Unit
) {
    var dropdownExpanded by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(IosDeepBlack)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Column(
            modifier = Modifier
                .clickable { if (playlists.size > 1) dropdownExpanded = true }
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Text(
                    text = "IPTV",
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Black,
                    color = IosWhite,
                    letterSpacing = 1.sp
                )
                if (playlists.size > 1) {
                    Icon(
                        imageVector = Icons.Default.KeyboardArrowDown,
                        contentDescription = "Kaynak Değiştir",
                        tint = IosTabSelected,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }
            Text(
                text = selectedPlaylist?.name ?: "IPTV Kaynağı Seçilmedi",
                fontSize = 11.sp,
                color = IosDusty,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )

            DropdownMenu(
                expanded = dropdownExpanded,
                onDismissRequest = { dropdownExpanded = false },
                modifier = Modifier.background(IosGrayBg)
            ) {
                playlists.forEach { item ->
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(item.name, color = IosWhite, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                Text(if (item.type == "m3u") "M3U Bağlantısı" else "Xtream codes info", color = IosDusty, fontSize = 11.sp)
                            }
                        },
                        onClick = {
                            viewModel.selectPlaylist(item)
                            dropdownExpanded = false
                        }
                    )
                }
            }
        }

        // Action Menu Buttons (Dion Style)
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            IconButton(
                onClick = onAddNewTrigger,
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(IosGrayBg)
            ) {
                Icon(
                    imageVector = Icons.Default.Add,
                    contentDescription = "Yeni Ekle",
                    tint = IosWhite,
                    modifier = Modifier.size(18.dp)
                )
            }

            IconButton(
                onClick = onNavigateToSettings,
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(IosGrayBg)
            ) {
                Icon(
                    imageVector = Icons.Default.AccountCircle,
                    contentDescription = "Yönetim",
                    tint = IosTabSelected,
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }
}

@Composable
fun OnboardingAndAddPlaylistForm(
    playlists: List<IptvPlaylist>,
    playlistType: String,
    pName: String,
    pUrl: String,
    pUser: String,
    pPass: String,
    validationError: String?,
    loadingChannels: Boolean,
    onBack: () -> Unit,
    onTypeChange: (String) -> Unit,
    onNameChange: (String) -> Unit,
    onUrlChange: (String) -> Unit,
    onUserChange: (String) -> Unit,
    onPassChange: (String) -> Unit,
    onLoadTurkPreroll: () -> Unit,
    onSave: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(IosDeepBlack)
            .padding(16.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Upper Dion Logo Shield Accent
        Box(
            modifier = Modifier
                .size(76.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(Brush.linearGradient(listOf(IosTabSelected, IosPinkAccent)))
                .padding(2.dp)
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(18.dp))
                    .background(IosDeepBlack),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Default.PlayCircleFilled,
                    contentDescription = null,
                    tint = IosTabSelected,
                    modifier = Modifier.size(44.dp)
                )
            }
        }

        Spacer(Modifier.height(16.dp))

        Text(
            text = "Dion IPTV Premium",
            fontSize = 24.sp,
            fontWeight = FontWeight.Black,
            color = IosWhite
        )
        Text(
            text = "Premium iOS IPTV Altyapısı ile Kesintisiz Yayın Deneyimi",
            fontSize = 12.sp,
            color = IosDusty,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 4.dp)
        )

        Spacer(Modifier.height(28.dp))

        // Form Card Wrapper
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = IosGrayBg),
            shape = RoundedCornerShape(20.dp)
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Text(
                    text = "YENİ BAĞLANTI PROFLİ EKLE",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = IosTabSelected,
                    letterSpacing = 1.sp
                )

                // Custom Segmented Control (iOS style)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(IosDarkBg)
                        .padding(2.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(8.dp))
                            .background(if (playlistType == "m3u") IosTabSelected else Color.Transparent)
                            .clickable { onTypeChange("m3u") }
                            .padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            "M3U Dosyası / Link",
                            color = if (playlistType == "m3u") IosWhite else IosDusty,
                            fontWeight = FontWeight.Bold,
                            fontSize = 12.sp
                        )
                    }

                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(8.dp))
                            .background(if (playlistType == "xtream") IosTabSelected else Color.Transparent)
                            .clickable { onTypeChange("xtream") }
                            .padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            "Xtream Codes API",
                            color = if (playlistType == "xtream") IosWhite else IosDusty,
                            fontWeight = FontWeight.Bold,
                            fontSize = 12.sp
                        )
                    }
                }

                // Input Rows styled nicely like iOS Inputs
                OutlinedTextField(
                    value = pName,
                    onValueChange = onNameChange,
                    placeholder = { Text("Mavi IPTV, Ev Yayını vb...", color = IosDusty, fontSize = 13.sp) },
                    label = { Text("Bağlantı Profili İsmi", color = IosTabSelected) },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = IosTabSelected,
                        unfocusedBorderColor = IosBorder,
                        focusedTextColor = IosWhite,
                        unfocusedTextColor = IosWhite,
                        focusedContainerColor = IosDarkBg,
                        unfocusedContainerColor = IosDarkBg
                    ),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth().testTag("playlist_name_input")
                )

                OutlinedTextField(
                    value = pUrl,
                    onValueChange = onUrlChange,
                    placeholder = { Text(if (playlistType == "m3u") "http://server.com/live.m3u" else "http://sunucuadresi.com:8080", color = IosDusty, fontSize = 13.sp) },
                    label = { Text(if (playlistType == "m3u") "M3U Playlist URL" else "Server Sunucu Adresi", color = IosTabSelected) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = IosTabSelected,
                        unfocusedBorderColor = IosBorder,
                        focusedTextColor = IosWhite,
                        unfocusedTextColor = IosWhite,
                        focusedContainerColor = IosDarkBg,
                        unfocusedContainerColor = IosDarkBg
                    ),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth().testTag("playlist_url_input")
                )

                if (playlistType == "xtream") {
                    OutlinedTextField(
                        value = pUser,
                        onValueChange = onUserChange,
                        placeholder = { Text("Kullanıcı Adı", color = IosDusty, fontSize = 13.sp) },
                        label = { Text("Username", color = IosTabSelected) },
                        singleLine = true,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = IosTabSelected,
                            unfocusedBorderColor = IosBorder,
                            focusedTextColor = IosWhite,
                            unfocusedTextColor = IosWhite,
                            focusedContainerColor = IosDarkBg,
                            unfocusedContainerColor = IosDarkBg
                        ),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth().testTag("xtream_user_input")
                    )

                    OutlinedTextField(
                        value = pPass,
                        onValueChange = onPassChange,
                        placeholder = { Text("••••••••", color = IosDusty) },
                        label = { Text("Password", color = IosTabSelected) },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = IosTabSelected,
                            unfocusedBorderColor = IosBorder,
                            focusedTextColor = IosWhite,
                            unfocusedTextColor = IosWhite,
                            focusedContainerColor = IosDarkBg,
                            unfocusedContainerColor = IosDarkBg
                        ),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth().testTag("xtream_pass_input")
                    )
                }

                validationError?.let {
                    Text(
                        text = it,
                        color = IosRedAccent,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(top = 2.dp)
                    )
                }

                // Form Buttons
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    if (playlists.isNotEmpty()) {
                        Button(
                            onClick = onBack,
                            colors = ButtonDefaults.buttonColors(containerColor = IosBorder),
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.weight(1f).height(46.dp)
                        ) {
                            Text("Vazgeç", color = IosWhite, fontWeight = FontWeight.Bold)
                        }
                    }

                    Button(
                        onClick = onSave,
                        colors = ButtonDefaults.buttonColors(containerColor = IosTabSelected),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier
                            .weight(1.5f)
                            .height(46.dp)
                            .testTag("save_source_button")
                    ) {
                        if (loadingChannels) {
                            CircularProgressIndicator(color = IosWhite, modifier = Modifier.size(20.dp))
                        } else {
                            Text("Bağlantıyı Kur", color = IosWhite, fontWeight = FontWeight.Black)
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        // Preload Turkish channels quick button if no list exists
        if (playlists.isEmpty()) {
            OutlinedButton(
                onClick = onLoadTurkPreroll,
                shape = RoundedCornerShape(14.dp),
                border = BorderStroke(1.dp, IosGoldAccent.copy(alpha = 0.4f)),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = IosGoldAccent),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp)
                    .testTag("load_turkish_preset_button")
            ) {
                Icon(Icons.Default.Tv, contentDescription = null, tint = IosGoldAccent, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Hazır Kamu Kanallarını (TR) İçe Aktar", color = IosGoldAccent, fontWeight = FontWeight.Bold, fontSize = 12.sp)
            }
        }
    }
}

@Composable
fun DiscoverTabContent(
    viewModel: IptvViewModel,
    filteredChannels: List<IptvChannel>,
    favorites: List<com.example.data.model.IptvFavorite>,
    onSelectChannel: (IptvChannel) -> Unit,
    onTabSwitch: (Tab) -> Unit
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 120.dp, start = 16.dp, end = 16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        // Neon Gradient Banner Card
        item {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 10.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .background(
                        Brush.linearGradient(
                            colors = listOf(
                                Color(0xFF1E1B4B), // Deep indigo
                                Color(0xFF0F172A), // Slate dark
                                Color(0xFF2E1065)  // Royal violet
                            )
                        )
                    )
                    .border(
                        BorderStroke(
                            1.dp,
                            Brush.linearGradient(
                                colors = listOf(Color.White.copy(alpha = 0.15f), Color.White.copy(alpha = 0.02f))
                            )
                        ),
                        RoundedCornerShape(24.dp)
                    )
            ) {
                // Glass glossy highlight vector arcs
                Column(
                    modifier = Modifier.padding(22.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .background(IosWhite.copy(alpha = 0.12f), RoundedCornerShape(8.dp))
                            .padding(horizontal = 8.dp, vertical = 4.dp)
                    ) {
                        Text(
                            text = "PREMIUM DESTEKLI",
                            fontSize = 8.sp,
                            fontWeight = FontWeight.Black,
                            color = IosGoldAccent,
                            letterSpacing = 1.sp
                        )
                    }

                    Spacer(Modifier.height(10.dp))

                    Text(
                        text = "Kesintisiz Akıllı \nYayın Akış Merkezi",
                        fontSize = 24.sp,
                        fontWeight = FontWeight.Black,
                        color = IosWhite,
                        lineHeight = 28.sp
                    )
                    Text(
                        text = "Özel H.265 / UHD Dekoder çekirdeği ile sıfır kayıplı ultra hızlı kanal yükleme.",
                        fontSize = 11.sp,
                        color = IosDusty,
                        modifier = Modifier.padding(top = 6.dp)
                    )

                    Spacer(Modifier.height(14.dp))

                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .background(IosTabSelected.copy(alpha = 0.2f), RoundedCornerShape(10.dp))
                                .border(1.dp, IosTabSelected.copy(alpha = 0.4f), RoundedCornerShape(10.dp))
                                .padding(horizontal = 10.dp, vertical = 5.dp)
                        ) {
                            Text("HEVC H.265", color = IosWhite, fontSize = 9.sp, fontWeight = FontWeight.Bold)
                        }

                        Box(
                            modifier = Modifier
                                .background(IosPinkAccent.copy(alpha = 0.2f), RoundedCornerShape(10.dp))
                                .border(1.dp, IosPinkAccent.copy(alpha = 0.4f), RoundedCornerShape(10.dp))
                                .padding(horizontal = 10.dp, vertical = 5.dp)
                        ) {
                            Text("10 Bit HDR", color = IosWhite, fontSize = 9.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }

        // Section: Featured channels (First 6 channels)
        if (filteredChannels.isNotEmpty()) {
            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "Öne Çıkan Canlı Kanallar",
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = IosWhite
                    )
                    Text(
                        text = "Tümünü Gör",
                        fontSize = 12.sp,
                        color = IosTabSelected,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.clickable { onTabSwitch(Tab.LiveTv) }
                    )
                }

                Spacer(Modifier.height(10.dp))

                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    items(filteredChannels.take(8)) { channel ->
                        Card(
                            modifier = Modifier
                                .width(120.dp)
                                .clickable { onSelectChannel(channel) },
                            colors = CardDefaults.cardColors(containerColor = IosGrayBg),
                            shape = RoundedCornerShape(16.dp),
                            border = BorderStroke(1.dp, IosBorder)
                        ) {
                            Column(
                                modifier = Modifier
                                    .padding(12.dp)
                                    .fillMaxWidth(),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(54.dp)
                                        .clip(RoundedCornerShape(12.dp))
                                        .background(IosDarkBg),
                                    contentAlignment = Alignment.Center
                                ) {
                                    AsyncImage(
                                        model = channel.logoUrl.ifEmpty { null },
                                        contentDescription = "Logo",
                                        fallback = painterResource(id = android.R.drawable.ic_menu_slideshow),
                                        modifier = Modifier.size(38.dp).clip(RoundedCornerShape(8.dp)),
                                        contentScale = ContentScale.Crop
                                    )
                                }

                                Spacer(Modifier.height(8.dp))

                                Text(
                                    text = channel.name,
                                    color = IosWhite,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold,
                                    maxLines = 1,
                                    textAlign = TextAlign.Center,
                                    overflow = TextOverflow.Ellipsis
                                )

                                Text(
                                    text = channel.category,
                                    color = IosTabSelected,
                                    fontSize = 8.sp,
                                    fontWeight = FontWeight.Black,
                                    maxLines = 1,
                                    textAlign = TextAlign.Center,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.padding(top = 2.dp)
                                )
                            }
                        }
                    }
                }
            }
        }

        // Section: Favorites Quick Row
        item {
            Text(
                text = "Hızlı Favori Kanallarım",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = IosWhite
            )

            Spacer(Modifier.height(10.dp))

            if (favorites.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .dashedBorder(1.dp, IosBorder, 16.dp)
                        .background(Color.Transparent)
                        .padding(24.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.FavoriteBorder,
                            contentDescription = null,
                            tint = IosDusty,
                            modifier = Modifier.size(24.dp)
                        )
                        Text(
                            text = "Henüz favoriye bir kanal eklenmedi.",
                            color = IosDusty,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium
                        )
                        Text(
                            text = "Canlı TV listesinden favoriye ekleyin.",
                            color = IosTabSelected,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.clickable { onTabSwitch(Tab.LiveTv) }
                        )
                    }
                }
            } else {
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    items(favorites) { item ->
                        val matchingChannel = filteredChannels.firstOrNull { it.streamUrl == item.streamUrl }
                        Card(
                            modifier = Modifier
                                .width(94.dp)
                                .clickable {
                                    matchingChannel?.let { onSelectChannel(it) } ?: onSelectChannel(
                                        IptvChannel(
                                            playlistId = item.playlistId,
                                            name = item.name,
                                            streamUrl = item.streamUrl,
                                            logoUrl = item.logoUrl,
                                            category = item.category,
                                            isFavorite = true
                                        )
                                    )
                                },
                            colors = CardDefaults.cardColors(containerColor = IosGrayBg),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Column(
                                modifier = Modifier
                                    .padding(10.dp)
                                    .fillMaxWidth(),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                AsyncImage(
                                    model = item.logoUrl.ifEmpty { null },
                                    contentDescription = null,
                                    fallback = painterResource(id = android.R.drawable.ic_menu_slideshow),
                                    modifier = Modifier
                                        .size(42.dp)
                                        .clip(RoundedCornerShape(8.dp))
                                )
                                Spacer(Modifier.height(6.dp))
                                Text(
                                    text = item.name,
                                    color = IosWhite,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    textAlign = TextAlign.Center
                                )
                            }
                        }
                    }
                }
            }
        }

        // Section: System and account subscription status card
        item {
            Card(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onTabSwitch(Tab.Settings) },
                colors = CardDefaults.cardColors(containerColor = IosGrayBg),
                shape = RoundedCornerShape(18.dp)
            ) {
                Row(
                    modifier = Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .background(IosGreenAccent.copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Default.VerifiedUser,
                            contentDescription = null,
                            tint = IosGreenAccent,
                            modifier = Modifier.size(20.dp)
                        )
                    }

                    Column(
                        modifier = Modifier.weight(1f)
                    ) {
                        Text(
                            text = "Abonelik Sınırsız / Ömürlük",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            color = IosWhite
                        )
                        Text(
                            text = "Sunucu bağlantı durumu: Aktif & Kararlı",
                            fontSize = 11.sp,
                            color = IosDusty
                        )
                    }

                    Icon(
                        imageVector = Icons.Default.ChevronRight,
                        contentDescription = null,
                        tint = IosDusty,
                        modifier = Modifier.size(18.dp)
                    )
                }
            }
        }
    }
}

@Composable
fun LiveTvTabContent(
    viewModel: IptvViewModel,
    filteredChannels: List<IptvChannel>,
    categories: List<String>,
    selectedCategory: String,
    searchQuery: String,
    loadingChannels: Boolean,
    channelsError: String?,
    currentChannel: IptvChannel?,
    onSelectChannel: (IptvChannel) -> Unit
) {
    var categoryDropdownExpanded by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier.fillMaxSize()
    ) {
        // Center-aligned category capsule selector with down chevron, matching Screenshot 1
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            Box {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(20.dp))
                        .background(IosGrayBg)
                        .clickable { categoryDropdownExpanded = true }
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(
                        text = selectedCategory,
                        color = IosWhite,
                        fontWeight = FontWeight.Bold,
                        fontSize = 14.sp
                    )
                    Icon(
                        imageVector = Icons.Default.KeyboardArrowDown,
                        contentDescription = "Dropdown",
                        tint = IosDusty,
                        modifier = Modifier.size(16.dp)
                    )
                }

                DropdownMenu(
                    expanded = categoryDropdownExpanded,
                    onDismissRequest = { categoryDropdownExpanded = false },
                    modifier = Modifier.background(IosGrayBg)
                ) {
                    categories.forEach { category ->
                        DropdownMenuItem(
                            text = { Text(category, color = IosWhite, fontWeight = FontWeight.Bold, fontSize = 13.sp) },
                            onClick = {
                                viewModel.setSelectedCategory(category)
                                categoryDropdownExpanded = false
                            }
                        )
                    }
                }
            }
        }

        // Sleek Outline/Transparent Search field "Arayın" exactly like Screenshot 1
        OutlinedTextField(
            value = searchQuery,
            onValueChange = { viewModel.setSearchQuery(it) },
            placeholder = { Text("Arayın", color = IosDusty, fontSize = 14.sp) },
            leadingIcon = { Icon(Icons.Default.Search, contentDescription = null, tint = IosDusty) },
            trailingIcon = {
                if (searchQuery.isNotEmpty()) {
                    IconButton(onClick = { viewModel.setSearchQuery("") }) {
                        Icon(Icons.Default.Clear, contentDescription = "Temizle", tint = IosDusty)
                    }
                }
            },
            singleLine = true,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = Color.Transparent,
                unfocusedBorderColor = Color.Transparent,
                focusedTextColor = IosWhite,
                unfocusedTextColor = IosWhite,
                focusedContainerColor = IosGrayBg,
                unfocusedContainerColor = IosGrayBg
            ),
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 6.dp)
                .testTag("search_channels_input")
        )

        // Time Header Row for EPG Timeline: "Bugün", "17:00", "17:30"
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = "Bugün",
                fontSize = 18.sp,
                fontWeight = FontWeight.Black,
                color = IosWhite
            )

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    text = "17:00",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = IosDusty
                )
                Icon(
                    imageVector = Icons.Default.ArrowDropDown,
                    contentDescription = null,
                    tint = IosDusty,
                    modifier = Modifier.size(16.dp)
                )
            }

            Text(
                text = "17:30",
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                color = IosDusty
            )
        }

        // Live Channels list view state managers
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
        ) {
            if (loadingChannels) {
                Column(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    CircularProgressIndicator(color = IosTabSelected, modifier = Modifier.size(36.dp))
                    Spacer(Modifier.height(8.dp))
                    Text("Bağlanılıyor...", color = IosWhite, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    Text("Kanal listesi derleniyor, bekleyin.", color = IosDusty, fontSize = 10.sp)
                }
            } else if (channelsError != null) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Icon(Icons.Default.WifiOff, contentDescription = null, tint = IosRedAccent, modifier = Modifier.size(48.dp))
                    Text(text = channelsError, color = IosWhite, fontSize = 12.sp, textAlign = TextAlign.Center)
                    Button(
                        onClick = { viewModel.playlists.value.firstOrNull()?.let { viewModel.selectPlaylist(it) } },
                        colors = ButtonDefaults.buttonColors(containerColor = IosTabSelected),
                        shape = RoundedCornerShape(8.dp)
                    ) {
                        Text("Yeniden Bağlan")
                    }
                }
            } else if (filteredChannels.isEmpty()) {
                Column(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Icon(Icons.Default.CompassCalibration, contentDescription = null, tint = IosDusty, modifier = Modifier.size(44.dp))
                    Spacer(Modifier.height(8.dp))
                    Text("Gösterilecek veri kaydı mevcut değil.", color = IosWhite, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    Text("Arama teriminizi düzenleyin.", color = IosDusty, fontSize = 10.sp)
                }
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(bottom = 120.dp, top = 2.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    items(filteredChannels) { channel ->
                        val isPlayingNow = currentChannel?.streamUrl == channel.streamUrl
                        DionEpgRow(
                            channel = channel,
                            isPlayingNow = isPlayingNow,
                            viewModel = viewModel,
                            onClick = { onSelectChannel(channel) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun FavoritesTabContent(
    viewModel: IptvViewModel,
    favorites: List<com.example.data.model.IptvFavorite>,
    filteredChannels: List<IptvChannel>,
    onSelectChannel: (IptvChannel) -> Unit
) {
    Column(
        modifier = Modifier.fillMaxSize()
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
        ) {
            Text(
                "Sık İzlenenler & Favoriler",
                fontSize = 18.sp,
                fontWeight = FontWeight.Black,
                color = IosWhite
            )
        }

        if (favorites.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .padding(24.dp),
                contentAlignment = Alignment.Center
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Favorite,
                        contentDescription = null,
                        tint = IosRedAccent.copy(alpha = 0.3f),
                        modifier = Modifier.size(64.dp)
                    )
                    Text(
                        "Favorileriniz Bomboş",
                        color = IosWhite,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Bold
                    )
                    Text(
                        "Uygulamadaki herhangi bir canlı kanalı kalp simgesine basarak bu sayfaya sık kullanılan olarak sabitleyebilirsiniz.",
                        color = IosDusty,
                        fontSize = 11.sp,
                        textAlign = TextAlign.Center,
                        lineHeight = 16.sp,
                        modifier = Modifier.padding(horizontal = 24.dp)
                    )
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = 120.dp, top = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(favorites) { fav ->
                    val matchingChannel = filteredChannels.firstOrNull { it.streamUrl == fav.streamUrl }
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp)
                            .clickable {
                                matchingChannel?.let { onSelectChannel(it) } ?: onSelectChannel(
                                    IptvChannel(
                                        playlistId = fav.playlistId,
                                        name = fav.name,
                                        streamUrl = fav.streamUrl,
                                        logoUrl = fav.logoUrl,
                                        category = fav.category,
                                        isFavorite = true
                                    )
                                )
                            },
                        colors = CardDefaults.cardColors(containerColor = IosDarkBg),
                        shape = RoundedCornerShape(12.dp),
                        border = BorderStroke(1.dp, IosBorder)
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(10.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(50.dp, 40.dp)
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(IosDeepBlack),
                                contentAlignment = Alignment.Center
                            ) {
                                AsyncImage(
                                    model = fav.logoUrl.ifEmpty { null },
                                    contentDescription = null,
                                    fallback = painterResource(id = android.R.drawable.ic_menu_slideshow),
                                    modifier = Modifier.size(40.dp, 30.dp),
                                    contentScale = ContentScale.Crop
                                )
                            }

                            Spacer(Modifier.width(12.dp))

                            Column(
                                modifier = Modifier.weight(1f)
                            ) {
                                Text(
                                    fav.name,
                                    color = IosWhite,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 13.sp,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                                Text(
                                    fav.category,
                                    color = IosTabSelected,
                                    fontSize = 10.sp,
                                    modifier = Modifier.padding(top = 2.dp)
                                )
                            }

                            IconButton(
                                onClick = {
                                    val ch = matchingChannel ?: IptvChannel(
                                        playlistId = fav.playlistId,
                                        name = fav.name,
                                        streamUrl = fav.streamUrl,
                                        logoUrl = fav.logoUrl,
                                        category = fav.category,
                                        isFavorite = true
                                    )
                                    viewModel.toggleFavorite(ch)
                                }
                            ) {
                                Icon(Icons.Default.Delete, contentDescription = "Delete", tint = IosRedAccent)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun SettingsTabContent(
    viewModel: IptvViewModel,
    playlists: List<IptvPlaylist>,
    selectedPlaylist: IptvPlaylist?,
    onTriggerAdd: () -> Unit
) {
    val accountInfo by viewModel.accountInfo.collectAsStateWithLifecycle()
    val loadingAccountInfo by viewModel.loadingAccountInfo.collectAsStateWithLifecycle()

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 120.dp, start = 16.dp, end = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            Text(
                "Profil & Abonelik Ayarları",
                fontSize = 18.sp,
                fontWeight = FontWeight.Black,
                color = IosWhite,
                modifier = Modifier.padding(top = 8.dp)
            )
        }

        // Active Playlist Provider Info section
        item {
            Card(
                colors = CardDefaults.cardColors(containerColor = IosGrayBg),
                shape = RoundedCornerShape(16.dp),
                border = BorderStroke(1.dp, IosBorder)
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            "AKTİF BULUT SUNUCU",
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            color = IosTabSelected,
                            letterSpacing = 1.sp
                        )

                        Box(
                            modifier = Modifier
                                .background(IosGreenAccent.copy(alpha = 0.15f), RoundedCornerShape(4.dp))
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        ) {
                            Text("BAĞLI", color = IosGreenAccent, fontSize = 9.sp, fontWeight = FontWeight.Bold)
                        }
                    }

                    if (selectedPlaylist == null) {
                        Text("Aktif kaynak yüklemesi yapılmadı.", color = IosDusty, fontSize = 12.sp)
                    } else {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Icon(Icons.Default.Dns, contentDescription = null, tint = IosPinkAccent, modifier = Modifier.size(28.dp))
                            Column {
                                Text(selectedPlaylist.name, color = IosWhite, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                Text(
                                    text = if (selectedPlaylist.type == "m3u") "M3U Bağlantı Formatı" else "Xtream Codes Sunucu Entegrasyonu",
                                    color = IosDusty,
                                    fontSize = 11.sp
                                )
                            }
                        }

                        // Subscription parameters inside card
                        if (loadingAccountInfo) {
                            Box(modifier = Modifier.fillMaxWidth().height(40.dp), contentAlignment = Alignment.Center) {
                                CircularProgressIndicator(color = IosTabSelected, modifier = Modifier.size(20.dp))
                            }
                        } else {
                            accountInfo?.let { info ->
                                HorizontalDivider(color = IosBorder, thickness = 1.dp)

                                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                    Text("Abonelik Durumu", color = IosDusty, fontSize = 11.sp)
                                    Text(info.status, color = IosGreenAccent, fontWeight = FontWeight.Bold, fontSize = 11.sp)
                                }
                                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                    Text("Bitiş Tarihi", color = IosDusty, fontSize = 11.sp)
                                    Text(info.expiryDate, color = IosWhite, fontWeight = FontWeight.Bold, fontSize = 11.sp)
                                }
                                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                    Text("Kanal Sayısı", color = IosDusty, fontSize = 11.sp)
                                    Text("${info.liveChannelsCount} TV / Canlı", color = IosWhite, fontWeight = FontWeight.Bold, fontSize = 11.sp)
                                }
                                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                    Text("Dizi / Film", color = IosDusty, fontSize = 11.sp)
                                    Text("${info.moviesCount} VOD Film", color = IosWhite, fontWeight = FontWeight.Bold, fontSize = 11.sp)
                                }
                            }
                        }
                    }
                }
            }
        }

        // Playlists list manager item
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    "Oynatılan Bağlantılarım",
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Bold,
                    color = IosWhite
                )

                Text(
                    "Profil Ekle",
                    fontSize = 12.sp,
                    color = IosTabSelected,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.clickable { onTriggerAdd() }
                )
            }
        }

        items(playlists) { item ->
            val isSelected = selectedPlaylist?.id == item.id
            Card(
                colors = CardDefaults.cardColors(containerColor = if (isSelected) IosDarkBg else IosGrayBg),
                shape = RoundedCornerShape(14.dp),
                border = BorderStroke(1.dp, if (isSelected) IosTabSelected else IosBorder)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        modifier = Modifier.weight(1f).clickable { viewModel.selectPlaylist(item) },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(34.dp)
                                .clip(CircleShape)
                                .background(if (isSelected) IosTabSelected.copy(alpha = 0.15f) else IosBorder),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = if (item.type == "m3u") Icons.Default.Link else Icons.Default.PowerSettingsNew,
                                contentDescription = null,
                                tint = if (isSelected) IosTabSelected else IosWhite,
                                modifier = Modifier.size(16.dp)
                            )
                        }

                        Column {
                            Text(item.name, color = IosWhite, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                            Text(if (item.type == "m3u") "M3U Linki" else "Xtream API Server", color = IosDusty, fontSize = 10.sp)
                        }
                    }

                    IconButton(
                        onClick = { viewModel.deletePlaylist(item) },
                        modifier = Modifier.size(36.dp)
                    ) {
                        Icon(imageVector = Icons.Default.Delete, contentDescription = "Sil", tint = IosRedAccent)
                    }
                }
            }
        }

        // Dion Engine diagnostic specifications
        item {
            Card(
                colors = CardDefaults.cardColors(containerColor = IosGrayBg),
                shape = RoundedCornerShape(14.dp),
                border = BorderStroke(1.dp, IosBorder)
            ) {
                Column(
                    modifier = Modifier.padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text("KODEK & MOTOR TEKNOLOJİSİ", color = IosGoldAccent, fontWeight = FontWeight.Bold, fontSize = 9.sp, letterSpacing = 1.sp)
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text("Çekirdek Altyapı", color = IosDusty, fontSize = 11.sp)
                        Text("iOS Hybrid Core v3", color = IosWhite, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text("Hafıza Kullanımı", color = IosDusty, fontSize = 11.sp)
                        Text("Ultra-light Fast (Sıfır Donma)", color = IosGreenAccent, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text("Ses Çıkış Entegrasyonu", color = IosDusty, fontSize = 11.sp)
                        Text("Dolby Digital Atmos 3D Surround", color = IosWhite, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}

@Composable
fun MiniPlayerDocked(
    playing: IptvChannel,
    isPlaying: Boolean,
    exoPlayer: ExoPlayer,
    onTogglePlay: () -> Unit,
    onClose: () -> Unit,
    onRestore: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp)
            .clickable { onRestore() },
        colors = CardDefaults.cardColors(containerColor = Color(0xF2121216)), // Translucent deep card content
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.08f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 16.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Live video thumbnail view
            Box(
                modifier = Modifier
                    .size(64.dp, 40.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(IosDeepBlack)
            ) {
                VideoPlayer(
                    exoPlayer = exoPlayer,
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM,
                    isActive = true,
                    modifier = Modifier.fillMaxSize()
                )
            }

            Spacer(Modifier.width(10.dp))

            Column(
                modifier = Modifier.weight(1f)
            ) {
                Text(
                    text = playing.name,
                    fontWeight = FontWeight.Bold,
                    color = IosWhite,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    text = "Dion Canlı Oynatıcı",
                    color = IosTabSelected,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }

            Row {
                IconButton(
                    onClick = onTogglePlay,
                    modifier = Modifier.size(40.dp)
                ) {
                    Icon(
                        imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                        contentDescription = "Oynat",
                        tint = IosWhite,
                        modifier = Modifier.size(20.dp)
                    )
                }

                IconButton(
                    onClick = onClose,
                    modifier = Modifier.size(40.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Kapat",
                        tint = IosDusty,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
        }
    }
}

@Composable
fun GlassyBottomBar(
    currentTab: Tab,
    onTabSelect: (Tab) -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .windowInsetsPadding(WindowInsets.navigationBars)
            .padding(horizontal = 24.dp, vertical = 12.dp)
            .clip(RoundedCornerShape(32.dp))
            .background(Color(0xE6121216)) // Glassmorphic frosted container
            .border(
                1.dp,
                Brush.verticalGradient(
                    colors = listOf(Color.White.copy(alpha = 0.12f), Color.White.copy(alpha = 0.02f))
                ),
                RoundedCornerShape(32.dp)
            )
            .padding(vertical = 10.dp, horizontal = 12.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceAround,
            verticalAlignment = Alignment.CenterVertically
        ) {
            GlassTabItem(
                label = "Keşfet",
                icon = Icons.Default.Home,
                selected = currentTab == Tab.Discover,
                onClick = { onTabSelect(Tab.Discover) }
            )

            GlassTabItem(
                label = "Canlı TV",
                icon = Icons.Default.Tv,
                selected = currentTab == Tab.LiveTv,
                onClick = { onTabSelect(Tab.LiveTv) }
            )

            GlassTabItem(
                label = "Favoriler",
                icon = Icons.Default.Favorite,
                selected = currentTab == Tab.Favorites,
                onClick = { onTabSelect(Tab.Favorites) }
            )

            GlassTabItem(
                label = "Hesap",
                icon = Icons.Default.Settings,
                selected = currentTab == Tab.Settings,
                onClick = { onTabSelect(Tab.Settings) }
            )
        }
    }
}

@Composable
fun GlassTabItem(
    label: String,
    icon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit
) {
    val scaleVal by animateFloatAsState(if (selected) 1.2f else 1.0f)

    Column(
        modifier = Modifier
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick
            ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = if (selected) IosTabSelected else IosDusty,
            modifier = Modifier
                .size(20.dp)
                .scale(scaleVal)
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = label,
            color = if (selected) IosWhite else IosDusty,
            fontSize = 9.sp,
            fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium
        )
    }
}

@OptIn(UnstableApi::class)
@Composable
fun FullScreenPlayerOverlay(
    playing: IptvChannel,
    isLandscape: Boolean,
    exoPlayer: ExoPlayer,
    isPlayerPlaying: Boolean,
    currentResolution: String,
    currentFps: String,
    currentBitrate: String,
    playerErrorMsg: String?,
    showPlayerControls: Boolean,
    showPlayerChannelList: Boolean,
    selectedResizeMode: Int,
    filteredChannels: List<IptvChannel>,
    categories: List<String>,
    selectedCategory: String,
    viewModel: IptvViewModel,
    onTogglePlay: () -> Unit,
    onToggleResize: () -> Unit,
    onToggleFav: () -> Unit,
    onRefresh: () -> Unit,
    onToggleControls: () -> Unit,
    onMinimize: () -> Unit,
    onClose: () -> Unit,
    onToggleChannelList: () -> Unit,
    onSelectChannelFromList: (IptvChannel) -> Unit,
    onSelectCategoryFromList: (String) -> Unit
) {
    var categoryDropdownExpanded by remember { mutableStateOf(false) }
    var searchQuery by remember { mutableStateOf("") }
    val displayChannels = remember(filteredChannels, searchQuery) {
        if (searchQuery.isEmpty()) filteredChannels else filteredChannels.filter { it.name.contains(searchQuery, ignoreCase = true) }
    }

    if (isLandscape) {
        // LANDSCAPE MODE: Full screen video with premium custom overlays (Screenshot 3)
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black)
        ) {
            VideoPlayer(
                exoPlayer = exoPlayer,
                resizeMode = selectedResizeMode,
                isActive = true,
                modifier = Modifier
                    .fillMaxSize()
                    .clickable { onToggleControls() }
            )

            // Backdrop tint to cover video when controls are showing
            AnimatedVisibility(
                visible = showPlayerControls,
                enter = fadeIn(),
                exit = fadeOut()
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.5f))
                )
            }

            // Overlay Interactive Controls UI
            AnimatedVisibility(
                visible = showPlayerControls,
                enter = fadeIn() + slideInVertically(initialOffsetY = { -it }),
                exit = fadeOut() + slideOutVertically(targetOffsetY = { -it }),
                modifier = Modifier.align(Alignment.TopCenter)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .windowInsetsPadding(WindowInsets.safeDrawing)
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    // Top-Left Cluster: Close "X", Resize Aspect Ratio button, PiP icon
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        IconButton(
                            onClick = onClose,
                            modifier = Modifier
                                .size(38.dp)
                                .clip(CircleShape)
                                .background(Color.White.copy(alpha = 0.12f))
                        ) {
                            Icon(Icons.Default.Close, contentDescription = "Kapat", tint = IosWhite, modifier = Modifier.size(18.dp))
                        }

                        IconButton(
                            onClick = onToggleResize,
                            modifier = Modifier
                                .size(38.dp)
                                .clip(CircleShape)
                                .background(Color.White.copy(alpha = 0.12f))
                        ) {
                            Icon(Icons.Default.AspectRatio, contentDescription = "Boyut", tint = IosWhite, modifier = Modifier.size(18.dp))
                        }

                        IconButton(
                            onClick = onMinimize,
                            modifier = Modifier
                                .size(38.dp)
                                .clip(CircleShape)
                                .background(Color.White.copy(alpha = 0.12f))
                        ) {
                            Icon(Icons.Default.PictureInPicture, contentDescription = "PiP", tint = IosWhite, modifier = Modifier.size(18.dp))
                        }
                    }

                    // Top-Right Cluster: Volume Control Pill
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        // Slider volume visual representation
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(20.dp))
                                .background(Color.Black.copy(alpha = 0.6f))
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(Icons.Default.VolumeUp, contentDescription = "Ses", tint = IosWhite, modifier = Modifier.size(14.dp))
                            Box(
                                modifier = Modifier
                                    .width(60.dp)
                                    .height(4.dp)
                                    .clip(RoundedCornerShape(2.dp))
                                    .background(IosWhite.copy(alpha = 0.3f))
                            ) {
                                Box(
                                    modifier = Modifier
                                        .fillMaxHeight()
                                        .fillMaxWidth(0.75f) // 75% default volume
                                        .background(IosWhite)
                                )
                            }
                        }
                    }
                }
            }

            // Circular Pause/Play Center Button
            AnimatedVisibility(
                visible = showPlayerControls,
                enter = fadeIn(),
                exit = fadeOut(),
                modifier = Modifier.align(Alignment.Center)
            ) {
                FloatingActionButton(
                    onClick = onTogglePlay,
                    containerColor = Color.Black.copy(alpha = 0.6f),
                    contentColor = IosWhite,
                    modifier = Modifier
                        .size(68.dp)
                        .border(1.dp, IosWhite.copy(alpha = 0.1f), CircleShape),
                    shape = CircleShape
                ) {
                    Icon(
                        imageVector = if (isPlayerPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                        contentDescription = "Oynat",
                        modifier = Modifier.size(36.dp)
                    )
                }
            }

            // Bottom controls overlay in Landscape (Screenshot 3)
            AnimatedVisibility(
                visible = showPlayerControls,
                enter = fadeIn() + slideInVertically(initialOffsetY = { it }),
                exit = fadeOut() + slideOutVertically(targetOffsetY = { it }),
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(WindowInsets.navigationBars)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    val activeProg = remember(playing) { viewModel.getChannelActiveProgram(playing) }
                    val progs = remember(playing) { viewModel.getChannelPrograms(playing) }
                    val activeIdx = progs.indexOfFirst { it.title == activeProg.title }
                    val nextProg = if (activeIdx != -1 && activeIdx < progs.size - 1) progs[activeIdx + 1] else null

                    // Left-align TV title: ● CANLI  NOW TV - Sen Çal Kapımı of Screenshot 3
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .clip(CircleShape)
                                .background(IosRedAccent)
                        )
                        Text(
                            text = "CANLI",
                            color = IosRedAccent,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Black
                        )
                        Text(
                            text = "${playing.name} - ${activeProg.title}",
                            color = IosWhite,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }

                    // Minimal progress bar overlay representing actual movie/show elapsed playback duration
                    val now = System.currentTimeMillis() / 1000
                    var progress = 0.35f
                    if (activeProg.startTimestamp > 0 && activeProg.endTimestamp > activeProg.startTimestamp) {
                        progress = ((now - activeProg.startTimestamp).toFloat() / 
                                   (activeProg.endTimestamp - activeProg.startTimestamp).toFloat())
                                   .coerceIn(0f, 1f)
                    }
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(4.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(IosWhite.copy(alpha = 0.2f))
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxHeight()
                                .fillMaxWidth(progress)
                                .background(IosWhite)
                        )
                    }

                    // Bottom info label row: "Şimdi..." and "Sonraki..." aligned beautifully
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column {
                            Text(
                                "ŞİMDİ OYNATILIYOR",
                                fontSize = 8.sp,
                                fontWeight = FontWeight.Bold,
                                color = IosDusty
                            )
                            Text(
                                activeProg.title,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                color = IosWhite,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }

                        Row(
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            nextProg?.let {
                                Column(horizontalAlignment = Alignment.End) {
                                    Text(
                                        "SIRADAKII PROGRAM",
                                        fontSize = 8.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = IosDusty
                                    )
                                    Text(
                                        "${it.startStr} - ${it.title}",
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = IosWhite.copy(alpha = 0.8f),
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }
                            }

                            // Far Right Settings cluster
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                // Settings Gear wheel
                                IconButton(onClick = { /* Settings wheel */ }) {
                                    Icon(Icons.Default.Settings, contentDescription = "Kalite", tint = IosWhite)
                                }
                                // Cast icon
                                IconButton(onClick = { /* Cast play */ }) {
                                    Icon(Icons.Default.Cast, contentDescription = "Cast", tint = IosWhite)
                                }
                                // Bookmark / favorite
                                IconButton(onClick = onToggleFav) {
                                    Icon(
                                        imageVector = if (playing.isFavorite) Icons.Default.Favorite else Icons.Outlined.FavoriteBorder,
                                        contentDescription = "Favori",
                                        tint = if (playing.isFavorite) IosRedAccent else IosWhite
                                    )
                                }
                                // Quick channel sidebar drawer indicator
                                IconButton(onClick = onToggleChannelList) {
                                    Icon(Icons.Default.FormatListBulleted, contentDescription = "Drawer", tint = IosWhite)
                                }
                            }
                        }
                    }
                }
            }

            // Quick Sidebar Sliding channels drawer inside full screen overlay
            AnimatedVisibility(
                visible = showPlayerChannelList,
                enter = slideInHorizontally(initialOffsetX = { it }),
                exit = slideOutHorizontally(targetOffsetX = { it }),
                modifier = Modifier
                    .align(Alignment.CenterEnd)
                    .fillMaxHeight()
                    .fillMaxWidth(0.35f)
                    .background(Color(0xE608080C))
                    .border(BorderStroke(1.dp, Color.White.copy(alpha = 0.08f)))
                    .windowInsetsPadding(WindowInsets.safeDrawing)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(12.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(Icons.Default.FormatListBulleted, contentDescription = null, tint = IosTabSelected, modifier = Modifier.size(16.dp))
                            Text("Hızlı Kanal Listesi", color = IosWhite, fontSize = 13.sp, fontWeight = FontWeight.Black)
                        }

                        IconButton(onClick = onToggleChannelList, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Default.Close, contentDescription = "Close", tint = IosDusty, modifier = Modifier.size(16.dp))
                        }
                    }

                    LazyRow(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        items(categories) { cat ->
                            val isSelectedCat = cat == selectedCategory
                            Box(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(if (isSelectedCat) IosTabSelected else Color.White.copy(alpha = 0.05f))
                                    .clickable { onSelectCategoryFromList(cat) }
                                    .padding(horizontal = 8.dp, vertical = 6.dp)
                            ) {
                                Text(cat, color = IosWhite, fontSize = 9.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                    }

                    Spacer(Modifier.height(4.dp))

                    LazyColumn(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        items(displayChannels) { item ->
                            val isThisActive = item.streamUrl == playing.streamUrl
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(if (isThisActive) IosTabSelected.copy(alpha = 0.15f) else Color.Transparent)
                                    .border(1.dp, if (isThisActive) IosTabSelected.copy(alpha = 0.4f) else Color.Transparent, RoundedCornerShape(10.dp))
                                    .clickable { onSelectChannelFromList(item) }
                                    .padding(6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                AsyncImage(
                                    model = item.logoUrl.ifEmpty { null },
                                    contentDescription = null,
                                    fallback = painterResource(id = android.R.drawable.ic_menu_slideshow),
                                    modifier = Modifier
                                        .size(34.dp, 28.dp)
                                        .clip(RoundedCornerShape(4.dp))
                                )

                                Spacer(Modifier.width(8.dp))

                                Column(modifier = Modifier.weight(1f)) {
                                    Text(item.name, color = IosWhite, fontSize = 11.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(item.category, color = IosDusty, fontSize = 8.sp, maxLines = 1)
                                }
                            }
                        }
                    }
                }
            }
        }
    } else {
        // PORTRAIT MODE: Interactive split-screen player container with fully list of channels below (Screenshot 2)
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(IosDeepBlack)
        ) {
            val activeProg = remember(playing) { viewModel.getChannelActiveProgram(playing) }

            // TOP 1/3 PORTION: Unified Video Player Container
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(230.dp)
                    .background(Color.Black)
            ) {
                VideoPlayer(
                    exoPlayer = exoPlayer,
                    resizeMode = selectedResizeMode,
                    isActive = true,
                    modifier = Modifier
                        .fillMaxSize()
                        .clickable { onToggleControls() }
                )

                // Shadow gradient block to protect top text contrast
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(
                            Brush.verticalGradient(
                                colors = listOf(Color.Black.copy(alpha = 0.6f), Color.Transparent, Color.Black.copy(alpha = 0.6f))
                            )
                        )
                )

                // Top Controls Layer: Back arrow, Title/Sub, Favorite/Bookmark heart icon
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(14.dp)
                        .align(Alignment.TopCenter),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    IconButton(
                        onClick = onMinimize,
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.4f))
                    ) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Kapat", tint = IosWhite)
                    }

                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.weight(1f)
                    ) {
                        Text(
                            text = playing.name,
                            fontWeight = FontWeight.Bold,
                            color = IosWhite,
                            fontSize = 13.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = activeProg.title,
                            color = IosTabSelected,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }

                    IconButton(
                        onClick = onToggleFav,
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.4f))
                    ) {
                        Icon(
                            imageVector = if (playing.isFavorite) Icons.Default.Favorite else Icons.Outlined.FavoriteBorder,
                            contentDescription = "Favorile",
                            tint = if (playing.isFavorite) IosRedAccent else IosWhite
                        )
                    }
                }

                // Top Left (under Back Button): PiP quick-minimize button
                IconButton(
                    onClick = onMinimize,
                    modifier = Modifier
                        .padding(top = 64.dp, start = 14.dp)
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(Color.Black.copy(alpha = 0.4f))
                        .align(Alignment.TopStart)
                ) {
                    Icon(Icons.Default.PictureInPicture, contentDescription = "PiP", tint = IosWhite, modifier = Modifier.size(16.dp))
                }

                // Center: Big Pause/Play circle button (Screenshot 2)
                Box(
                    modifier = Modifier
                        .size(54.dp)
                        .clip(CircleShape)
                        .background(Color.Black.copy(alpha = 0.5f))
                        .border(1.dp, IosWhite.copy(alpha = 0.1f), CircleShape)
                        .clickable { onTogglePlay() }
                        .align(Alignment.Center),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = if (isPlayerPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                        contentDescription = "Oynat",
                        tint = IosWhite,
                        modifier = Modifier.size(30.dp)
                    )
                }

                // Bottom strip: Minimalist seek bar progress slider, live status indicator, fullscreen button
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .align(Alignment.BottomCenter)
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    // Seekline
                    val now = System.currentTimeMillis() / 1000
                    var progress = 0.35f
                    if (activeProg.startTimestamp > 0 && activeProg.endTimestamp > activeProg.startTimestamp) {
                        progress = ((now - activeProg.startTimestamp).toFloat() / 
                                   (activeProg.endTimestamp - activeProg.startTimestamp).toFloat())
                                   .coerceIn(0f, 1f)
                    }
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(2.dp)
                            .background(IosWhite.copy(alpha = 0.25f))
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxHeight()
                                .fillMaxWidth(progress)
                                .background(IosWhite)
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(6.dp)
                                    .clip(CircleShape)
                                    .background(IosRedAccent)
                            )
                            Text(
                                text = "CANLI  ${playing.name}",
                                color = IosWhite,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold
                            )
                        }

                        // Resize toggle button triggers Landscape
                        IconButton(
                            onClick = onToggleResize,
                            modifier = Modifier.size(24.dp)
                        ) {
                            Icon(Icons.Default.Fullscreen, contentDescription = "Fullscreen", tint = IosWhite)
                        }
                    }
                }
            }

            // BOTTOM 2/3 PORTION: Interactive EPG channel grid browser for quick channel change (Screenshot 2)
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .background(IosDeepBlack)
            ) {
                // Category Capsule dropdown Selector
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center
                ) {
                    Box {
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(20.dp))
                                .background(IosGrayBg)
                                .clickable { categoryDropdownExpanded = true }
                                .padding(horizontal = 16.dp, vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Text(
                                text = selectedCategory,
                                color = IosWhite,
                                fontWeight = FontWeight.Bold,
                                fontSize = 13.sp
                            )
                            Icon(
                                imageVector = Icons.Default.KeyboardArrowDown,
                                contentDescription = "Dropdown",
                                tint = IosDusty,
                                modifier = Modifier.size(16.dp)
                            )
                        }

                        DropdownMenu(
                            expanded = categoryDropdownExpanded,
                            onDismissRequest = { categoryDropdownExpanded = false },
                            modifier = Modifier.background(IosGrayBg)
                        ) {
                            categories.forEach { category ->
                                DropdownMenuItem(
                                    text = { Text(category, color = IosWhite, fontWeight = FontWeight.Bold, fontSize = 13.sp) },
                                    onClick = {
                                        onSelectCategoryFromList(category)
                                        categoryDropdownExpanded = false
                                    }
                                )
                            }
                        }
                    }
                }

                // Clean transparent search block
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    placeholder = { Text("Arayın", color = IosDusty, fontSize = 14.sp) },
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null, tint = IosDusty) },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Color.Transparent,
                        unfocusedBorderColor = Color.Transparent,
                        focusedTextColor = IosWhite,
                        unfocusedTextColor = IosWhite,
                        focusedContainerColor = IosGrayBg,
                        unfocusedContainerColor = IosGrayBg
                    ),
                    shape = RoundedCornerShape(16.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 4.dp)
                )

                // Timeline headers
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("Bugün", fontSize = 16.sp, fontWeight = FontWeight.Black, color = IosWhite)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text("17:00", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = IosDusty)
                        Icon(Icons.Default.ArrowDropDown, contentDescription = null, tint = IosDusty, modifier = Modifier.size(16.dp))
                    }
                    Text("17:30", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = IosDusty)
                }

                // Scrollable lazy list of channels for split screen change channel instantly
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    contentPadding = PaddingValues(bottom = 24.dp)
                ) {
                    items(displayChannels) { item ->
                        val isThisActive = item.streamUrl == playing.streamUrl
                        DionEpgRow(
                            channel = item,
                            isPlayingNow = isThisActive,
                            viewModel = viewModel,
                            onClick = { onSelectChannelFromList(item) }
                        )
                    }
                }
            }
        }
    }
}

// ======================== MODIFIERS & UTILITIES ========================

// Advanced Dashed Border Modifier utilizing custom path drawing for professional Empty States
fun Modifier.dashedBorder(
    width: Dp = 1.dp,
    color: Color = Color.Gray,
    cornerRadius: Dp = 0.dp
) = this.drawWithContent {
    drawContent()
    val strokeWidth = width.toPx()
    val pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(
        floatArrayOf(10f, 10f), 0f
    )
    val rRadius = cornerRadius.toPx()

    drawRoundRect(
        color = color,
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(rRadius, rRadius),
        style = androidx.compose.ui.graphics.drawscope.Stroke(
            width = strokeWidth,
            pathEffect = pathEffect
        )
    )
}

// Global Premium Color mapping for Channel Logos according to Screenshot 1 and 2
fun getChannelColor(channelName: String): Color {
    val name = channelName.lowercase()
    return when {
        name.contains("trt 4k") || name.contains("trt4k") -> Color(0xFFD2B55B) // Pastel Gold-Yellow
        name.contains("trt 1") || name.contains("trt1") -> Color(0xFF9E2E3E) // Crimson Red
        name.contains("spor") -> Color(0xFF0D9488) // Vibrant Ocean Teal
        name.contains("tv8") || name.contains("tv 8") -> Color(0xFF8C5353) // Cocoa Pinkish Brown
        name.contains("fox") || name.contains("now") || name.contains("atv") -> Color(0xFFD96A23) // Pastel Orange
        name.contains("kanal d") || name.contains("kanald") -> Color(0xFF2E66B3) // Deep Sky Blue
        name.contains("show") -> Color(0xFF1EA87A) // Emerald Mint Green
        name.contains("star") -> Color(0xFF6B4EB3) // Soft Mystic Purple
        name.contains("24") -> Color(0xFFC7781F) // Amber Gold
        else -> {
            val colors = listOf(
                Color(0xFF2E66B3), Color(0xFF1EA87A), Color(0xFF6B4EB3),
                Color(0xFF9E2E3E), Color(0xFF0D9488), Color(0xFFD96A23),
                Color(0xFFC7781F), Color(0xFF8C5353)
            )
            colors[kotlin.math.abs(channelName.hashCode()) % colors.size]
        }
    }
}

// Global Premium Dark Color palette for EPG blocks according to Screenshot 1 and 2
fun getProgramColor(title: String, index: Int = 0): Color {
    val hash = kotlin.math.abs(title.hashCode() + index)
    val colors = listOf(
        Color(0xFF4C2F55), // Deep Dark Amethyst
        Color(0xFF2A4B3D), // Deep Pine Forest
        Color(0xFF4E2A2E), // Deep Cherry Maroon
        Color(0xFF2D4E5B), // Deep Slate Ocean
        Color(0xFF4C432F), // Deep Saturated Bronze
        Color(0xFF213D5E), // Deep Navy Sapphire
        Color(0xFF3B2D2F), // Deep Warm Charcoal
        Color(0xFF33333D)  // Glass Obsidian
    )
    return colors[hash % colors.size]
}

@Composable
fun DionEpgRow(
    channel: IptvChannel,
    isPlayingNow: Boolean,
    viewModel: IptvViewModel,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val activeProgram = remember(channel) { viewModel.getChannelActiveProgram(channel) }
    val programs = remember(channel) { viewModel.getChannelPrograms(channel) }
    
    val activeIndex = programs.indexOfFirst { it.title == activeProgram.title }
    val nextProgram = if (activeIndex != -1 && activeIndex < programs.size - 1) {
        programs[activeIndex + 1]
    } else {
        null
    }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Left Channel Logo Box (Clean Rounded Square, colorful background matching TRT, FOX, TV8 etc.)
        Box(
            modifier = Modifier
                .size(width = 64.dp, height = 60.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(getChannelColor(channel.name)),
            contentAlignment = Alignment.Center
        ) {
            AsyncImage(
                model = channel.logoUrl.ifEmpty { null },
                contentDescription = channel.name,
                fallback = painterResource(id = android.R.drawable.ic_menu_slideshow),
                error = painterResource(id = android.R.drawable.ic_menu_slideshow),
                modifier = Modifier
                    .size(44.dp, 36.dp)
                    .clip(RoundedCornerShape(8.dp)),
                contentScale = ContentScale.Fit
            )
        }

        Spacer(Modifier.width(12.dp))

        // Right side EPG blocks (Two cards side-by-side representing EPG timeline track)
        Row(
            modifier = Modifier.weight(1f),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            // Active Show Box (Takes 70% of available weight)
            val showColor = getProgramColor(activeProgram.title, 0)
            Box(
                modifier = Modifier
                    .weight(0.7f)
                    .height(60.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(showColor)
                    .border(
                        1.dp,
                        if (isPlayingNow) IosTabSelected else Color.White.copy(alpha = 0.05f),
                        RoundedCornerShape(16.dp)
                    )
                    .padding(horizontal = 12.dp, vertical = 8.dp)
            ) {
                // Elapsed proportional progress shading overlay (Visual progress slider inside card)
                val now = System.currentTimeMillis() / 1000
                if (activeProgram.startTimestamp > 0 && activeProgram.endTimestamp > activeProgram.startTimestamp) {
                    val progress = ((now - activeProgram.startTimestamp).toFloat() / 
                                   (activeProgram.endTimestamp - activeProgram.startTimestamp).toFloat())
                                   .coerceIn(0f, 1f)
                    Box(
                        modifier = Modifier
                            .fillMaxHeight()
                            .fillMaxWidth(progress)
                            .background(Color.White.copy(alpha = 0.12f))
                            .align(Alignment.CenterStart)
                    )
                }

                Column(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp)
                    ) {
                        Text(
                            text = channel.name,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Black,
                            color = IosWhite.copy(alpha = 0.6f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        
                        // Small resolution badge to replace complex settings
                        Box(
                            modifier = Modifier
                                .background(IosWhite.copy(alpha = 0.15f), RoundedCornerShape(3.dp))
                                .padding(horizontal = 4.dp, vertical = 1.dp)
                        ) {
                            Text(
                                "4K",
                                fontSize = 7.sp,
                                fontWeight = FontWeight.Bold,
                                color = IosWhite
                            )
                        }

                        Text(
                            text = activeProgram.startStr,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            color = IosWhite.copy(alpha = 0.5f)
                        )
                    }

                    Spacer(Modifier.height(2.dp))

                    Text(
                        text = activeProgram.title,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Black,
                        color = IosWhite,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }

            // Next Show Box (Takes 30% of available weight - represents remaining upcoming track)
            val nextColor = getProgramColor(nextProgram?.title ?: "Dion Sonraki", 1)
            Box(
                modifier = Modifier
                    .weight(0.3f)
                    .height(60.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(nextColor.copy(alpha = 0.7f))
                    .padding(horizontal = 8.dp, vertical = 8.dp),
                contentAlignment = Alignment.CenterStart
            ) {
                Column(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center
                ) {
                    Text(
                        text = nextProgram?.startStr ?: "17:30",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Black,
                        color = IosWhite.copy(alpha = 0.5f)
                    )
                    
                    Spacer(Modifier.height(2.dp))

                    Text(
                        text = nextProgram?.title ?: "Yayın Akışı",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = IosWhite.copy(alpha = 0.7f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}

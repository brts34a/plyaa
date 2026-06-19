package com.example.ui.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.data.database.AppDatabase
import com.example.data.model.IptvChannel
import com.example.data.model.IptvFavorite
import com.example.data.model.IptvPlaylist
import com.example.data.model.EpgProgram
import com.example.data.model.IptvAccountInfo
import com.example.data.parser.M3uParser
import com.example.data.parser.XtreamClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.ByteArrayInputStream

class IptvViewModel(application: Application) : AndroidViewModel(application) {
    private val db = AppDatabase.getDatabase(application)
    private val playlistDao = db.playlistDao()
    private val favoriteDao = db.favoriteDao()
    private val httpClient = OkHttpClient()

    // Playlists from DB
    val playlists: StateFlow<List<IptvPlaylist>> = playlistDao.getAllPlaylists()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    // Favorites from DB
    val favorites: StateFlow<List<IptvFavorite>> = favoriteDao.getAllFavorites()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    // UI state for Loading channels
    private val _loadingChannels = MutableStateFlow(false)
    val loadingChannels = _loadingChannels.asStateFlow()

    private val _channelsError = MutableStateFlow<String?>(null)
    val channelsError = _channelsError.asStateFlow()

    // Loaded channels for currently selected playlist
    private val _loadedChannels = MutableStateFlow<List<IptvChannel>>(emptyList())
    
    // Active playlist selection
    private val _selectedPlaylist = MutableStateFlow<IptvPlaylist?>(null)
    val selectedPlaylist = _selectedPlaylist.asStateFlow()

    // Filter controls
    private val _searchQuery = MutableStateFlow("")
    val searchQuery = _searchQuery.asStateFlow()

    private val _selectedCategory = MutableStateFlow("Tümü")
    val selectedCategory = _selectedCategory.asStateFlow()

    // Computed categories for the currently loaded list
    private val _categories = MutableStateFlow<List<String>>(listOf("Tümü", "Favorilerim"))
    val categories = _categories.asStateFlow()

    // Currently playing channel
    private val _currentChannel = MutableStateFlow<IptvChannel?>(null)
    val currentChannel = _currentChannel.asStateFlow()

    // EPG list for currently playing channel
    private val _currentChannelEpg = MutableStateFlow<List<EpgProgram>>(emptyList())
    val currentChannelEpg = _currentChannelEpg.asStateFlow()

    private val _loadingEpg = MutableStateFlow(false)
    val loadingEpg = _loadingEpg.asStateFlow()

    // On-demand channel EPG cache map
    private val _channelsActiveEpg = MutableStateFlow<Map<String, EpgProgram>>(emptyMap())
    val channelsActiveEpg = _channelsActiveEpg.asStateFlow()

    // Tracking currently fetching stream URLs
    private val fetchingStreamUrls = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    private val _accountInfo = MutableStateFlow<IptvAccountInfo?>(null)
    val accountInfo = _accountInfo.asStateFlow()

    private val _loadingAccountInfo = MutableStateFlow(false)
    val loadingAccountInfo = _loadingAccountInfo.asStateFlow()

    // Combined filtered channel list based on search, category and favorites
    val filteredChannels: StateFlow<List<IptvChannel>> = combine(
        _loadedChannels,
        _searchQuery,
        _selectedCategory,
        favorites
    ) { channels, query, category, favList ->
        // Map channels to include their correct isFavorite status
        val mappedChannels = channels.map { channel ->
            channel.copy(isFavorite = favList.any { it.playlistId == channel.playlistId && it.streamUrl == channel.streamUrl })
        }

        // Apply filters
        var result = mappedChannels

        if (category == "Favoriler" || category == "Favorilerim") {
            result = result.filter { it.isFavorite }
        } else if (category != "Tümü") {
            result = result.filter { it.category == category }
        }

        if (query.isNotEmpty()) {
            result = result.filter { it.name.contains(query, ignoreCase = true) }
        }

        result
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    init {
        // Automatically load first playlist if exists
        viewModelScope.launch {
            playlists.collect { list ->
                if (list.isNotEmpty() && _selectedPlaylist.value == null) {
                    selectPlaylist(list.first())
                }
            }
        }
    }

    fun selectPlaylist(playlist: IptvPlaylist) {
        _selectedPlaylist.value = playlist
        _currentChannel.value = null
        _channelsActiveEpg.value = emptyMap()
        fetchingStreamUrls.clear()
        loadChannelsForPlaylist(playlist)
    }

    private fun loadChannelsForPlaylist(playlist: IptvPlaylist) {
        viewModelScope.launch {
            _loadingChannels.value = true
            _channelsError.value = null
            _loadedChannels.value = emptyList()
            _selectedCategory.value = "Tümü"
            _accountInfo.value = null // Reset account info on playlist change

            try {
                val channels = if (playlist.type == "m3u") {
                    fetchM3uPlaylists(playlist.url, playlist.id)
                } else {
                    XtreamClient.fetchChannels(playlist)
                }

                if (channels.isEmpty()) {
                    _channelsError.value = "Kanal listesi boş veya yüklenemedi. Bilgileri ve internet bağlantınızı kontrol ediniz."
                } else {
                    _loadedChannels.value = channels
                    
                    // Extract unique categories
                    val uniqueCategories = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
                        channels.map { it.category }.distinct().sorted()
                    }
                    _categories.value = listOf("Tümü", "Favorilerim") + uniqueCategories
                    
                    // Load account subscription info
                    loadAccountInfo(playlist)
                }
            } catch (e: Exception) {
                _channelsError.value = "Hata oluştu: ${e.localizedMessage}"
            } finally {
                _loadingChannels.value = false
            }
        }
    }

    private suspend fun fetchM3uPlaylists(url: String, playlistId: Int): List<IptvChannel> = withContext(Dispatchers.IO) {
        try {
            val request = Request.Builder().url(url).build()
            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@withContext emptyList()
                val bodyBytes = response.body?.bytes() ?: return@withContext emptyList()
                val byteStream = ByteArrayInputStream(bodyBytes)
                return@withContext M3uParser.parse(byteStream, playlistId)
            }
        } catch (e: Exception) {
            e.printStackTrace()
            emptyList()
        }
    }

    fun addPlaylist(name: String, type: String, url: String, username: String = "", password: String = "", onSuccess: () -> Unit, onError: (String) -> Unit) {
        viewModelScope.launch {
            _loadingChannels.value = true
            try {
                val newPlaylist = IptvPlaylist(
                    name = name,
                    type = type,
                    url = url,
                    username = username,
                    password = password
                )

                if (type == "xtream") {
                    // Test credentials
                    val works = XtreamClient.testCredentials(newPlaylist)
                    if (!works) {
                        onError("Xtream servisine bağlanılamadı. Bilgilerinizi kontrol edin.")
                        _loadingChannels.value = false
                        return@launch
                    }
                }

                val rowId = playlistDao.insertPlaylist(newPlaylist)
                val playlistWithId = newPlaylist.copy(id = rowId.toInt())
                selectPlaylist(playlistWithId)
                onSuccess()
            } catch (e: Exception) {
                onError("Hata: ${e.localizedMessage}")
            } finally {
                _loadingChannels.value = false
            }
        }
    }

    fun deletePlaylist(playlist: IptvPlaylist) {
        viewModelScope.launch {
            playlistDao.deletePlaylist(playlist)
            if (_selectedPlaylist.value?.id == playlist.id) {
                _selectedPlaylist.value = null
                _loadedChannels.value = emptyList()
                _currentChannel.value = null
            }
        }
    }

    fun toggleFavorite(channel: IptvChannel) {
        viewModelScope.launch {
            val isFav = favoriteDao.isFavorite(channel.playlistId, channel.streamUrl)
            if (isFav) {
                favoriteDao.deleteFavorite(channel.playlistId, channel.streamUrl)
            } else {
                val fav = IptvFavorite(
                    playlistId = channel.playlistId,
                    name = channel.name,
                    streamUrl = channel.streamUrl,
                    logoUrl = channel.logoUrl,
                    category = channel.category
                )
                favoriteDao.insertFavorite(fav)
            }
            // Trigger dynamic update on Combining flows by updating list state reference slightly or simply retriggering
            val oldList = _loadedChannels.value
            _loadedChannels.value = emptyList()
            _loadedChannels.value = oldList
        }
    }

    fun selectChannel(channel: IptvChannel?) {
        _currentChannel.value = channel
        if (channel != null) {
            loadEpgForChannel(channel, _selectedPlaylist.value)
        }
    }

    fun playNextChannel() {
        val currentList = filteredChannels.value
        val currentIndex = currentList.indexOfFirst { it.streamUrl == _currentChannel.value?.streamUrl }
        if (currentIndex != -1 && currentIndex < currentList.size - 1) {
            val nextChannel = currentList[currentIndex + 1]
            _currentChannel.value = nextChannel
            loadEpgForChannel(nextChannel, _selectedPlaylist.value)
        }
    }

    fun playPreviousChannel() {
        val currentList = filteredChannels.value
        val currentIndex = currentList.indexOfFirst { it.streamUrl == _currentChannel.value?.streamUrl }
        if (currentIndex > 0) {
            val prevChannel = currentList[currentIndex - 1]
            _currentChannel.value = prevChannel
            loadEpgForChannel(prevChannel, _selectedPlaylist.value)
        }
    }

    fun loadEpgForChannel(channel: IptvChannel, playlist: IptvPlaylist?) {
        _currentChannelEpg.value = generateSimulatedEpg(channel)
        _loadingEpg.value = false
    }

    private fun generateSimulatedEpg(channel: IptvChannel): List<EpgProgram> {
        val now = System.currentTimeMillis() / 1000
        val oneHour = 3600
        val list = mutableListOf<EpgProgram>()

        val isTr = channel.category.lowercase().contains("tr") || 
                   channel.category.lowercase().contains("türk") || 
                   channel.category.lowercase().contains("ulusal") || 
                   channel.name.lowercase().contains("trt") || 
                   channel.name.lowercase().contains("tv") ||
                   channel.name.lowercase().contains("atv") ||
                   channel.name.lowercase().contains("show") ||
                   channel.name.lowercase().contains("kanal") ||
                   channel.name.lowercase().contains("star")

        val zoneId = if (isTr) java.util.TimeZone.getTimeZone("Europe/Istanbul") else java.util.TimeZone.getDefault()
        val calendar = java.util.Calendar.getInstance(zoneId)
        val currentHour = calendar.get(java.util.Calendar.HOUR_OF_DAY)
        val baseHour = (currentHour / 2) * 2

        calendar.set(java.util.Calendar.MINUTE, 0)
        calendar.set(java.util.Calendar.SECOND, 0)

        val formatterTime = java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
        formatterTime.timeZone = zoneId

        for (i in -1..6) { // extended list range
            val showCal = calendar.clone() as java.util.Calendar
            showCal.set(java.util.Calendar.HOUR_OF_DAY, baseHour)
            showCal.add(java.util.Calendar.HOUR_OF_DAY, i * 2)

            val startTs = showCal.timeInMillis / 1000
            val endTs = startTs + 2 * oneHour

            val startStr = formatterTime.format(showCal.time)
            showCal.add(java.util.Calendar.HOUR_OF_DAY, 2)
            val endStr = formatterTime.format(showCal.time)

            val offsetHour = baseHour + i * 2
            val normalizedHour = ((offsetHour % 24) + 24) % 24

            val showTitle = getSimulatedTitle(channel, normalizedHour)
            val showDesc = getSimulatedDescription(showTitle, channel)

            list.add(
                EpgProgram(
                    title = showTitle,
                    description = showDesc,
                    startTimestamp = startTs,
                    endTimestamp = endTs,
                    startStr = startStr,
                    endStr = endStr
                )
            )
        }
        return list
    }

    private fun getSimulatedDescription(title: String, channel: IptvChannel): String {
        val titleLow = title.lowercase()
        return when {
            titleLow.contains("müge anlı") -> "Kayıp insanların arandığı, faili meçhul cinayetlerin aydınlatılmaya çalışıldığı ekranların en çok izlenen sabah kuşağı programı."
            titleLow.contains("kuruluş osman") -> "Osman Bey'in devlet kurma mücadelesini konu alan tarihi drama dizisi. Yeni bölümüyle ekranlarda."
            titleLow.contains("kim milyoner olmak") -> "Kenan İmirzalıoğlu'nun sunumuyla dünyanın en çok kazandıran genel kültür ve bilgi yarışması."
            titleLow.contains("arka sokaklar") -> "İstanbul Emniyet Müdürlüğü Asayiş Şube Müdürlüğü'nde görev yapan özel ekibin maceralarını konu alan kült polisiye dizi."
            titleLow.contains("inci taneleri") -> "Yıllar sonra hapishaneden çıkan Azem Yücedağ’ın, kaybettiği çocuklerini bulma ve hayatını yeniden kurma hikayesini konu alan başyapıt."
            titleLow.contains("kızılcık şerbeti") -> "İki farklı aile yapısının çocuklarının evliliğiyle başlayan olayları ele alan, büyük ses getiren dram dizisi."
            titleLow.contains("güldür güldür") -> "Ekranların kahkaha klasiği! Birbirinden komik skeçlerle hayatın içinden eğlenceli hikayeler ve tiplemeler."
            titleLow.contains("survivor") -> "Ünlüler ve Gönüllüler takımlarının zorlu ada şartlarında verdikleri büyük mücadele, zorlu parkur oyunları ve konsey heyecanı."
            titleLow.contains("gönül dağı") -> "Bozkırın ortasındaki bir kasabada yaşayan amcaoğullarının, imkansızlıklara rağmen uçak yapma hayallerini ve sıcacık aile bağlarını anlatan sevilen dizi."
            titleLow.contains("yemekteyiz") -> "Zuhal Topal'ın eğlenceli sunumuyla, beş farklı yarışmacının hafta boyunca kendi gününde yemek hazırlayıp misafirlerini ağırlayarak puan topladığı yemek yarışması."
            titleLow.contains("gelin görümce") -> "Gelinler ve görümcelerin lezzet ve uyum mücadelesi verdiği, popüler yarışma programı."
            titleLow.contains("yalı çapkını") -> "Gaziantepli güçlü bir ailenin şımarık oğlu Ferit ile Seyran'ın yollarının kesişmesiyle başlayan fırtınalı aşk hikayesi."
            titleLow.contains("kızıl goncalar") -> "Farklı inanç ve kültür yapılarından gelen insanların hayatlarının kesişmesini konu alan sürükleyici dram yapımı."
            titleLow.contains("seksenler") -> "80'li yılların mahalle hayatını, esnaf ilişkilerini, müziklerini ve sıcak aile bağlarını ekrana getiren nostaljik komedi dizisi."
            titleLow.contains("gelin evi") -> "Yeni evli gelinlerin sunum, ikram, ev düzeni ve düğün konseptlerini yarıştırdığı eğlenceli gündüz kuşağı programı."
            titleLow.contains("esra erol") -> "Esra Erol'un sunumuyla ailelerin bir araya geldiği, kayıpların bulunduğu ve yarım kalan hayatların tamamlandığı sevilen reality programı."
            titleLow.contains("çalar saat") -> "Günün en sıcak gelişmeleri, gazete manşetleri ve tarafsız yorumlarla güne enerjik bir başlangıç sunan sabah haber kuşağı."
            titleLow.contains("söz") -> "Vatanı için gözünü kırpmadan mücadele eden özel kuvvet timinin nefes kesen operasyonları."
            titleLow.contains("masterchef") -> "Türkiye'nin en yetenekli şef adaylarının mutfaktaki kıyasıya yarışı, şeflerin zorlu tüyoları ve lezzet dolu dakikalar."
            titleLow.contains("güz masalı") || titleLow.contains("ikimizin yerine") || titleLow.contains("yemin") || titleLow.contains("hint") -> "İzleyicileri derin bir aşk, entrika ve dram dolu yolculuğa çıkaran ekranların fenomen pembe dizisi."
            titleLow.contains("emanet") -> "Hastanede yolları kesişen iki farklı dünyanın sıcak ve duygu yüklü hikayesi."
            
            // Sports Genre
            titleLow.contains("süper lig") || titleLow.contains("maç") || titleLow.contains("karşılaşması") || titleLow.contains("derbi") -> "Süper Lig'in devlerinin kıyasıya mücadelesi! Canlı yayın ve maç öncesi-sonrası harika analizlerle futbol keyfi."
            titleLow.contains("doksan artı") -> "Haftanın tüm maçlarının, hakem kararlarının ve takımların son durumlarının tecrübeli yorumcular tarafından detaylı analizi."
            titleLow.contains("spor") || titleLow.contains("bülten") || titleLow.contains("arena") || titleLow.contains("center") || titleLow.contains("merkez") -> "Haftalık spor bülteni, transfer gelişmeleri, lig özetleri ve tüm branşlardan en yeni haberler."
            
            // News Genre
            titleLow.contains("ana haber") -> "Günün en önemli yurt içi ve yurt dışı gelişmeleri, tarafsız habercilik anlayışı ve son dakika bağlantılarıyla ekranda."
            titleLow.contains("gündem") || titleLow.contains("açık oturum") || titleLow.contains("gece ajansı") || titleLow.contains("analiz") -> "Günün öne çıkan haber başlıkları, siyaset, ekonomi, uluslararası ilişkiler uzmanlarının katılımıyla enine boyuna masaya yatırılıyor."
            titleLow.contains("haber") -> "Haber merkezinden canlı yayın, ulusal ve global düzeyde günün en sıcak gelişmeleri, anlık piyasa durumları ve hava durumu."
            
            // Movies Genre
            titleLow.contains("aksiyon") || titleLow.contains("adrenalin") || titleLow.contains("john wick") || titleLow.contains("görevimiz tehlike") || titleLow.contains("kara şövalye") -> "Nefes kesen sahneleri, inanılmaz dövüş koreografileri ve heyecan dolu kovalamacalarıyla sinema tarihinin en iyi aksiyon filmleri."
            titleLow.contains("gerilim") || titleLow.contains("korku") || titleLow.contains("zindan adası") || titleLow.contains("kuzuların sessizliği") -> "Tüyler ürperten gizemler, beklenmedik olay örgüleri ve korku dolu anlarla donatılmış sürükleyici bir sinema şöleni."
            titleLow.contains("türk sineması") -> "Yeşilçam'ın unutulmaz klasiklerinden günümüz modern Türk sinemasına uzanan geniş yelpazede ödüllü yapımlar."
            titleLow.contains("bilim kurgu") || titleLow.contains("yıldızlararası") || titleLow.contains("başlangıç") || titleLow.contains("inception") -> "Gelecek tasvirleri, yapay zeka, uzay yolculukları ve teknolojik devrimleri konu alan vizyoner başyapıtlar."
            titleLow.contains("komedi") || titleLow.contains("şaban") || titleLow.contains("çakallarla dans") -> "Karın ağrıtan kahkahalar, komik tiplemeler ve eğlenceli diyaloglarla bezenmiş harika bir komedi filmi gösterimi."
            titleLow.contains("romantik") -> "Kalpleri ısıtan aşk hikayeleri, unutulmaz sahneler ve duygusal dakikalar vaat eden romantik yapıtlar."
            titleLow.contains("sinema") || titleLow.contains("film") || titleLow.contains("vizyon") || titleLow.contains("movie") || titleLow.contains("cinema") -> "Özel seçilmiş, yüksek çözünürlükle sunulan gişe rekortmeni yerli ve yabancı sinema filmleri kuşağı."
            
            // Documentaries Genre
            titleLow.contains("uzay") || titleLow.contains("kozmos") -> "Evrenin oluşumu, kara delikler, galaksiler ve insanoğlunun yıldızlar arası keşif yolculuğunu anlatan bilimsel başyapıt."
            titleLow.contains("doğa") || titleLow.contains("vahşi") || titleLow.contains("mücadele") || titleLow.contains("yaşam") || titleLow.contains("alaska") || titleLow.contains("aslan") -> "Yeryüzündeki en vahşi yırtıcıların yaşam mücadelesi ve vahşi yaşamın bilinmeyen tarafları."
            titleLow.contains("kâşif") || titleLow.contains("okyanus") || titleLow.contains("deniz") -> "Keşfedilmemiş okyanus derinliklerindeki gizemli deniz canlıları ve su altı habitatının nefes kesen yolculuğu."
            titleLow.contains("mühendislik") || titleLow.contains("mega") -> "Dünyanın en zorlu coğrafyalarında inşa edilen mega yapıların, devasa köprülerin ve gökdelenlerin sınırları zorlayan yapım hikayeleri."
            titleLow.contains("belgesel") || titleLow.contains("nasıl yapılır") || titleLow.contains("antika") -> "İnsanlık tarihi, doğa, bilim, teknoloji ve benzersiz coğrafyaların keşfedilmemiş güzelliklerini ekranlara taşıyan ödüllü belgesel yapımı."
            
            // Kids/Cartoons Genre
            titleLow.contains("rafadan tayfa") -> "Mahalle kültürünü, dayanışmayı ve eğlenceli çocukluk maceralarını konu alan çocukların sevgilisi yerli çizgi dizi."
            titleLow.contains("keloğlan") -> "Anadolu masallarının sevimli kahramanı Keloğlan'ın kıvrak zekasıyla zorlukların üstesinden geldiği eğlenceli maceralar."
            titleLow.contains("kahraman") || titleLow.contains("çizgi") || titleLow.contains("cartoon") || titleLow.contains("çocuk") || titleLow.contains("bebek") || titleLow.contains("kids") -> "Çocukların zihinsel ve sosyal gelişimine katkıda bulunan, rengarenk, müzikli ve son derece güvenli eğitici çizgi filmler."
            
            // Music Genre
            titleLow.contains("pop") || titleLow.contains("hit") || titleLow.contains("klip") || titleLow.contains("akustik") || titleLow.contains("müzik") || titleLow.contains("music") -> "En hit klipler, her tarza hitap eden özel müzik çalma listeleri, nostaljik şarkılar ve keyifle dinlenecek canlı performanslar."
            
            // General Fallback
            else -> "Canlı ve kesintisiz televizyon yayını. ${channel.name} ekranlarında en çok sevilen ve ilgiyle takip edilen popüler program kuşağı devam ediyor."
        }
    }

    private fun getSimulatedTitle(channel: IptvChannel, baseHour: Int): String {
        val nameLow = channel.name.lowercase()
        val catLow = channel.category.lowercase()
        val hash = kotlin.math.abs(channel.name.hashCode() + baseHour)
        
        // 1. Specific Major Turkish Channels
        if (nameLow.contains("atv") || nameLow.contains("a2")) {
            return when (baseHour) {
                in 6..7 -> "Güne Merhaba"
                in 8..9 -> "Kahvaltı Haberleri"
                in 10..12 -> "Müge Anlı ile Tatlı Sert"
                13 -> "ATV Gün Ortası Haberleri"
                in 14..15 -> "Mutfak Bahane"
                in 16..18 -> "Esra Erol'da"
                19 -> "ATV Ana Haber"
                in 20..22 -> "Kuruluş Osman (Yeni Bölüm)"
                23 -> "Kim Milyoner Olmak İster?"
                else -> "Gece Sineması / Tekrar Kuşağı"
            }
        }
        
        if (nameLow.contains("kanal d") || nameLow.contains("kanald")) {
            return when (baseHour) {
                in 6..8 -> "Görsel Haber"
                in 9..10 -> "Neler Oluyor Hayatta?"
                in 11..12 -> "Gelinim Mutfakta"
                in 13..15 -> "Arka Sokaklar (Tekrar)"
                in 16..17 -> "Gelinim Mutfakta (Özel Sürüm)"
                in 18..19 -> "Kanal D Ana Haber"
                in 20..22 -> "İnci Taneleri (Yeni Bölüm)"
                23 -> "Yabancı Sinema Kuşağı"
                else -> "Arka Sokaklar (Tekrar)"
            }
        }
        
        if (nameLow.contains("show")) {
            return when (baseHour) {
                in 6..7 -> "Yeni Güne Merhaba"
                in 8..9 -> "Bu Sabah"
                in 10..12 -> "Dizi Tekrar Kuşağı"
                in 13..14 -> "Gelin Evi"
                in 15..17 -> "Didem Arslan Yılmaz'la Vazgeçme"
                in 18..19 -> "Show Ana Haber"
                in 20..22 -> "Kızılcık Şerbeti (Yeni Bölüm)"
                23 -> "Kızılcık Şerbeti (Tekrar)"
                else -> "Güldür Güldür Show (Tekrar)"
            }
        }
        
        if (nameLow.contains("star")) {
            return when (baseHour) {
                in 6..7 -> "Güne Başlarken"
                in 8..9 -> "Sabahın Sultanı Seda Sayan"
                in 10..12 -> "Gerçeğin Peşinde"
                in 13..15 -> "Dizi Tekrar Kuşağı"
                in 16..18 -> "Söz (Tekrar)"
                19 -> "Star Haber"
                in 20..22 -> "Yalı Çapkını (Yeni Bölüm)"
                23 -> "Yalı Çapkını (Tekrar)"
                else -> "Yerli Film Özel Gösterim"
            }
        }
        
        if (nameLow.contains("tv8") || nameLow.contains("tv 8")) {
            return when (baseHour) {
                in 6..7 -> "Görsel Sabah"
                in 8..9 -> "Gel Konuşalım"
                in 10..12 -> "Aramızda Kalmasın"
                in 13..15 -> "Survivor Panoroma"
                in 16..19 -> "Zuhal Topal'la Yemekteyiz"
                in 20..23 -> "Survivor Türkiye (Canlı)"
                else -> "MasterChef Türkiye (Tekrar)"
            }
        }
        
        if (nameLow.contains("trt 1") || nameLow.contains("trt1")) {
            return when (baseHour) {
                in 6..7 -> "Kur'an-ı Kerim'i Güzel Okuma Yarışması"
                in 8..9 -> "Günaydın Hayat"
                in 10..12 -> "Alişan ile Hayata Gülümse"
                in 13..15 -> "Seksenler (Tekrar)"
                in 16..18 -> "Gönül Dağı (Tekrar)"
                19 -> "TRT 1 Ana Haber"
                in 20..22 -> "Gönül Dağı (Yeni Bölüm)"
                23 -> "Pelin Çift ile Gündem Ötesi"
                else -> "Seksenler Nostalji Kuşağı"
            }
        }
        
        if (nameLow.contains("now") || nameLow.contains("fox")) {
            return when (baseHour) {
                in 6..7 -> "Ezgi Gözeger ile Çalar Saat Hafta Sonu"
                in 8..10 -> "İlker Karagöz ile NOW Çalar Saat"
                in 11..12 -> "Çağla ile Yeni Bir Gün"
                in 13..15 -> "En Hamarat Benim"
                in 16..18 -> "Fatih Ürek ile Gelin Görümce"
                19 -> "Selçuk Tepeli ile NOW Ana Haber"
                in 20..22 -> "Kızıl Goncalar (Yeni Bölüm)"
                23 -> "Orta Sayfa"
                else -> "Yabancı Sinema Kuşağı / Tekrar"
            }
        }
        
        if (nameLow.contains("kanal 7") || nameLow.contains("kanal7")) {
            return when (baseHour) {
                in 6..7 -> "Kanal 7'de Sabah"
                in 8..12 -> "Güz Masalı (Hint Dizisi)"
                in 13..15 -> "İkimizin Yerine (Hint Dizisi)"
                in 16..18 -> "Yemin (Tekrar)"
                19 -> "Kanal 7 Ana Haber"
                in 20..22 -> "Emanet (Yeni Bölüm)"
                23 -> "Başka Rotasız"
                else -> "Hint Dizileri Tekrar"
            }
        }
        
        // 2. Sports Genres (Eurosport, beIN Sport, S Sport, Tivibu Spor, A Spor, TRT Spor etc.)
        if (catLow.contains("spor") || catLow.contains("sport") || nameLow.contains("spor") || nameLow.contains("sport") || nameLow.contains("bein") || nameLow.contains("eurosport") || nameLow.contains("ssport")) {
            return when (baseHour) {
                in 6..7 -> "Eurosport Haber / Sabah Sporu"
                in 8..9 -> "Süper Lig Gündemi / Transfer Günlüğü"
                in 10..12 -> "Spor Center / Canlı Bağlantılar"
                in 13..16 -> "Avrupa Ligleri Özel Programı / Maç Analiz"
                in 17..18 -> "Canlı Haber / Dev Maç Önü Analizleri"
                in 19..22 -> {
                    val teams = listOf(
                        "Galatasaray - Fenerbahçe Süper Lig Derbisi (Canlı)",
                        "Beşiktaş - Trabzonspor Karşılaşması (Canlı)",
                        "Real Madrid - Manchester City Şampiyonlar Ligi (Canlı)",
                        "Anadolu Efes - Fenerbahçe Beko EuroLeague (Canlı)"
                    )
                    teams[hash % teams.size]
                }
                23 -> "Doksan Artı / Derbi ve Maç Sonu Özel Analizi"
                else -> "Unutulmaz Karşılaşmalar / Altın Arşiv"
            }
        }
        
        // 3. News Genres (NTV, CNN Türk, Habertürk, TRT Haber, Halk TV, Sözcü TV, Tele1, Ekol etc.)
        if (catLow.contains("haber") || catLow.contains("news") || nameLow.contains("haber") || nameLow.contains("news") || nameLow.contains("ntv") || nameLow.contains("cnn") || nameLow.contains("sozcu") || nameLow.contains("sözcü") || nameLow.contains("szc") || nameLow.contains("halk") || nameLow.contains("tele1") || nameLow.contains("tv100") || nameLow.contains("global")) {
            return when (baseHour) {
                in 6..8 -> "Gözcü Sabah Ajansı / Manşet Gelişmeleri"
                in 9..11 -> "Ekonomi ve Piyasalar Son Durum / Canlı"
                in 12..13 -> "Gün Ortası Canlı Haber Bülteni"
                in 14..16 -> "Özel Analiz / Ekonomi ve Politika Gündemi"
                in 17..18 -> "Akşam Bülteni / Manşet Geri Sayım"
                in 19..20 -> "Ana Haber Bülteni (Canlı)"
                in 21..23 -> "Karşı Karşıya / Siyaset ve Açık Oturum Tartışma"
                else -> "Haber Masası / Uykusuzlara Özel Gece Geçi"
            }
        }
        
        // 4. Movie / VOD / Cinema Genres
        if (catLow.contains("sinema") || catLow.contains("film") || catLow.contains("movie") || catLow.contains("vod") || nameLow.contains("sinema") || nameLow.contains("film") || nameLow.contains("cinema") || nameLow.contains("vizyon")) {
            if (nameLow.contains("aksiyon") || nameLow.contains("action")) {
                return when (baseHour) {
                    in 6..12 -> "Gündüz Aksiyon Kuşağı: Hızlı ve Öfkeli"
                    in 13..17 -> "Soluksuz Takip: Görevimiz Tehlike"
                    in 18..21 -> "Akşam Blockbuster Filmi: Kara Şövalye"
                    else -> "Gece Adrenalin Kuşağı: John Wick"
                }
            }
            if (nameLow.contains("gerilim") || nameLow.contains("korku") || nameLow.contains("thriller") || nameLow.contains("horror")) {
                return when (baseHour) {
                    in 6..12 -> "Öğle Sonu Gizemi: Zindan Adası"
                    in 13..17 -> "Psikolojik Gerilim: Kuzuların Sessizliği"
                    in 18..21 -> "Gerilim Saati: Se7en (Yedi)"
                    else -> "Gece Kabusu: Korku Seansı"
                }
            }
            if (nameLow.contains("komedi") || nameLow.contains("comedy")) {
                return when (baseHour) {
                    in 6..12 -> "Güne Kahkaha ile Başlayın: Maske"
                    in 13..17 -> "Komedi Saati: Şaban Oğlu Şaban"
                    in 18..21 -> "Akşam Eğlencesi: Çakallarla Dans"
                    else -> "Gece Stand-up Gösterisi & Komedi"
                }
            }
            // General Cinema
            return when (baseHour) {
                in 6..10 -> "Sinema Klasikleri: Esaretin Bedeli"
                in 11..14 -> "Aile Sineması: Forrest Gump"
                in 15..17 -> "Ödüllü Yapımlar: Parazit"
                in 18..21 -> "Prime Time Sinema: Yıldızlararası"
                else -> "Gece Sineması: Başlangıç (Inception)"
            }
        }
        
        // 5. Documentary Genres
        if (catLow.contains("belgesel") || catLow.contains("document") || nameLow.contains("belgesel") || nameLow.contains("documentary") || nameLow.contains("geographic") || nameLow.contains("history") || nameLow.contains("dmax") || nameLow.contains("tlc") || nameLow.contains("wild")) {
            if (nameLow.contains("wild") || nameLow.contains("doğa") || nameLow.contains("geographic")) {
                return when (baseHour) {
                    in 6..10 -> "Vahşi Alaska Günlükleri"
                    in 11..14 -> "Savana Kaplanları & Aslanlar İmparatorluğu"
                    in 15..17 -> "Derin Okyanusun Gizemli Canlıları"
                    in 18..21 -> "Afrika'nın Vahşi Kralları"
                    else -> "Yırtıcıların Gecesi / Karanlıktaki Pençeler"
                }
            }
            return when (baseHour) {
                in 6..10 -> "Antika Avcıları / Değerli Hazineler"
                in 11..14 -> "Nasıl Yapılır? / Bilim ve Teknoloji"
                in 15..17 -> "Ölümcül Av / Alaska Balıkçıları"
                in 18..21 -> "Otoyol Polisi / Kovalamaca 24 Saat"
                else -> "Sıra Dışı Mühendislik Harikaları ve Mega Yapılar"
            }
        }
        
        // 6. Kids/Cartoon Genres
        if (catLow.contains("çocuk") || catLow.contains("bebek") || catLow.contains("kids") || catLow.contains("cartoon") || catLow.contains("çizgi") || nameLow.contains("çizgi") || nameLow.contains("cocuk") || nameLow.contains("kids")) {
            return when (baseHour) {
                in 7..9 -> "Sevimli Kahramanlar / Rafadan Tayfa"
                in 10..12 -> "Keloğlan / Neşeli Melodiler"
                in 13..15 -> "Macera Ormanı / Sevimli Hayvanlar"
                in 16..18 -> "Süper Kahramanlar / Rafadan Tayfa"
                in 19..20 -> "Akşam Çizgi Filmleri"
                else -> "Masal Saati / Uyku Öncesi Hikayeler"
            }
        }

        // 7. Music Genres
        if (catLow.contains("müzik") || catLow.contains("music") || nameLow.contains("müzik") || nameLow.contains("music") || nameLow.contains("kral") || nameLow.contains("power") || nameLow.contains("dream") || nameLow.contains("tr")) {
            return when (baseHour) {
                in 6..9 -> "Sabah Enerjisi / Türkçe Pop %100"
                in 10..13 -> "Günün En Popüler Top 20 Klipleri"
                in 14..17 -> "Kral Akustik Kampet Performansları"
                in 18..20 -> "Retro Hits / Unutulmaz 90'lar & 2000'ler"
                in 21..22 -> "Power Party / DJ Canlı Kabin Seti"
                else -> "Gece Ritmi / Chillout Sakin Melodiler"
            }
        }
        
        // 8. General Fallback
        val generic = listOf(
            "Özel Yayını", "Günlük Akış Programı", "Eğlenceli Saatler", "Haftalık Özet",
            "Yaşam ve Sağlık Kuşağı", "Ev Sohbetleri", "Gündüz Bülteni", "Seçkin Yapımlar",
            "Canlı Yayın Kuşağı", "Gece Klasiği", "Özel Nostalji", "Seyahat ve Kültür"
        )
        return "${channel.name} ${generic[hash % generic.size]}"
    }

    fun setSearchQuery(query: String) {
        _searchQuery.value = query
    }

    fun setSelectedCategory(category: String) {
        _selectedCategory.value = category
    }

    fun loadAccountInfo(playlist: IptvPlaylist) {
        viewModelScope.launch {
            _loadingAccountInfo.value = true
            try {
                val info = XtreamClient.fetchAccountDetails(playlist)
                
                val infoWithCount = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
                    val channels = _loadedChannels.value
                    val totalCount = channels.size
                    
                    if (totalCount > 0) {
                        val movieKeywords = listOf("film", "movie", "sinema", "vod", "cinema", "ortak", "vizyon")
                        val tvKeywords = listOf("dizi", "series", "season")
                        
                        var lCount = 0
                        var mCount = 0
                        var sCount = 0
                        
                        for (ch in channels) {
                            val catLow = ch.category.lowercase()
                            when {
                                movieKeywords.any { catLow.contains(it) } -> mCount++
                                tvKeywords.any { catLow.contains(it) } -> sCount++
                                else -> lCount++
                            }
                        }
                        info.copy(
                            liveChannelsCount = lCount,
                            moviesCount = mCount,
                            seriesCount = sCount
                        )
                    } else {
                        info
                    }
                }
                _accountInfo.value = infoWithCount
            } catch (e: Exception) {
                e.printStackTrace()
            } finally {
                _loadingAccountInfo.value = false
            }
        }
    }

    fun fetchEpgForChannelOnDemand(channel: IptvChannel) {
        // Activated demand EPG map
        _channelsActiveEpg.value = _channelsActiveEpg.value.toMutableMap().also {
            it[channel.streamUrl] = getChannelActiveProgram(channel)
        }
    }

    private fun findCurrentActiveProgram(programs: List<EpgProgram>): EpgProgram? {
        val now = System.currentTimeMillis() / 1000
        return programs.firstOrNull { now in it.startTimestamp until it.endTimestamp }
    }

    fun getChannelActiveProgram(channel: IptvChannel): EpgProgram {
        val programs = generateSimulatedEpg(channel)
        val now = System.currentTimeMillis() / 1000
        return programs.firstOrNull { now in it.startTimestamp until it.endTimestamp }
            ?: programs.firstOrNull { it.startTimestamp > now }
            ?: EpgProgram(
                title = "Canlı Yayın",
                description = "Yayın akışı devam ediyor.",
                startTimestamp = now - 3600,
                endTimestamp = now + 3600,
                startStr = "16:00",
                endStr = "18:00"
            )
    }

    fun getChannelPrograms(channel: IptvChannel): List<EpgProgram> {
        return generateSimulatedEpg(channel)
    }
}

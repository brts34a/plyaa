import SwiftUI
import AVKit
import Combine
import AVFoundation
import MediaPlayer

// MARK: - Safe Decoder Int/String Helper for Xtream Codes Compatibility
enum SafeStringOrInt: Codable, Hashable {
    case string(String)
    case integer(Int)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let i = try? container.decode(Int.self) {
            self = .integer(i)
        } else {
            self = .string("")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .integer(let i): try container.encode(i)
        }
    }
    
    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .integer(let i): return String(i)
        }
    }
    
    var intValue: Int {
        switch self {
        case .string(let s): return s.isEmpty ? 0 : (Int(s) ?? 0)
        case .integer(let i): return i
        }
    }
}

// MARK: - IPTV Models
struct IPTVAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var mode: Int // 0 = M3U, 1 = Xtream
    var m3uUrl: String = ""
    var xtreamHost: String = ""
    var xtreamUser: String = ""
    var xtreamPass: String = ""
    var expDate: String?
    var maxConnections: String?
    var activeConnections: String?
    var status: String?
    var epgUrl: String?
}

struct Channel: Identifiable, Codable, Hashable {
    var id = UUID()
    let name: String
    let logo: String
    let group: String
    let url: String
    var contentType: String = "live" // "live", "movie", "series"
    var added: Int? = 0
    var customStreamId: String? = nil
    
    enum CodingKeys: String, CodingKey {
        case id, name, logo, group, url, contentType, added, customStreamId = "streamId"
    }
    
    init(name: String, logo: String, group: String, url: String, contentType: String = "live", added: Int? = 0, streamId: String? = nil) {
        self.id = UUID()
        self.name = name
        self.logo = logo
        self.group = group
        self.url = url
        self.contentType = contentType
        self.added = added ?? 0
        self.customStreamId = streamId
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.logo = try container.decode(String.self, forKey: .logo)
        self.group = try container.decode(String.self, forKey: .group)
        self.url = try container.decode(String.self, forKey: .url)
        self.contentType = try container.decodeIfPresent(String.self, forKey: .contentType) ?? "live"
        self.added = try container.decodeIfPresent(Int.self, forKey: .added) ?? 0
        self.customStreamId = try container.decodeIfPresent(String.self, forKey: .customStreamId)
    }
    
    var streamId: String? {
        if let explicitId = customStreamId { return explicitId }
        guard contentType == "live" else { return nil }
        let parts = url.components(separatedBy: "/")
        if parts.count >= 4, let last = parts.last {
            if let dotIndex = last.firstIndex(of: ".") {
                return String(last[..<dotIndex])
            }
            return last
        }
        return nil
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(logo, forKey: .logo)
        try container.encode(group, forKey: .group)
        try container.encode(url, forKey: .url)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(added, forKey: .added)
    }
    
    var safeGroup: String {
        let g = group.trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty ? "Diğer" : g
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(url)
    }
    
    static func == (lhs: Channel, rhs: Channel) -> Bool {
        return lhs.name == rhs.name && lhs.url == rhs.url
    }
}

// MARK: - Resilient Decoder Error-Prevention Wrapper
struct SafeDecodable<T: Codable>: Codable {
    let value: T?
    
    init(from decoder: Decoder) throws {
        do {
            let container = try decoder.singleValueContainer()
            self.value = try container.decode(T.self)
        } catch {
            self.value = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = value {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }
}

// MARK: - Custom Network & Xtream Codes Models
struct XtreamCategory: Codable, Identifiable {
    let category_id: SafeStringOrInt?
    let category_name: String?
    
    var id: String { category_id?.stringValue ?? UUID().uuidString }
}

struct XtreamStream: Codable {
    let num: SafeStringOrInt?
    let name: String?
    let stream_name: String?
    let stream_id: SafeStringOrInt?
    let stream_icon: String?
    let category_id: SafeStringOrInt?
    let container_extension: String?
}

struct XtreamLoginResponse: Codable {
    struct UserInfo: Codable {
        let username: String?
        let status: String?
        let exp_date: SafeStringOrInt?
        let active_cons: SafeStringOrInt?
        let max_connections: SafeStringOrInt?
    }
    let user_info: UserInfo?
}

// MARK: - Volume View Extension for SwiftUI Gesture Control
extension MPVolumeView {
    static var volumeSlider: UISlider? {
        let volumeView = MPVolumeView()
        return volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
    }
}
class PlayerInfoManager: ObservableObject {
    @Published var resolutionString: String = "Bağlanıyor..."
    @Published var isAudioOnly: Bool = false
    @Published var isOverlayVisible: Bool = true
    @Published var isPlaying: Bool = true
    weak var player: AVPlayerUIView?
    var timer: Timer?
    var hideTimer: Timer?
    
    func start(player: AVPlayerUIView?) {
        self.player = player
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.update()
        }
        userTapped()
    }
    
    func update() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.player?.player else { return }
            
            if let item = p.currentItem {
                let size = item.presentationSize
                if size.height > 10 {
                    self.resolutionString = "\(Int(size.height))p 50FPS"
                }
            }
        }
    }
    
    func togglePlayPause() {
        guard let p = player?.player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            p.play()
            isPlaying = true
        }
    }
    
    func userTapped() {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                self.isOverlayVisible = true
            }
            self.hideTimer?.invalidate()
            self.hideTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
                withAnimation(.easeInOut(duration: 0.5)) {
                    self?.isOverlayVisible = false
                }
            }
        }
    }
    
    func stop() {
        timer?.invalidate()
        hideTimer?.invalidate()
        player?.player?.pause()
        player = nil
        DispatchQueue.main.async {
            self.resolutionString = "Bağlanıyor..."
            self.isPlaying = false
        }
    }
    
    deinit {
        timer?.invalidate()
        hideTimer?.invalidate()
    }
}

// MARK: - Native iOS High-Performance IPTV AVPlayer
class AVPlayerUIView: UIView {
    var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }
    
    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }
    
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
}

struct NativeVideoPlayerView: UIViewRepresentable {
    let urlString: String
    let videoContentMode: UIView.ContentMode
    @ObservedObject var infoManager: PlayerInfoManager
    var showsPlaybackControls: Bool = true
    
    class Coordinator: NSObject {
        var currentUrl: String = ""
        var playerView: AVPlayerUIView?
        var player: AVPlayer?
        weak var infoManager: PlayerInfoManager?
        var statusObservation: NSKeyValueObservation?
        var timeObserverToken: Any?
        
        init(infoManager: PlayerInfoManager) {
            self.infoManager = infoManager
            super.init()
        }
        
        deinit {
            statusObservation?.invalidate()
            if let to = timeObserverToken, let p = player {
                p.removeTimeObserver(to)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(infoManager: infoManager)
    }
    
    func makeUIView(context: Context) -> AVPlayerUIView {
        let view = AVPlayerUIView()
        view.backgroundColor = .black
        switch videoContentMode {
        case .scaleAspectFill:
            view.playerLayer.videoGravity = .resizeAspectFill
        case .scaleAspectFit:
            view.playerLayer.videoGravity = .resizeAspect
        default:
            view.playerLayer.videoGravity = .resizeAspect
        }
        context.coordinator.playerView = view
        return view
    }
    
    func updateUIView(_ uiView: AVPlayerUIView, context: Context) {
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            uiView.player?.pause()
            return
        }
        
        if context.coordinator.currentUrl != normalized {
            context.coordinator.currentUrl = normalized
            
            // The Magic Trick: AVPlayer struggles with raw .ts streams.
            // If the URL ends with .ts, we replace it with .m3u8.
            // Xtream Codes natively supports this and returns an HLS stream which AVPlayer prefers.
            var playableUrlString = normalized
            if playableUrlString.hasSuffix(".ts") {
                playableUrlString = playableUrlString.replacingOccurrences(of: ".ts", with: ".m3u8")
            }
            
            if let targetUrl = URL(string: playableUrlString) {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
                try? AVAudioSession.sharedInstance().setActive(true)
                
                let headers: [String: String] = ["User-Agent": "VLC/3.0.18 LibVLC/3.0.18"]
                let asset = AVURLAsset(url: targetUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                uiView.player = player
                context.coordinator.player = player
                
                context.coordinator.statusObservation = player.currentItem?.observe(\.status, options: [.new, .old]) { item, _ in
                    if item.status == .readyToPlay {
                        DispatchQueue.main.async {
                            context.coordinator.infoManager?.resolutionString = "Oynatılıyor"
                            let size = item.presentationSize
                            if size.width > 0 && size.height > 0 {
                                context.coordinator.infoManager?.resolutionString = "\(Int(size.height))p"
                            }
                        }
                    } else if item.status == .failed {
                        DispatchQueue.main.async {
                            context.coordinator.infoManager?.resolutionString = "Hata"
                        }
                    }
                }
                
                player.play()
                
                DispatchQueue.main.async {
                    context.coordinator.infoManager?.isPlaying = true
                    // Provide a reference to the player layer instance so togglePlayPause works
                    // Context infoManager can store an Any? reference to AVPlayer 
                    context.coordinator.infoManager?.player = uiView
                }
            }
        }
    }
    
    static func dismantleUIView(_ uiView: AVPlayerUIView, coordinator: Coordinator) {
        uiView.player?.pause()
    }
}

// MARK: - Modern Player Overlay: Clock, Quality
struct PlayerOverlaySwiftUIView: View {
    @ObservedObject var info: PlayerInfoManager
    
    var body: some View {
        GeometryReader { geo in
            let isLandscapeMode = geo.size.width > geo.size.height
            
            if !isLandscapeMode {
                VStack {
                    HStack(spacing: 8) {
                        Spacer()
                        
                        if info.isOverlayVisible {
                            // Kalite / FPS
                            HStack(spacing: 4) {
                                Image(systemName: info.isAudioOnly ? "waveform" : "bolt.horizontal.fill")
                                    .foregroundColor(info.isAudioOnly ? Color.orange : Color(hex: "6D28D9"))
                                Text(info.resolutionString)
                                    .fontWeight(.bold)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(info.isAudioOnly ? Color.yellow.opacity(0.15) : Color.black.opacity(0.65))
                            .cornerRadius(8)
                            .transition(.opacity)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.top, 45) // Provides clearance for native back/close buttons on notch devices
                    .padding(.trailing, 45)
                    .animation(.easeInOut(duration: 0.3), value: info.isOverlayVisible)
                    
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Main IPTV Application UI
struct ContentView: View {
    // Mode choice: 0 = M3U, 1 = Xtream Codes
    @AppStorage("iptv_mode") private var iptvMode: Int = 0
    
    // Saved credentials
    @AppStorage("m3u_url") private var m3uUrl: String = ""
    @AppStorage("xtream_host") private var xtreamHost: String = ""
    @AppStorage("xtream_user") private var xtreamUser: String = ""
    @AppStorage("xtream_pass") private var xtreamPass: String = ""
    
    // Server / Subscription Details
    @AppStorage("server_expiry") private var serverExpiry: String = ""
    @AppStorage("server_active_cons") private var serverActiveCons: String = ""
    @AppStorage("server_max_cons") private var serverMaxCons: String = ""
    @AppStorage("server_status") private var serverStatus: String = ""
    
    // UI States
    @Namespace private var glassAnimation
    @State private var accounts: [IPTVAccount] = []
    @State private var showAccountsSheet: Bool = false
    @AppStorage("dion_active_account_id") private var activeAccountIdString: String = ""
    @State private var playerContentMode: UIView.ContentMode = .scaleAspectFit
    
    @State private var channels: [Channel] = []
    @State private var favourites: Set<String> = []
    @State private var selectedChannel: Channel? = nil
    
    @StateObject private var globalPlayerInfo = PlayerInfoManager()
    
    // Collapsible profile bar state (Hidden by default to save screen space)
    @State private var showActiveProfileDetails: Bool = false
    
    // Primary Filter Tabs
    @State private var contentTypeFilter: String = "live" // "live", "movie", "series"
    @State private var selectedCategory: String = "Tümü"
    @State private var searchQuery: String = ""
    
    // Core Loaders
    @State private var providerSheetState: Int = 0 // 0: Main list, 1: Add M3U, 2: Add Xtream, 3: Detail
    @State private var selectedDetailAccount: IPTVAccount? = nil
    @State private var showCategorySheet: Bool = false
    @State private var categorySearchQuery: String = ""
    @State private var isLoading: Bool = false
    @State private var showSyncOverlay: Bool = false
    @State private var loadStep1: Bool = false
    @State private var loadStep2: Bool = false
    @State private var loadStep3: Bool = false
    @State private var loadStep4: Bool = false
    @State private var loadStep5: Bool = false
    @State private var loadStepFinished: Bool = false
    @State private var loadingMessage: String = ""
    @State private var errorMessage: String? = nil
    
    // Sheet Local States
    @State private var tempM3uUrl: String = ""
    @State private var tempM3uEpgUrl: String = ""
    @State private var tempXtreamHost: String = ""
    @State private var tempXtreamUser: String = ""
    @State private var tempXtreamPass: String = ""
    @State private var tempEditAccountName: String = ""
    @State private var tempEditUrl: String = ""
    @State private var tempEditUser: String = ""
    @State private var tempEditPass: String = ""
    @State private var tempEditEpgUrl: String = ""
    @State private var sheetIsLoading: Bool = false
    @State private var sheetLoadingMessage: String = ""
    @State private var sheetError: String? = nil
    @State private var cacheClearedMessage: String? = nil
    
    // MARK: - App Tab Selection
    enum AppTab { case home, live, library, search, settings }
    @State private var currentTab: AppTab = .home
    @State private var isLandscape: Bool = false
    @State private var isInitializingChannels: Bool = true
    @State private var showLandscapeChannelList: Bool = false
    @State private var landscapeSearchQuery: String = ""
    @State private var selectedLandscapeGroup: String = "Tümü"
    @State private var showLandscapeSettings: Bool = false
    @State private var showBrightnessPill: Bool = false
    @State private var showVolumePill: Bool = false
    @State private var showingControls: Bool = false
    @State private var controlsTimer: Timer? = nil
    @State private var brightnessLevel: CGFloat = UIScreen.main.brightness
    @State private var volumeLevel: CGFloat = 0.5
    @State private var dragStartBrightness: CGFloat = 0.5
    @State private var dragStartVolume: CGFloat = 0.5
    
    var body: some View {
        GeometryReader { geo in
            let _ = geo.size.width > geo.size.height
            ZStack {
                Color(hex: "08090C").ignoresSafeArea()
                
                // Active Volume Sync with physical buttons / system levels
                VolumeSliderRepresentable(volume: $volumeLevel)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                
                // Premium Blurry Neon Fluid Backgrounds
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(hex: "6D28D9"), Color(hex: "007FFF")], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 320, height: 320)
                        .offset(x: -120, y: -240)
                    Circle()
                        .fill(LinearGradient(colors: [Color(hex: "FF007F"), Color(hex: "7B2CBF")], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 380, height: 380)
                        .offset(x: 140, y: -100)
                }
                .blur(radius: 80)
                .opacity(0.18)
                .ignoresSafeArea()
                
                if isLandscape, let _ = selectedChannel {
                    landscapePlayerView
                        .background(Color.black)
                        .ignoresSafeArea()
                        .zIndex(2000)
                } else {
                    VStack(spacing: 0) {
                        if let channel = selectedChannel {
                            globalPortraitPlayerView
                                .frame(height: geo.size.height * 0.35)
                            
                            if channel.contentType != "live" {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 16) {
                                        Text(channel.name)
                                            .font(.system(size: 24, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 20)
                                            .padding(.top, 20)
                                            
                                        Text(channel.safeGroup)
                                            .font(.system(size: 14))
                                            .foregroundColor(.white.opacity(0.6))
                                            .padding(.horizontal, 20)
                                            
                                        Text("Şimdi Oynatılıyor...")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(Color(hex: "6D28D9"))
                                            .padding(.horizontal, 20)
                                    }
                                }
                                .frame(height: geo.size.height * 0.65)
                            } else {
                                mainTabContent
                                    .frame(height: geo.size.height * 0.65)
                            }
                        } else {
                            mainTabContent
                                .frame(height: geo.size.height)
                        }
                        Spacer(minLength: 0)
                    }
                    
                    VStack {
                        Spacer()
                        floatingTabBar
                    }
                }
            }
        }
        .onAppear {
            loadAccounts()
            configureAudioSession()
            loadFavourites()
            loadSavedData()
            brightnessLevel = UIScreen.main.brightness
            volumeLevel = CGFloat(AVAudioSession.sharedInstance().outputVolume)
        }
        .overlay(
            Group {
                if showSyncOverlay {
                    syncOverlayView
                }
            }
        )
        .sheet(isPresented: $showCategorySheet) {
            categorySelectionSheet
                .sexySheetBackground()
        }
        .sheet(isPresented: $showAccountsSheet) {
            accountsDrawerSheet
                .sexySheetBackground()
        }
        .preferredColorScheme(.dark) // Force dark color scheme to keep UI colors crisp
    }
    
    var syncOverlayView: some View {
        ZStack {
            Color(hex: "101116").ignoresSafeArea()
            
            VStack(spacing: 24) {
                if loadStepFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                        .padding(.top, 40)
                    
                    Text("Her şey hazır!")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("\(channels.filter({ $0.contentType == "live" }).count) kanal, \(channels.filter({ $0.contentType == "movie" }).count) film, \(channels.filter({ $0.contentType == "series" }).count) dizi")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.bottom, 20)
                } else {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.05)).frame(width: 80, height: 80)
                        Image(systemName: "film")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                    }
                    .padding(.top, 40)
                    
                    Text("İçeriğiniz hazırlanıyor")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text(loadingMessage)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.bottom, 20)
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    syncStepRow(text: "Sunucuya bağlanılıyor", isDone: loadStep1, inProgress: isLoading && !loadStepFinished && !loadStep1)
                    syncStepRow(text: "Canlı kanallar eşitleniyor", isDone: loadStep2, inProgress: loadStep1 && !loadStep2)
                    syncStepRow(text: "Filmler eşitleniyor", isDone: loadStep3, inProgress: loadStep2 && !loadStep3)
                    syncStepRow(text: "Diziler eşitleniyor", isDone: loadStep4, inProgress: loadStep3 && !loadStep4)
                    syncStepRow(text: "İçerik eşleştiriliyor", isDone: loadStep5, inProgress: loadStep4 && !loadStep5)
                }
                .padding(24)
                .background(Color(hex: "1C1C1E"))
                .cornerRadius(16)
                .padding(.horizontal, 30)
                
                Spacer()
            }
            .padding(.top, 40)
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        if loadStepFinished {
                            showSyncOverlay = false
                            isLoading = false
                            showAccountsSheet = false
                            providerSheetState = 0
                            currentTab = .home
                        } else {
                            showSyncOverlay = false
                            isLoading = false
                        }
                    }) {
                        Text("Bitti")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .sexyGlass(cornerRadius: 16)
                            .frame(height: 32)
                    }
                    .padding(.trailing, 20)
                    .padding(.top, 20)
                }
                Spacer()
            }
        }
    }
    
    func syncStepRow(text: String, isDone: Bool, inProgress: Bool) -> some View {
        HStack(spacing: 12) {
            if isDone {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 20))
            } else if inProgress {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.6)))
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "circle").foregroundColor(.white.opacity(0.2)).font(.system(size: 20))
            }
            
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(isDone || inProgress ? .white : .white.opacity(0.3))
            
            Spacer()
        }
    }
    
    // MARK: - New Architecture Views
    
    var mainTabContent: some View {
        Group {
            switch currentTab {
            case .home:
                if isInitializingChannels { initializingView() } else if channels.isEmpty { emptyView() } else { homeTabContent }
            case .live:
                if isInitializingChannels { initializingView() } else if channels.isEmpty { emptyView() } else { liveTVTabContent }
            case .library:
                if isInitializingChannels { initializingView() } else if channels.isEmpty { emptyView() } else { libraryTabContent }
            case .search:
                if isInitializingChannels { initializingView() } else if channels.isEmpty { emptyView() } else { searchTabContent }
            case .settings:
                accountsDrawerSheet
            }
        }
    }
    
    @State private var localLiveCategory: String = "Tümü"
    
    var globalPortraitPlayerView: some View {
        VStack(spacing: 0) {
            if let channel = selectedChannel {
                // Top Header (Dion Style)
                HStack(spacing: 0) {
                    Button(action: { closeSelectedChannel() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    
                    Spacer(minLength: 10)
                    
                    VStack(spacing: 2) {
                        Text(channel.name.uppercased())
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if channel.contentType == "live" {
                            let prgName = EPGManager.shared.currentProgramName(for: channel)
                            Text(prgName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer(minLength: 10)
                    
                    Button(action: { toggleFavourite(channel.url) }) {
                        Image(systemName: favourites.contains(channel.url) ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                
                // Video Player Container
                ZStack {
                    NativeVideoPlayerView(urlString: channel.url, videoContentMode: playerContentMode, infoManager: globalPlayerInfo)
                        .background(Color.black)
                    
                    if globalPlayerInfo.isOverlayVisible {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        
                        // Top Left Airplay
                        VStack {
                            HStack {
                                Button(action: {}) {
                                    Image(systemName: "rectangle.inset.filled.and.person.filled") // Mock for airplay/cast
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 38, height: 38)
                                        .background(Color.white.opacity(0.2))
                                        .clipShape(Circle())
                                }
                                Spacer()
                            }
                            .padding(12)
                            Spacer()
                        }
                        
                        // Center Play/Pause
                        Button(action: { globalPlayerInfo.togglePlayPause() }) {
                            Image(systemName: globalPlayerInfo.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 64, height: 64)
                                .background(Color.white.opacity(0.2))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1.5))
                        }
                        
                        // Bottom Details
                        VStack {
                            Spacer()
                            HStack(alignment: .bottom) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                    Text("CANLI  \(channel.name.uppercased())")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 6) {
                                    Button(action: { withAnimation { isLandscape = true } }) {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                    
                                    if channel.contentType == "live" {
                                        let nextPrg = EPGManager.shared.nextProgramName(for: channel)
                                        if !nextPrg.isEmpty {
                                            Text(nextPrg.uppercased())
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.white.opacity(0.7))
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                            
                            // Progress Bar
                            if channel.contentType == "live" {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.3))
                                            .frame(height: 2.5)
                                            .cornerRadius(1.25)
                                        Rectangle()
                                            .fill(Color.white)
                                            .frame(width: geo.size.width * CGFloat(EPGManager.shared.programProgress(for: channel)), height: 2.5)
                                            .cornerRadius(1.25)
                                    }
                                }
                                .frame(height: 2.5)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                            }
                        }
                    }
                }
                .onTapGesture {
                    withAnimation { globalPlayerInfo.isOverlayVisible.toggle() }
                }
            } else {
                Color(hex: "08090C")
                Text("Kanal Seçin").foregroundColor(.white.opacity(0.3))
            }
        }
        .clipped()
    }
    
    @State private var activeLiveCategory: String? = nil
    @State private var liveSearchQuery: String = ""

    var liveTVTabContent: some View {
        Group {
            if let cat = activeLiveCategory {
                liveCategoryDetailView(category: cat)
            } else {
                liveTVHomeView
            }
        }
    }
    
    var liveTVHomeView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                // Top Header
                HStack {
                    Text("Canlı TV")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { showAccountsSheet = true; providerSheetState = 0 }) {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 40)
                
                // TV Rehberi Header
                HStack {
                    Text("TV rehberi")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 20)
                
                // TV Rehberi Items
                VStack(spacing: 8) {
                    let topChannels = channels.filter { $0.contentType == "live" }.prefix(4)
                    ForEach(topChannels) { channel in
                        HStack(spacing: 12) {
                            // Logo Box
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(hex: "CE9A67"))
                                    .frame(width: 60, height: 60)
                                if let url = URL(string: channel.logo) {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 40)
                                        }
                                    }
                                }
                            }
                            
                            // Info Box
                            VStack(alignment: .leading, spacing: 4) {
                                Text(channel.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.8))
                                Text(channel.safeGroup)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 60)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(12)
                        }
                        .padding(.horizontal, 20)
                        .onTapGesture { selectedChannel = channel }
                    }
                }
                
                // Categories
                Text("Kategoriler")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                
                let liveGroups = UniqueChannelsCache.getGroups(for: "live", channels: channels)
                
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(liveGroups, id: \.self) { group in
                        Button(action: {
                            withAnimation { activeLiveCategory = group }
                        }) {
                            Text(group)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120) // For Tab bar
            }
        }
        .onAppear {
            if let matched = accounts.first(where: { $0.id.uuidString == activeAccountIdString }) {
                EPGManager.shared.fetchEPG(for: matched)
            }
        }
    }
    
    func liveCategoryDetailView(category: String) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { withAnimation { activeLiveCategory = nil } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                Menu {
                    let liveGroups = Array(Set(channels.filter({ $0.contentType == "live" }).map({ $0.safeGroup }))).sorted()
                    ForEach(liveGroups, id: \.self) { group in
                        Button(group) {
                            withAnimation { activeLiveCategory = group }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(category)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(20)
                }
                
                Spacer()
                
                Color.clear.frame(width: 44, height: 44) // Balance
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.5))
                TextField("", text: $liveSearchQuery, prompt: Text("Arayın").foregroundColor(.white.opacity(0.4)))
                    .foregroundColor(.white)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            // Header times
            HStack {
                Text("Bugün")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                
                let timeFormatter = DateFormatter()
                let _ = timeFormatter.dateFormat = "HH:mm"
                Text(timeFormatter.string(from: Date()))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            
            // Timeline
            epgTimelineGrid(category: category)
        }
        .onAppear {
            if let matched = accounts.first(where: { $0.id.uuidString == activeAccountIdString }) {
                EPGManager.shared.fetchEPG(for: matched)
            }
        }
    }
    
    func epgTimelineGrid(category: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 8) {
                let filteredLive = channels.filter { $0.contentType == "live" && $0.safeGroup == category && (liveSearchQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(liveSearchQuery)) }
                ForEach(filteredLive, id: \.id) { channel in
                    HStack(spacing: 8) {
                        let isSelected = selectedChannel?.url == channel.url
                        
                        // Left Logo Box
                        Button(action: { selectedChannel = channel }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(colorForChannel(channel.name))
                                    .frame(width: 80, height: 64)
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 2))
                                
                                if let url = URL(string: channel.logo), !channel.logo.isEmpty {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fit).frame(width: 50, height: 50)
                                        } else {
                                            Text(channel.name.prefix(2).uppercased()).font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                                        }
                                    }
                                } else {
                                    Text(channel.name.prefix(2).uppercased()).font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                                }
                            }
                        }
                        
                        // Right EPG Box
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                epgProgramBox(
                                    channelName: channel.name,
                                    title: EPGManager.shared.currentProgramName(for: channel),
                                    isActive: true,
                                    isSelected: isSelected,
                                    width: UIScreen.main.bounds.width - 120, // Occupy most space
                                    onPress: { selectedChannel = channel }
                                )
                                
                                let nextTitle = EPGManager.shared.nextProgramName(for: channel)
                                if !nextTitle.isEmpty {
                                    epgProgramBox(
                                        channelName: channel.name,
                                        title: nextTitle,
                                        isActive: false,
                                        isSelected: false,
                                        width: 140,
                                        onPress: { selectedChannel = channel }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 140)
        }
    }
    
    func colorForChannel(_ name: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.8, green: 0.7, blue: 0.2), // Yellowish
            Color(red: 0.6, green: 0.2, blue: 0.3), // Reddish
            Color(red: 0.2, green: 0.5, blue: 0.6), // Bluish
            Color(red: 0.4, green: 0.4, blue: 0.4), // Grayish
            Color(red: 0.9, green: 0.6, blue: 0.2), // Orange
            Color(red: 0.3, green: 0.4, blue: 0.6), // Dark Blue
            Color(red: 0.4, green: 0.6, blue: 0.3), // Green
            Color(red: 0.5, green: 0.2, blue: 0.6)  // Purple
        ]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }

    func epgProgramBox(channelName: String, title: String, isActive: Bool, isSelected: Bool, width: CGFloat, onPress: @escaping () -> Void) -> some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(channelName.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    if isSelected {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                    }
                }
                
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? .black : .white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: width, height: 64, alignment: .leading)
            .background(isSelected ? Color.white : (isActive ? Color.white.opacity(0.2) : Color.white.opacity(0.1)))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
        @State private var activeLibraryCategory: String? = nil
    
    var libraryTabContent: some View {
        Group {
            if let category = activeLibraryCategory {
                libraryCategoryDetailView(category: category)
            } else {
                libraryHomeView
            }
        }
    }
    
    @State private var libraryFilter: String = "Öne çıkanlar" // "Öne çıkanlar", "Filmler", "Diziler"
    
    var libraryHomeView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Top Header
                HStack {
                    Text("Kütüphane")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                
                // Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        libraryPill(title: "Öne çıkanlar", icon: "sparkles", selected: libraryFilter == "Öne çıkanlar")
                        libraryPill(title: "Filmler", icon: "film", selected: libraryFilter == "Filmler")
                        libraryPill(title: "Diziler", icon: "tv", selected: libraryFilter == "Diziler")
                    }
                    .padding(.horizontal, 20)
                }
                
                if libraryFilter == "Öne çıkanlar" {
                    let featuredMovies = getUniqueChannels(type: "movie", limit: 10, reversed: false)
                    if !featuredMovies.isEmpty {
                        libraryHorizontalRankedSection(title: "Öne çıkan filmler", items: featuredMovies)
                    }
                    
                    let featuredSeries = getUniqueChannels(type: "series", limit: 10, reversed: false)
                    if !featuredSeries.isEmpty {
                        libraryHorizontalRankedSection(title: "Öne çıkan diziler", items: featuredSeries)
                    }
                    
                    let recentMovies = getUniqueChannels(type: "movie", limit: 15, reversed: true, sortByRecent: true)
                    
                    if !recentMovies.isEmpty {
                        libraryHorizontalPortraitSection(title: "Son eklenen filmler", items: recentMovies)
                    }
                } else if libraryFilter == "Filmler" {
                    let movieGroups = UniqueChannelsCache.getGroups(for: "movie", channels: channels)
                    libraryCategoryGrid(groups: movieGroups)
                } else if libraryFilter == "Diziler" {
                    let seriesGroups = UniqueChannelsCache.getGroups(for: "series", channels: channels)
                    libraryCategoryGrid(groups: seriesGroups)
                }
                
                Spacer().frame(height: 120)
            }
        }
    }
    
    func libraryPill(title: String, icon: String, selected: Bool) -> some View {
        Button(action: {
            withAnimation { libraryFilter = title }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(selected ? Color(hex: "007FFF") : .white)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(selected ? Color(hex: "007FFF") : .white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(selected ? Color(hex: "007FFF").opacity(0.15) : Color.white.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(selected ? Color(hex: "007FFF").opacity(0.5) : Color.white.opacity(0.2), lineWidth: 1)
            )
            .cornerRadius(20)
        }
    }
    
    func libraryCategoryGrid(groups: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(groups, id: \.self) { group in
                Button(action: {
                    withAnimation { activeLibraryCategory = group }
                }) {
                    Text(group)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(12)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }
    
    func libraryHorizontalRankedSection(title: String, items: [Channel]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, channel in
                        Button(action: {
                            selectedChannel = channel
                        }) {
                            ZStack(alignment: .bottomLeading) {
                                Group {
                                    if !channel.logo.isEmpty, let url = URL(string: channel.logo) {
                                        AsyncImage(url: url) { phase in
                                            if let image = phase.image {
                                                image.resizable().aspectRatio(contentMode: .fill)
                                            } else {
                                                Color.white.opacity(0.1)
                                            }
                                        }
                                    } else {
                                        Color.white.opacity(0.1)
                                    }
                                }
                                .frame(width: 250, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.leading, 30)
                                .padding(.bottom, 45)
                                
                                HStack(alignment: .bottom, spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 70, weight: .heavy))
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.8), radius: 5, x: 2, y: 2)
                                    
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(channel.name)
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text(channel.safeGroup)
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundColor(.white.opacity(0.5))
                                            .lineLimit(1)
                                    }
                                    .padding(.bottom, 12)
                                }
                            }
                            .frame(width: 280, height: 185)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.leading, index == 0 ? 10 : 0)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.top, 10)
    }
    
    func libraryHorizontalPortraitSection(title: String, items: [Channel]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, channel in
                        Button(action: {
                            selectedChannel = channel
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                Group {
                                    if !channel.logo.isEmpty, let url = URL(string: channel.logo) {
                                        AsyncImage(url: url) { phase in
                                            if let image = phase.image {
                                                image.resizable().aspectRatio(contentMode: .fill)
                                            } else {
                                                ZStack {
                                                    Color.white.opacity(0.1)
                                                    Image(systemName: "film")
                                                        .foregroundColor(.white.opacity(0.5))
                                                }
                                            }
                                        }
                                    } else {
                                        ZStack {
                                            Color.white.opacity(0.1)
                                            Image(systemName: "film")
                                                .foregroundColor(.white.opacity(0.5))
                                        }
                                    }
                                }
                                .frame(width: 120, height: 170)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                
                                Text(channel.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .frame(width: 120, alignment: .leading)
                                
                                Text(channel.safeGroup)
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                                    .frame(width: 120, alignment: .leading)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.leading, index == 0 ? 20 : 0)
                        .padding(.trailing, index == items.count - 1 ? 20 : 0)
                    }
                }
            }
        }
        .padding(.top, 10)
    }
    
    @State private var librarySearchQuery: String = ""
    
    func libraryCategoryDetailView(category: String) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { withAnimation { activeLibraryCategory = nil; librarySearchQuery = "" } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .bold))
                        Text("Geri")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(Color(hex: "6D28D9"))
                    .padding(10)
                    .background(Color(hex: "6D28D9").opacity(0.1))
                    .cornerRadius(12)
                }
                Spacer()
                Text(category)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Color.clear.frame(width: 70, height: 44) // Balance
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.5))
                TextField("", text: $librarySearchQuery, prompt: Text("Bu kategoride ara...").foregroundColor(.white.opacity(0.4)))
                    .foregroundColor(.white)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            // Content
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                    let filteredItems = channels.filter { $0.contentType != "live" && $0.safeGroup == category && (librarySearchQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(librarySearchQuery)) }
                    
                    let uniqueFilteredItems: [Channel] = {
                        var seenMovieNames = Set<String>()
                        return filteredItems.filter { item in
                            let cleared = cleanTitle(item.name)
                            if seenMovieNames.contains(cleared) {
                                return false
                            } else {
                                seenMovieNames.insert(cleared)
                                return true
                            }
                        }
                    }()
                    
                    ForEach(uniqueFilteredItems, id: \.id) { channel in
                        Button(action: { selectedChannel = channel }) {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.05))
                                    if let url = URL(string: channel.logo) {
                                        AsyncImage(url: url) { phase in
                                            if let image = phase.image {
                                                image.resizable().aspectRatio(contentMode: .fill).frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 12))
                                            } else {
                                                Image(systemName: "film.fill").foregroundColor(.white.opacity(0.2)).font(.system(size: 30))
                                            }
                                        }
                                    }
                                }
                                .frame(height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                
                                Text(channel.name)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 140)
            }
        }
    }

    var homeTabContent: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if let hero = channels.filter({ $0.contentType == "movie" }).first ?? channels.first {
                        ZStack(alignment: .bottom) {
                            if let url = URL(string: hero.logo) {
                                AsyncImage(url: url) { phase in
                                    if let image = phase.image {
                                        image.resizable().aspectRatio(contentMode: .fill).frame(height: 520).clipped()
                                    } else {
                                        Color.white.opacity(0.05).frame(height: 520)
                                    }
                                }
                            }
                            
                            LinearGradient(colors: [.clear, Color(hex: "08090C")], startPoint: .center, endPoint: .bottom).frame(height: 520)
                            
                            VStack(spacing: 16) {
                                Text(hero.name)
                                    .font(.system(size: 32, weight: .black))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)
                                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                                
                                HStack(spacing: 16) {
                                    Button(action: {
                                        selectedChannel = hero
                                    }) {
                                        HStack {
                                            Image(systemName: "play.fill")
                                            Text("Oynat")
                                        }
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.black)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 14)
                                    .background(Color.white)
                                    .cornerRadius(24)
                                }
                                
                                Button(action: { toggleFavourite(hero.url) }) {
                                    Image(systemName: favourites.contains(hero.url) ? "checkmark" : "plus")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 48, height: 48)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Circle())
                                }
                            }
                        }
                        .padding(.bottom, 40)
                    }
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("Canlı Kanallar")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(channels.filter({ $0.contentType == "live" }).prefix(20)) { channel in
                                Button(action: { selectedChannel = channel; currentTab = .live }) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05))
                                        if let url = URL(string: channel.logo) {
                                            AsyncImage(url: url) { p in
                                                if let i = p.image { i.resizable().scaledToFit().frame(width: 46).cornerRadius(8) }
                                            }
                                        }
                                    }
                                    .frame(width: 90, height: 90)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 20)
                
                homeCategoryRow(title: "Senin İçin Seçilenler", type: "movie")
                homeCategoryRow(title: "Son Eklenenler", type: "series")
                homeCategoryRow(title: "Gündem", type: "live")
                
                Spacer().frame(height: 120)
            }
        }
        .ignoresSafeArea(edges: .top)
        
        // Top Header Overlay
            HStack {
                Text("Ana sayfa")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.8), radius: 2)
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: {
                        // Reload Action
                        if !activeAccountIdString.isEmpty {
                            if let acc = accounts.first(where: { $0.id.uuidString == activeAccountIdString }) {
                                EPGManager.shared.clearCache()
                                if acc.mode == 0 {
                                    fetchM3uDataInSheet(acc.m3uUrl)
                                } else {
                                    fetchXtreamDataInSheet(host: acc.xtreamHost, user: acc.xtreamUser, pass: acc.xtreamPass)
                                }
                            }
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .sexyGlassCircle()
                    }
                    Button(action: {
                        showAccountsSheet = true
                    }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .sexyGlassCircle()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 50)
        }
    }
    
    func homeCategoryRow(title: String, type: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
             Text(title)
                 .font(.system(size: 18, weight: .bold))
                 .foregroundColor(.white)
                 .padding(.horizontal, 20)
                 .padding(.top, 10)
             
             ScrollView(.horizontal, showsIndicators: false) {
                 HStack(spacing: 12) {
                     let items = getUniqueChannels(type: type, limit: 15, reversed: type == "series", sortByRecent: title.localizedCaseInsensitiveContains("son eklenenler") || title.localizedCaseInsensitiveContains("yeni"))
                     ForEach(items) { channel in
                         Button(action: { selectedChannel = channel }) {
                             VStack(alignment: .leading, spacing: 8) {
                                 ZStack {
                                     RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05))
                                     if let url = URL(string: channel.logo) {
                                         AsyncImage(url: url) { p in
                                             if let i = p.image { i.resizable().scaledToFill().frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 12)) }
                                             else { Image(systemName: "film").foregroundColor(.white.opacity(0.3)) }
                                         }
                                     } else {
                                         Image(systemName: "film").foregroundColor(.white.opacity(0.3))
                                     }
                                 }
                                 .frame(width: 120, height: 180)
                                 
                                 Text(channel.name)
                                     .font(.system(size: 11, weight: .semibold))
                                     .foregroundColor(.white.opacity(0.8))
                                     .lineLimit(1)
                                     .frame(width: 120, alignment: .leading)
                             }
                         }
                     }
                 }
                 .padding(.horizontal, 20)
             }
        }
    }

    var searchTabContent: some View {
        VStack(spacing: 0) {
            // Top Category Picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    let modes = [("Tümü", "all"), ("Live TV", "live"), ("Filmler", "movie"), ("Diziler", "series")]
                    ForEach(modes, id: \.1) { mode in
                        let isSelected = contentTypeFilter == mode.1
                        Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { contentTypeFilter = mode.1 } }) {
                            Text(mode.0)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    ZStack {
                                        if isSelected {
                                            Color.white.opacity(0.6)
                                                .opacity(0.3)
                                                .cornerRadius(20)
                                                .matchedGeometryEffect(id: "searchTabGlass", in: glassAnimation)
                                        } else {
                                            Color.white.opacity(0.1)
                                                .cornerRadius(20)
                                        }
                                    }
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 50)
            
            // Search Bar at Top
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.5))
                TextField("", text: $searchQuery, prompt: Text("İçerik ara...").foregroundColor(.white.opacity(0.3)))
                    .foregroundColor(.white)
                    .autocorrectionDisabled()
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .cornerRadius(16)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            if searchQuery.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 64, weight: .light))
                        .foregroundColor(.white.opacity(0.3))
                    Text("Arayın")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
            } else {
                channelsListView()
                    .padding(.bottom, 120) // Extra padding for the tab bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    struct TabButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
    
    var floatingTabBar: some View {
        HStack(spacing: 12) {
            // Main Pill
            HStack(spacing: 0) {
                tabItem(title: "Ana sayfa", icon: "house.fill", tab: .home)
                tabItem(title: "Canlı TV", icon: "antenna.radiowaves.left.and.right", tab: .live)
                tabItem(title: "Kütüphane", icon: "square.stack.3d.up.fill", tab: .library)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .sexyGlass(cornerRadius: 35)
            
            // Search Circle
            tabItem(title: "Ara", icon: "magnifyingglass", tab: .search, isCircle: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    func cleanTitle(_ title: String) -> String {
        UniqueChannelsCache.lock.lock()
        if let cached = UniqueChannelsCache.cleanedTitles[title] {
            UniqueChannelsCache.lock.unlock()
            return cached
        }
        UniqueChannelsCache.lock.unlock()

        var str = title.lowercased()
        
        // Remove text in brackets []
        while let left = str.firstIndex(of: "["), let right = str.firstIndex(of: "]"), left < right {
            str.removeSubrange(left...right)
        }
        
        // Remove text in parentheses ()
        while let left = str.firstIndex(of: "("), let right = str.firstIndex(of: ")"), left < right {
            str.removeSubrange(left...right)
        }
        
        // Replace punctuation/hyphens with space to separate tokens cleanly
        str = str.replacingOccurrences(of: "-", with: " ")
        str = str.replacingOccurrences(of: "_", with: " ")
        str = str.replacingOccurrences(of: ".", with: " ")
        
        // Split title into tokens using non-alphanumeric boundaries
        let tokens = str.components(separatedBy: CharacterSet.alphanumerics.inverted)
        
        let unwantedTags: Set<String> = [
            "1080p", "720p", "4k", "2160p", "uhd", "hd", "sd", "web-dl", "webdl", "bluray", "brrip",
            "tr", "en", "fra", "ger", "dublaj", "alt", "altyazili", "altyazılı", "altyazı", "turkce", "türkçe",
            "dual", "ses", "org", "orjinal", "orj", "filmi", "sinema", "dizisi", "h264", "h265", "hevc", "x264", "x265",
            "3d", "web", "rip", "mkv", "mp4", "avi"
        ]
        
        var filteredTokens = [String]()
        for token in tokens {
            let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanToken.isEmpty { continue }
            if unwantedTags.contains(cleanToken) { continue }
            
            // Exclude 4-digit years (e.g. 1999, 2021)
            if cleanToken.count == 4, let year = Int(cleanToken), year >= 1850 && year <= 2100 {
                continue
            }
            
            // Exclude season patterns: s01, s1, e01, e1, s01e01, etc.
            let isSeasonEpisode = cleanToken.range(of: "^s\\d+$", options: .regularExpression) != nil ||
                                  cleanToken.range(of: "^e\\d+$", options: .regularExpression) != nil ||
                                  cleanToken.range(of: "^s\\d+e\\d+$", options: .regularExpression) != nil ||
                                  cleanToken.range(of: "^yeni$", options: .regularExpression) != nil ||
                                  cleanToken == "seasons" || cleanToken == "season" || cleanToken == "sezon" ||
                                  cleanToken == "bölüm" || cleanToken == "bolum" || cleanToken == "bölümü" || cleanToken == "bolumu" ||
                                  cleanToken == "episode" || cleanToken == "ep" || cleanToken == "part"
            
            if isSeasonEpisode { continue }
            filteredTokens.append(cleanToken)
        }
        
        let finalTitle = filteredTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = finalTitle.isEmpty ? title.lowercased() : finalTitle

        UniqueChannelsCache.lock.lock()
        UniqueChannelsCache.cleanedTitles[title] = resolvedTitle
        UniqueChannelsCache.lock.unlock()

        return resolvedTitle
    }

    func getUniqueChannels(type: String, limit: Int, reversed: Bool, sortByRecent: Bool = false) -> [Channel] {
        let cacheKey = "\(type)_\(limit)_\(reversed)_\(sortByRecent)_\(channels.count)"
        
        UniqueChannelsCache.lock.lock()
        if let cached = UniqueChannelsCache.cache[cacheKey] {
            UniqueChannelsCache.lock.unlock()
            return cached
        }
        UniqueChannelsCache.lock.unlock()

        var list = [Channel]()
        var seenNames = Set<String>()
        var seenUrls = Set<String>()
        var filtered = channels.filter { $0.contentType == type }
        
        if sortByRecent {
            let hasAddedTimestamps = filtered.contains { ($0.added ?? 0) > 0 }
            if hasAddedTimestamps {
                filtered.sort { ($0.added ?? 0) > ($1.added ?? 0) }
            } else {
                filtered = filtered.reversed()
            }
        } else if reversed {
            filtered = filtered.reversed()
        }
        
        for ch in filtered {
            let clearedName = cleanTitle(ch.name)
            let normalizedUrl = ch.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !seenNames.contains(clearedName) && !seenUrls.contains(normalizedUrl) {
                seenNames.insert(clearedName)
                seenUrls.insert(normalizedUrl)
                list.append(ch)
            }
            if list.count >= limit { break }
        }

        UniqueChannelsCache.lock.lock()
        UniqueChannelsCache.cache[cacheKey] = list
        UniqueChannelsCache.lock.unlock()

        return list
    }

    func tabItem(title: String, icon: String, tab: AppTab, isCircle: Bool = false) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                if currentTab == tab {
                    // Reset tab state if already active
                    if tab == .live { activeLiveCategory = nil }
                    if tab == .library { selectedCategory = "Tümü"; librarySearchQuery = "" }
                } else {
                    currentTab = tab
                }
            }
        }) {
            if isCircle {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 58, height: 58)
                    .sexyGlassCircle()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: currentTab == tab ? .bold : .medium))
                        .foregroundColor(currentTab == tab ? .white : .white.opacity(0.6))
                    
                    Text(title)
                        .font(.system(size: 10, weight: currentTab == tab ? .bold : .medium))
                        .foregroundColor(currentTab == tab ? .white : .white.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    Group {
                        if currentTab == tab {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color.white.opacity(0.2))
                                .matchedGeometryEffect(id: "navGlass", in: glassAnimation)
                        } else {
                            Color.clear
                        }
                    }
                )
            }
        }
        .buttonStyle(TabButtonStyle())
    }
    
    var landscapeFilteredChannels: [Channel] {
        let currentType = selectedChannel?.contentType ?? "live"
        var list = channels.filter { $0.contentType == currentType }
        
        if selectedLandscapeGroup != "Tümü" && !selectedLandscapeGroup.isEmpty {
            list = list.filter { $0.safeGroup == selectedLandscapeGroup }
        }
        
        if !landscapeSearchQuery.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(landscapeSearchQuery) }
        }
        return list
    }

    var landscapePlayerView: some View {
        ZStack {
            if let channel = selectedChannel {
                // 1. Core Native Player
                NativeVideoPlayerView(urlString: channel.url, videoContentMode: playerContentMode, infoManager: globalPlayerInfo, showsPlaybackControls: false)
                    .ignoresSafeArea()
                
                // 2 & 3. Base Tap-to-toggle overlay & Swipe Gestures (Brightness/Volume)
                GeometryReader { geo in
                    Color.black.opacity(0.005)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation {
                                showingControls.toggle()
                            }
                            if showingControls {
                                resetTimer()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    if showLandscapeChannelList || showLandscapeSettings { return }
                                    
                                    let isLeft = value.startLocation.x < geo.size.width / 2
                                    
                                    if isLeft {
                                        if !showBrightnessPill {
                                            dragStartBrightness = brightnessLevel
                                            withAnimation {
                                                showBrightnessPill = true
                                                showingControls = true
                                            }
                                        }
                                        resetTimer()
                                        let delta = value.translation.height / -250.0
                                        brightnessLevel = max(0.0, min(1.0, dragStartBrightness + delta))
                                        UIScreen.main.brightness = brightnessLevel
                                    } else {
                                        if !showVolumePill {
                                            dragStartVolume = volumeLevel
                                            withAnimation {
                                                showVolumePill = true
                                                showingControls = true
                                            }
                                        }
                                        resetTimer()
                                        let delta = value.translation.height / -250.0
                                        volumeLevel = max(0.0, min(1.0, dragStartVolume + delta))
                                    }
                                }
                                .onEnded { value in
                                    let isLeft = value.startLocation.x < geo.size.width / 2
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        withAnimation {
                                            if isLeft { showBrightnessPill = false }
                                            else { showVolumePill = false }
                                        }
                                    }
                                }
                        )
                }
                .zIndex(15)
                
                // 4. Vertical Sliding Indicators (Left: Brightness, Right: Volume)
                HStack {
                    // Left: Brightness
                    if showBrightnessPill || showingControls {
                        VStack(spacing: 12) {
                            Image(systemName: "sun.max.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 15, weight: .bold))
                            
                            GeometryReader { innerGeo in
                                ZStack(alignment: .bottom) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.12))
                                    Capsule()
                                        .fill(Color(hex: "007FFF"))
                                        .frame(height: innerGeo.size.height * brightnessLevel)
                                }
                            }
                            .frame(width: 6, height: 140)
                            
                            Text("\(Int(brightnessLevel * 100))%")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.vertical, 16)
                        .padding(.horizontal, 10)
                        .sexyGlass(cornerRadius: 20)
                        .padding(.leading, 30)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    
                    Spacer()
                    
                    // Right: Volume
                    if showVolumePill || showingControls {
                        VStack(spacing: 12) {
                            Image(systemName: volumeLevel > 0.5 ? "speaker.wave.3.fill" : (volumeLevel > 0 ? "speaker.wave.1.fill" : "speaker.slash.fill"))
                                .foregroundColor(.white)
                                .font(.system(size: 15, weight: .bold))
                            
                            GeometryReader { innerGeo in
                                ZStack(alignment: .bottom) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.12))
                                    Capsule()
                                        .fill(Color(hex: "007FFF"))
                                        .frame(height: innerGeo.size.height * volumeLevel)
                                }
                            }
                            .frame(width: 6, height: 140)
                            
                            Text("\(Int(volumeLevel * 100))%")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.vertical, 16)
                        .padding(.horizontal, 10)
                        .sexyGlass(cornerRadius: 20)
                        .padding(.trailing, 30)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .zIndex(50)
                
                // 5. Controls Overlay (Top section, Center section, Bottom section)
                if showingControls {
                    LinearGradient(
                        gradient: Gradient(colors: [Color.black.opacity(0.6), Color.clear, Color.black.opacity(0.8)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false) // Let touches pass through to gesture overlay
                    .zIndex(90)
                    
                    VStack {
                        // Top Section (Top bar buttons & resolution info)
                        HStack {
                            HStack(spacing: 12) {
                                Button(action: {
                                    showLandscapeChannelList = false
                                    showLandscapeSettings = false
                                    isLandscape = false
                                }) {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 44, height: 44)
                                        .background(.ultraThinMaterial)
                                        .environment(\.colorScheme, .dark)
                                        .clipShape(Circle())
                                }
                                
                                Button(action: {
                                    showLandscapeChannelList = false
                                    showLandscapeSettings = false
                                    closeSelectedChannel()
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.red)
                                        .frame(width: 44, height: 44)
                                        .background(.ultraThinMaterial)
                                        .environment(\.colorScheme, .dark)
                                        .clipShape(Circle())
                                }
                                
                                Button(action: { cycleAspect() }) {
                                    Image(systemName: "aspectratio")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 44, height: 44)
                                        .background(.ultraThinMaterial)
                                        .environment(\.colorScheme, .dark)
                                        .clipShape(Circle())
                                }
                            }
                            
                            Spacer()
                            
                            // Top Right: Active stable resolution
                            HStack(spacing: 6) {
                                Image(systemName: "bolt.horizontal.fill")
                                    .foregroundColor(Color(hex: "007FFF"))
                                Text(globalPlayerInfo.resolutionString)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                            .cornerRadius(8)
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 24)
                        
                        Spacer()
                        
                        // Center Section (Play / Pause button)
                        HStack {
                            Button(action: {
                                globalPlayerInfo.togglePlayPause()
                                resetTimer()
                            }) {
                                Image(systemName: globalPlayerInfo.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 38, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 74, height: 74)
                                    .background(.ultraThinMaterial)
                                    .environment(\.colorScheme, .dark)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                            }
                        }
                        
                        Spacer()
                        
                        // Bottom Section (Active TV information + action options)
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                // Live Badge
                                HStack(spacing: 4) {
                                    Circle().fill(Color.red).frame(width: 6, height: 6)
                                    Text("CANLI")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundColor(.red)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(4)
                                
                                Text(channel.name)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                
                                Text(channel.safeGroup)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            // Bottom Action Options (Settings, Toggle Favourite, Channel Selector)
                            HStack(spacing: 12) {
                                Button(action: {
                                    withAnimation {
                                        showLandscapeSettings.toggle()
                                        showLandscapeChannelList = false
                                    }
                                    resetTimer()
                                }) {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(showLandscapeSettings ? Color(hex: "007FFF") : .white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.45))
                                        .clipShape(Circle())
                                }
                                
                                Button(action: {
                                    toggleFavourite(channel.url)
                                    resetTimer()
                                }) {
                                    Image(systemName: favourites.contains(channel.url) ? "bookmark.fill" : "bookmark")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(favourites.contains(channel.url) ? .yellow : .white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.45))
                                        .clipShape(Circle())
                                }
                                
                                Button(action: {
                                    withAnimation {
                                        showLandscapeChannelList.toggle()
                                        showLandscapeSettings = false
                                        selectedLandscapeGroup = channel.safeGroup // auto select current group!
                                    }
                                    resetTimer()
                                }) {
                                    Image(systemName: "list.bullet")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(showLandscapeChannelList ? Color(hex: "007FFF") : .white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.45))
                                        .clipShape(Circle())
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                        .padding(.bottom, 24)
                    }
                    .zIndex(100)
                }
                
                // 6. Sliding Channels Drawer Sidebar (Glassmorphic)
                if showLandscapeChannelList {
                    HStack(spacing: 0) {
                        Spacer()
                        
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Kanallar")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                Spacer()
                                Button(action: {
                                    withAnimation {
                                        showLandscapeChannelList = false
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            
                            // Category picker list of group pills
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    Button(action: {
                                        selectedLandscapeGroup = "Tümü"
                                        resetTimer()
                                    }) {
                                        Text("Tümü")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(selectedLandscapeGroup == "Tümü" ? .white : .white.opacity(0.6))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(selectedLandscapeGroup == "Tümü" ? Color(hex: "007FFF") : Color.white.opacity(0.08))
                                            .cornerRadius(12)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    
                                    let currentType = selectedChannel?.contentType ?? "live"
                                    let landscapeGroups = Array(Set(channels.filter { $0.contentType == currentType }.map { $0.safeGroup })).sorted()
                                    
                                    ForEach(landscapeGroups, id: \.self) { grp in
                                        Button(action: {
                                            selectedLandscapeGroup = grp
                                            resetTimer()
                                        }) {
                                            Text(grp)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(selectedLandscapeGroup == grp ? .white : .white.opacity(0.6))
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(selectedLandscapeGroup == grp ? Color(hex: "007FFF") : Color.white.opacity(0.08))
                                                .cornerRadius(12)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.white.opacity(0.4))
                                TextField("", text: $landscapeSearchQuery, prompt: Text("Ara...").foregroundColor(.white.opacity(0.3)))
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .foregroundColor(.white)
                                    .font(.system(size: 14))
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(10)
                            .padding(.horizontal, 16)
                            
                            ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(spacing: 8) {
                                        ForEach(landscapeFilteredChannels, id: \.self) { ch in
                                            Button(action: {
                                                selectedChannel = ch
                                                resetTimer()
                                            }) {
                                                HStack(spacing: 12) {
                                                    if !ch.logo.isEmpty, let url = URL(string: ch.logo) {
                                                        AsyncImage(url: url) { phase in
                                                            if let img = phase.image {
                                                                img.resizable().scaledToFit()
                                                            } else {
                                                                Image(systemName: ch.contentType == "live" ? "antenna.radiowaves.left.and.right" : "film")
                                                                    .foregroundColor(.white.opacity(0.3))
                                                            }
                                                        }
                                                        .frame(width: 32, height: 32)
                                                        .cornerRadius(4)
                                                    } else {
                                                        Image(systemName: ch.contentType == "live" ? "antenna.radiowaves.left.and.right" : "film")
                                                            .foregroundColor(.white.opacity(0.3))
                                                            .frame(width: 32, height: 32)
                                                    }
                                                    
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(ch.name)
                                                            .font(.system(size: 13, weight: .semibold))
                                                            .foregroundColor(selectedChannel?.url == ch.url ? Color(hex: "007FFF") : .white)
                                                            .lineLimit(1)
                                                            .multilineTextAlignment(.leading)
                                                        
                                                        Text(ch.safeGroup)
                                                            .font(.system(size: 10))
                                                            .foregroundColor(.white.opacity(0.4))
                                                            .lineLimit(1)
                                                            .multilineTextAlignment(.leading)
                                                    }
                                                    Spacer()
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(selectedChannel?.url == ch.url ? Color.white.opacity(0.08) : Color.clear)
                                                .cornerRadius(8)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                            .id(ch.url)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                                .onAppear {
                                    if let selected = selectedChannel {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            withAnimation {
                                                proxy.scrollTo(selected.url, anchor: .center)
                                            }
                                        }
                                    }
                                }
                                .onChange(of: selectedLandscapeGroup) { _ in
                                    if let selected = selectedChannel {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            withAnimation {
                                                proxy.scrollTo(selected.url, anchor: .center)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: 300)
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .transition(.move(edge: .trailing))
                    }
                    .zIndex(1000)
                }
                
                // 7. Sliding Settings Drawer Sidebar (Glassmorphic)
                if showLandscapeSettings {
                    HStack(spacing: 0) {
                        Spacer()
                        
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Yayın Ayarları")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                Spacer()
                                Button(action: {
                                    withAnimation {
                                        showLandscapeSettings = false
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    // Aspect ratios
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Ekran Boyutu")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.white.opacity(0.6))
                                        
                                        ForEach([UIView.ContentMode.scaleAspectFit, UIView.ContentMode.scaleAspectFill, UIView.ContentMode.scaleToFill], id: \.self) { mode in
                                            Button(action: {
                                                playerContentMode = mode
                                                resetTimer()
                                            }) {
                                                HStack {
                                                    Text(mode == .scaleAspectFit ? "Sığdır (Fit)" : (mode == .scaleAspectFill ? "Doldur (Fill)" : "Yay (Stretch)"))
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(.white)
                                                    Spacer()
                                                    if playerContentMode == mode {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .foregroundColor(Color(hex: "007FFF"))
                                                    }
                                                }
                                                .padding(12)
                                                .background(Color.white.opacity(playerContentMode == mode ? 0.12 : 0.04))
                                                .cornerRadius(8)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    
                                    // Connection Details info block
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Yayın Bilgileri")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.white.opacity(0.6))
                                        
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Text("Yayın Adı")
                                                    .foregroundColor(.white.opacity(0.4))
                                                Spacer()
                                                Text(channel.name)
                                                    .foregroundColor(.white)
                                                    .font(.system(size: 12, weight: .bold))
                                            }
                                            HStack {
                                                Text("Grup")
                                                    .foregroundColor(.white.opacity(0.4))
                                                Spacer()
                                                Text(channel.safeGroup)
                                                    .foregroundColor(.white)
                                            }
                                            HStack {
                                                Text("Çözünürlük")
                                                    .foregroundColor(.white.opacity(0.4))
                                                Spacer()
                                                Text(globalPlayerInfo.resolutionString)
                                                    .foregroundColor(.green)
                                            }
                                        }
                                        .font(.system(size: 11, design: .monospaced))
                                        .padding(12)
                                        .background(Color.white.opacity(0.04))
                                        .cornerRadius(8)
                                    }
                                    .padding(.horizontal, 16)
                                    
                                    // Refresh Stream Button
                                    Button(action: {
                                        let oldChan = channel
                                        selectedChannel = nil
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            selectedChannel = oldChan
                                        }
                                        showLandscapeSettings = false
                                        resetTimer()
                                    }) {
                                        HStack {
                                            Image(systemName: "arrow.clockwise")
                                            Text("Yayını Yeniden Başlat")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(Color.orange.opacity(0.2))
                                        .cornerRadius(8)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.5), lineWidth: 1))
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                        .frame(width: 300)
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .transition(.move(edge: .trailing))
                    }
                    .zIndex(1000)
                }
            } else {
                Color.black
                Text("Yatay tam ekran modunu kullanmak için lütfen önce bir yayın seçin.")
                    .foregroundColor(.white.opacity(0.5))
                    .padding()
            }
        }
        .onAppear {
            showingControls = true
            resetTimer()
            brightnessLevel = UIScreen.main.brightness
            volumeLevel = CGFloat(AVAudioSession.sharedInstance().outputVolume)
        }
        .onDisappear {
            controlsTimer?.invalidate()
        }
    }
    
    private func resetTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation {
                showingControls = false
            }
        }
    }
    
    // MARK: - Header Bar Section
    var headerBarSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(iptvMode == 0 ? "M3U PLAYLIST" : "XTREAM CODES API")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(Color(hex: "6D28D9"))
                Text("IPTV PRO")
                    .font(.system(size: 22, weight: .black))
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                // List Accounts Drawer Trigger
                Button(action: { showAccountsSheet = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                        Text("Listelerim (\(accounts.count))")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
                
                if channels.isEmpty {
                    Button(action: {
                        openSettings()
                        showAccountsSheet = true; providerSheetState = 0
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Yükle")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(hex: "6D28D9"))
                        .cornerRadius(10)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Button(action: {
                        openSettings()
                        showAccountsSheet = true; providerSheetState = 0
                    }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.white.opacity(0.7))
                            .font(.system(size: 15))
                            .padding(9)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }
    
    // MARK: - Welcome / Onboarding Area
    var welcomeOnboardingArea: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "tv.badge.wifi.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: "6D28D9"), Color(hex: "007FFF")], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: Color(hex: "6D28D9").opacity(0.25), radius: 12)
            
            VStack(spacing: 8) {
                Text("IPTV Dünyasına Hoş Geldiniz")
                    .font(.system(size: 20, weight: .black))
                    .foregroundColor(.white)
                
                Text("M3U formatında oynatma listesi URL'nizi veya Xtream Codes API hesap bilgilerinizi girerek canlı tv, sinema ve dizileri izlemeye başlayın.")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Button(action: {
                openSettings()
                showAccountsSheet = true; providerSheetState = 0
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                    Text("GİRİŞ YAP / YÜKLE")
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(colors: [Color(hex: "6D28D9"), Color(hex: "00EFFF")], startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(14)
                .shadow(color: Color(hex: "6D28D9").opacity(0.3), radius: 8)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 10)
            
            Spacer()
        }
    }
    
    // MARK: - Unified Lists, Search, Tabs & Items Display Section
    var typeTabsView: some View {
        HStack(spacing: 4) {
            typeTabButton(title: "Canlı TV", icon: "tv.fill", tag: "live")
            typeTabButton(title: "Filmler", icon: "film.fill", tag: "movie")
            typeTabButton(title: "Diziler", icon: "popcorn.fill", tag: "series")
        }
        .padding(4)
        .background(Color(hex: "121420"))
        .cornerRadius(12)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
    
    var searchBarView: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.4))
            TextField("", text: $searchQuery, prompt: Text(placeholderText).foregroundColor(.white.opacity(0.3)))
                .foregroundColor(.white)
                .autocorrectionDisabled()
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(12)
        .background(Color(hex: "11131E"))
        .cornerRadius(12)
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    var filterButtonsView: some View {
        HStack(spacing: 12) {
            Button(action: {
                categorySearchQuery = ""
                showCategorySheet = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "6D28D9"))
                    Text(selectedCategory == "Tümü" ? "Kategori Seç (\(categories.count))" : selectedCategory)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
            
            if !favourites.isEmpty {
                Button(action: {
                    withAnimation {
                        if selectedCategory == "Favoriler" {
                            selectedCategory = "Tümü"
                        } else {
                            selectedCategory = "Favoriler"
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: selectedCategory == "Favoriler" ? "star.fill" : "star")
                            .foregroundColor(.yellow)
                        Text("Favoriler")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(selectedCategory == "Favoriler" ? Color.yellow.opacity(0.12) : Color.white.opacity(0.04))
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    var statesAndListView: some View {
        if let error = errorMessage {
            errorView(error: error)
        } else if isLoading {
            loadingView()
        } else if filteredChannels.isEmpty {
            emptyView()
        } else {
            channelsListView()
        }
    }
    
    func errorView(error: String) -> some View {
        VStack(spacing: 6) {
            Text("Bağlantı Hatası!")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.red)
            Text(error)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
    
    func loadingView() -> some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "6D28D9"))).scaleEffect(1.2)
                Text(loadingMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
    }
    
    func initializingView() -> some View {
        VStack(spacing: 24) {
            Spacer()
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            
            Text("İçerikler Hazırlanıyor...")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "08090C").ignoresSafeArea())
    }
    
    func emptyView() -> some View {
        VStack {
            Spacer()
            
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(hex: "6D28D9"), Color(hex: "007FFF")], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 90, height: 90)
                        .blur(radius: 12)
                        .opacity(0.5)
                    
                    Image(systemName: "tv.slash.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(.white)
                }
                
                VStack(spacing: 8) {
                    Text("Kütüphaneniz Boş")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("İçerikleri görebilmek için lütfen bir IPTV sağlayıcısı ekleyin.")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                
                Button(action: {
                    showAccountsSheet = true
                    providerSheetState = 0
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Sağlayıcı Ekle")
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .sexyGlass(cornerRadius: 22)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 10)
            }
            .padding(.vertical, 32)
            .padding(.horizontal, 20)
            
            Spacer()
            Spacer().frame(height: 120) // Bottom Tabbar overlap safety
        }
    }
    
    func channelsListView() -> some View {
        List {
            ForEach(filteredChannels) { channel in
                ChannelRowView(
                    channel: channel,
                    isSelected: selectedChannel?.url == channel.url,
                    isFavorite: favourites.contains(channel.url),
                    onTapFavorite: { toggleFavourite(channel.url) },
                    onTapChannel: { selectedChannel = channel }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(PlainListStyle())
        .background(Color.clear)
    }

    var listsFilterAndItemsSection: some View {
        VStack(spacing: 0) {
            typeTabsView
            searchBarView
            filterButtonsView
            statesAndListView
        }
    }
    
    func placeholderIcon(for contentType: String) -> some View {
        Image(systemName: contentType == "live" ? "tv.fill" : (contentType == "movie" ? "film.fill" : "play.rectangle.fill"))
            .foregroundColor(Color(hex: "6D28D9"))
            .font(.system(size: 15))
    }
    
    // Toggle primary navigation filter buttons
    func typeTabButton(title: String, icon: String, tag: String) -> some View {
        let isSelected = contentTypeFilter == tag
        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                contentTypeFilter = tag
                selectedCategory = "Tümü"
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(isSelected ? .white : Color.white.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    if isSelected {
                        Color.white.opacity(0.6)
                            .opacity(0.3)
                            .cornerRadius(8)
                            .matchedGeometryEffect(id: "typeTabGlass", in: glassAnimation)
                    }
                }
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    var placeholderText: String {
        switch contentTypeFilter {
        case "live": return "Canlı kanal ara..."
        case "movie": return "Sinema filmi ara..."
        default: return "Dizi / Sezon ara..."
        }
    }
    
    // MARK: - Dynamic Filter Categorization
    var categories: [String] {
        let matched = channels.filter { $0.contentType == contentTypeFilter }
        let groups = Set(matched.map { $0.safeGroup })
        return Array(groups).sorted()
    }
    
    var filteredChannels: [Channel] {
        var baseList = channels
        
        // Match active section filter
        if currentTab == .search {
            if contentTypeFilter != "all" {
                baseList = baseList.filter { $0.contentType == contentTypeFilter }
            }
            if !searchQuery.isEmpty {
                let key = searchQuery.lowercased()
                baseList = baseList.filter {
                    $0.name.lowercased().contains(key) || $0.safeGroup.lowercased().contains(key)
                }
            }
            return baseList
        }
        
        if selectedCategory != "Favoriler" {
            if contentTypeFilter != "all" {
                baseList = baseList.filter { $0.contentType == contentTypeFilter }
            }
        }
        
        // Category selection filter
        if selectedCategory == "Favoriler" {
            baseList = baseList.filter { favourites.contains($0.url) }
        } else if selectedCategory != "Tümü" {
            baseList = baseList.filter { $0.safeGroup == selectedCategory }
        }
        
        // Search query keywords helper
        if !searchQuery.isEmpty {
            let key = searchQuery.lowercased()
            baseList = baseList.filter {
                $0.name.lowercased().contains(key) || $0.safeGroup.lowercased().contains(key)
            }
        }
        
        return baseList
    }
    
    // Computed stream statistics
    var liveCount: Int { channels.filter { $0.contentType == "live" }.count }
    var movieCount: Int { channels.filter { $0.contentType == "movie" }.count }
    var seriesCount: Int { channels.filter { $0.contentType == "series" }.count }
    
    // MARK: - Local File Directory Path Helpers
    func getM3uFilePath() -> URL {
        let suffix = activeAccountIdString.isEmpty ? "" : "_\(activeAccountIdString)"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("saved_playlist\(suffix).m3u")
    }
    
    func getXtreamFilePath() -> URL {
        let suffix = activeAccountIdString.isEmpty ? "" : "_\(activeAccountIdString)"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("xtream_cache\(suffix).json")
    }
    
    // MARK: - Audio Session Control
    func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure AVAudioSession category: \(error)")
        }
    }
    
    // MARK: - Playback Favourites Engine
    func loadFavourites() {
        if let data = UserDefaults.standard.stringArray(forKey: "fav_playlist") {
            favourites = Set(data)
        }
    }
    
    func toggleFavourite(_ url: String) {
        if favourites.contains(url) {
            favourites.remove(url)
        } else {
            favourites.insert(url)
        }
        UserDefaults.standard.set(Array(favourites), forKey: "fav_playlist")
    }
    
    func closeSelectedChannel() {
        globalPlayerInfo.stop()
        selectedChannel = nil
        isLandscape = false
        showLandscapeChannelList = false
        showLandscapeSettings = false
    }
    
    // MARK: - Authentication Logouts
    func logoutAccount() {
        channels = []
        selectedChannel = nil
        m3uUrl = ""
        xtreamHost = ""
        xtreamUser = ""
        xtreamPass = ""
        
        serverExpiry = ""
        serverActiveCons = ""
        serverMaxCons = ""
        serverStatus = ""
        
        // Clear localized files
        try? FileManager.default.removeItem(at: getM3uFilePath())
        try? FileManager.default.removeItem(at: getXtreamFilePath())
    }
    
    // MARK: - M3U Credentials Extractor
    func extractXtreamCredentials(from m3uUrlString: String) -> (host: String, user: String, pass: String)? {
        let clean = m3uUrlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean) else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        
        var username: String? = nil
        var password: String? = nil
        
        if let queryItems = components.queryItems {
            for item in queryItems {
                let name = item.name.lowercased()
                if name == "username" || name == "user" {
                    username = item.value
                } else if name == "password" || name == "pass" {
                    password = item.value
                }
            }
        }
        
        if username == nil || password == nil {
            let pathComponents = components.path.components(separatedBy: "/")
            if pathComponents.count >= 4 {
                username = pathComponents[2]
                password = pathComponents[3]
            }
        }
        
        guard let user = username, let pass = password else { return nil }
        
        var host = ""
        if let scheme = components.scheme {
            host += "\(scheme)://"
        } else {
            host += "http://"
        }
        if let hostName = components.host {
            host += hostName
        }
        if let port = components.port {
            host += ":\(port)"
        }
        
        return (host: host, user: user, pass: pass)
    }
    
    // MARK: - Dedicated Server Subscription Fetcher
    func fetchServerInfo(host: String, user: String, pass: String) {
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanHost.hasPrefix("http://") && !cleanHost.hasPrefix("https://") {
            cleanHost = "http://\(cleanHost)"
        }
        if cleanHost.hasSuffix("/") {
            cleanHost.removeLast()
        }
        
        guard let apiUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)") else { return }
        
        var request = URLRequest(url: apiUrl)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else { return }
            
            if let loginResponse = try? JSONDecoder().decode(XtreamLoginResponse.self, from: data),
               let info = loginResponse.user_info {
                DispatchQueue.main.async {
                    self.serverStatus = info.status ?? "Aktif"
                    
                    if let exp = info.exp_date {
                        let expVal = exp.intValue
                        if expVal == 0 {
                            self.serverExpiry = "Sınırsız"
                        } else {
                            let date = Date(timeIntervalSince1970: TimeInterval(expVal))
                            let formatter = DateFormatter()
                            formatter.dateFormat = "dd.MM.yyyy"
                            self.serverExpiry = formatter.string(from: date)
                        }
                    } else {
                        self.serverExpiry = "Bilinmiyor"
                    }
                    
                    self.serverActiveCons = info.active_cons?.stringValue ?? "0"
                    self.serverMaxCons = info.max_connections?.stringValue ?? "1"
                    
                    // Update Account metadata
                    if let idx = self.accounts.firstIndex(where: { $0.xtreamHost == cleanHost && $0.xtreamUser == user }) {
                        self.accounts[idx].status = self.serverStatus
                        self.accounts[idx].expDate = self.serverExpiry
                        self.accounts[idx].activeConnections = self.serverActiveCons
                        self.accounts[idx].maxConnections = self.serverMaxCons
                        self.saveAccounts()
                    }
                }
            }
        }.resume()
    }
    
    // MARK: - Video Aspect Ratio Helpers
    private func cycleAspect() {
        if playerContentMode == .scaleAspectFit {
            playerContentMode = .scaleAspectFill
        } else if playerContentMode == .scaleAspectFill {
            playerContentMode = .scaleToFill
        } else {
            playerContentMode = .scaleAspectFit
        }
    }
    
    private var aspectTitle: String {
        switch playerContentMode {
        case .scaleAspectFit: return "Sığdır"
        case .scaleAspectFill: return "Zoom"
        case .scaleToFill: return "16:9"
        default: return "Sığdır"
        }
    }
    
    private var aspectIcon: String {
        switch playerContentMode {
        case .scaleAspectFit: return "arrow.up.left.and.arrow.down.right"
        case .scaleAspectFill: return "arrow.up.left.and.down.right.magnifyingglass"
        case .scaleToFill: return "arrow.left.and.right"
        default: return "arrow.up.left.and.arrow.down.right"
        }
    }
    
    // MARK: - Local Data Lifecycles
    func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: "dion_accounts_list")
        }
    }
    
    func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: "dion_accounts_list"),
           let decoded = try? JSONDecoder().decode([IPTVAccount].self, from: data) {
            self.accounts = decoded
        } else {
            // Migrate old single list to accounts
            if !m3uUrl.isEmpty {
                let name = URL(string: m3uUrl)?.host ?? "M3U Playlist"
                let newAcc = IPTVAccount(name: name, mode: 0, m3uUrl: m3uUrl)
                self.accounts = [newAcc]
                self.activeAccountIdString = newAcc.id.uuidString
                saveAccounts()
            } else if !xtreamHost.isEmpty {
                let name = "\(xtreamUser)@\(URL(string: xtreamHost)?.host ?? xtreamHost)"
                let newAcc = IPTVAccount(name: name, mode: 1, xtreamHost: xtreamHost, xtreamUser: xtreamUser, xtreamPass: xtreamPass)
                self.accounts = [newAcc]
                self.activeAccountIdString = newAcc.id.uuidString
                saveAccounts()
            }
        }
    }
    
    func switchAccount(to account: IPTVAccount) {
        selectedChannel = nil
        activeAccountIdString = account.id.uuidString
        iptvMode = account.mode
        
        UniqueChannelsCache.clear()
        // EPGManager.shared.fetchEPG(for: account)
        
        if account.mode == 0 {
            self.m3uUrl = account.m3uUrl
        } else {
            self.xtreamHost = account.xtreamHost
            self.xtreamUser = account.xtreamUser
            self.xtreamPass = account.xtreamPass
        }
        
        self.channels = []
        loadSavedData()
        
        if self.channels.isEmpty {
            if account.mode == 0 {
                fetchM3uData(account.m3uUrl)
            } else {
                fetchXtreamData(host: account.xtreamHost, user: account.xtreamUser, pass: account.xtreamPass)
            }
        }
    }
    
    func loadSavedData() {
        self.errorMessage = nil
        
        if accounts.isEmpty {
            isInitializingChannels = false
        }
        
        if activeAccountIdString.isEmpty {
            if let first = accounts.first {
                activeAccountIdString = first.id.uuidString
                iptvMode = first.mode
                if first.mode == 0 {
                    m3uUrl = first.m3uUrl
                } else {
                    xtreamHost = first.xtreamHost
                    xtreamUser = first.xtreamUser
                    xtreamPass = first.xtreamPass
                }
                // EPGManager.shared.fetchEPG(for: first)
            }
        } else {
            if let matched = accounts.first(where: { $0.id.uuidString == activeAccountIdString }) {
                iptvMode = matched.mode
                if matched.mode == 0 {
                    m3uUrl = matched.m3uUrl
                } else {
                    xtreamHost = matched.xtreamHost
                    xtreamUser = matched.xtreamUser
                    xtreamPass = matched.xtreamPass
                }
                // EPGManager.shared.fetchEPG(for: matched)
            }
        }
        
        if iptvMode == 0 {
            // Check M3U Cache
            if let text = try? String(contentsOf: getM3uFilePath(), encoding: .utf8) {
                parseM3UContentSilent(text)
            } else if !m3uUrl.isEmpty {
                fetchM3uData(m3uUrl)
            } else {
                isInitializingChannels = false
            }
            
            if !m3uUrl.isEmpty {
                if let creds = extractXtreamCredentials(from: m3uUrl) {
                    fetchServerInfo(host: creds.host, user: creds.user, pass: creds.pass)
                } else {
                    serverExpiry = "M3U Bağlantısı"
                    serverActiveCons = "N/A"
                    serverMaxCons = "N/A"
                    serverStatus = "Aktif"
                }
            } else {
                serverExpiry = ""
                serverActiveCons = ""
                serverMaxCons = ""
                serverStatus = ""
            }
        } else {
            // Check Xtream Cache JSON
            if let data = try? Data(contentsOf: getXtreamFilePath()),
               let cached = try? JSONDecoder().decode([Channel].self, from: data) {
                self.channels = cached
                isInitializingChannels = false
            } else if !xtreamHost.isEmpty {
                fetchXtreamData(host: xtreamHost, user: xtreamUser, pass: xtreamPass)
            } else {
                isInitializingChannels = false
            }
            
            if !xtreamHost.isEmpty && !xtreamUser.isEmpty && !xtreamPass.isEmpty {
                fetchServerInfo(host: xtreamHost, user: xtreamUser, pass: xtreamPass)
            } else {
                serverExpiry = ""
                serverActiveCons = ""
                serverMaxCons = ""
                serverStatus = ""
            }
        }
    }
    
    func openSettings() {
        tempM3uUrl = m3uUrl
        tempXtreamHost = xtreamHost
        tempXtreamUser = xtreamUser
        tempXtreamPass = xtreamPass
        sheetError = nil
        sheetIsLoading = false
    }
    
    // MARK: - Fetch & Parse M3U Engine
    func fetchM3uData(_ urlString: String) {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data, let text = String(data: data, encoding: .utf8) else { return }
            
            try? text.write(to: getM3uFilePath(), atomically: true, encoding: .utf8)
            
            DispatchQueue.main.async {
                self.m3uUrl = clean
                self.parseM3UContentSilent(text)
            }
        }.resume()
    }
    
    func parseM3UContentSilent(_ text: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var loaded: [Channel] = []
            let lines = text.components(separatedBy: .newlines)
            var currentName = ""
            var currentGroup = "Genel"
            var currentLogo = ""
            
            var foundEpgUrl: String? = nil
            if let firstLine = lines.first(where: { $0.hasPrefix("#EXTM3U") }) {
                if let range = firstLine.range(of: "x-tvg-url=\"") ?? firstLine.range(of: "url-tvg=\"") {
                    let sub = firstLine[range.upperBound...]
                    if let end = sub.range(of: "\"") {
                        foundEpgUrl = String(sub[..<end.lowerBound])
                    }
                }
            }
            if let found = foundEpgUrl {
                DispatchQueue.main.async {
                    if let idx = self.accounts.firstIndex(where: { $0.m3uUrl == self.m3uUrl }) {
                        if self.accounts[idx].epgUrl != found {
                            self.accounts[idx].epgUrl = found
                            self.saveAccounts()
                        }
                    }
                }
            }
            
            for line in lines {
                let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty { continue }
                
                if clean.hasPrefix("#EXTINF:") {
                    if let groupRange = clean.range(of: "group-title=\"") {
                        let sub = clean[groupRange.upperBound...]
                        if let end = sub.range(of: "\"") {
                            currentGroup = String(sub[..<end.lowerBound])
                        }
                    } else {
                        currentGroup = "Genel"
                    }
                    
                    if let logoRange = clean.range(of: "tvg-logo=\"") {
                        let sub = clean[logoRange.upperBound...]
                        if let end = sub.range(of: "\"") {
                            currentLogo = String(sub[..<end.lowerBound])
                        }
                    }
                    
                    if let comma = clean.range(of: ",", options: .backwards) {
                        currentName = String(clean[comma.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } else if !clean.hasPrefix("#") {
                    if currentName.isEmpty {
                        let urlFilename = URL(string: clean)?.lastPathComponent ?? "Desteklenmeyen Yayın"
                        currentName = urlFilename.isEmpty ? "Bilinmeyen Kanal" : urlFilename
                    }
                    
                    let grpLower = currentGroup.lowercased()
                    let contentType: String
                    
                    let isVideoFileSuf = clean.lowercased().hasSuffix(".mkv") || clean.lowercased().hasSuffix(".mp4") || clean.lowercased().hasSuffix(".avi") || clean.lowercased().hasSuffix(".mov") || clean.lowercased().hasSuffix(".m4v")
                    let isXtreamMoviePath = clean.lowercased().contains("/movie/") || clean.lowercased().contains("/movies/")
                    let isXtreamSeriesPath = clean.lowercased().contains("/series/")
                    
                    let groupIsSeries = grpLower.contains("dizi") || grpLower.contains("series") || grpLower.contains("sezon") || grpLower.contains("season")
                    
                    if isXtreamSeriesPath {
                        contentType = "series"
                    } else if isXtreamMoviePath {
                        contentType = "movie"
                    } else if isVideoFileSuf {
                        if groupIsSeries {
                            contentType = "series"
                        } else {
                            contentType = "movie"
                        }
                    } else {
                        contentType = "live"
                    }
                    
                    loaded.append(Channel(name: currentName, logo: currentLogo, group: currentGroup, url: clean, contentType: contentType))
                    currentName = ""
                    currentLogo = ""
                }
            }
            
            DispatchQueue.main.async {
                self.channels = loaded
                self.isInitializingChannels = false
            }
        }
    }

    func parseM3UContent(_ text: String) {
        isLoading = true
        loadStep1 = true
        loadStep2 = false
        loadStep3 = false
        loadStep4 = false
        loadStep5 = false
        loadStepFinished = false
        loadingMessage = "Yayınlar düzenleniyor..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            var loaded: [Channel] = []
            let lines = text.components(separatedBy: .newlines)
            var currentName = ""
            var currentGroup = "Genel"
            var currentLogo = ""
            
            DispatchQueue.main.async { self.loadStep2 = true; self.loadingMessage = "Kanallar ayrıştırılıyor..." }
            
            var foundEpgUrl: String? = nil
            if let firstLine = lines.first(where: { $0.hasPrefix("#EXTM3U") }) {
                if let range = firstLine.range(of: "x-tvg-url=\"") ?? firstLine.range(of: "url-tvg=\"") {
                    let sub = firstLine[range.upperBound...]
                    if let end = sub.range(of: "\"") {
                        foundEpgUrl = String(sub[..<end.lowerBound])
                    }
                }
            }
            if let found = foundEpgUrl {
                DispatchQueue.main.async {
                    if let idx = self.accounts.firstIndex(where: { $0.m3uUrl == self.m3uUrl }) {
                        if self.accounts[idx].epgUrl != found {
                            self.accounts[idx].epgUrl = found
                            self.saveAccounts()
                        }
                    }
                }
            }
            
            for line in lines {
                let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty { continue }
                
                if clean.hasPrefix("#EXTINF:") {
                    // Group/category parsing
                    if let groupRange = clean.range(of: "group-title=\"") {
                        let sub = clean[groupRange.upperBound...]
                        if let end = sub.range(of: "\"") {
                            currentGroup = String(sub[..<end.lowerBound])
                        }
                    } else {
                        currentGroup = "Genel"
                    }
                    
                    // Logo parsing
                    if let logoRange = clean.range(of: "tvg-logo=\"") {
                        let sub = clean[logoRange.upperBound...]
                        if let end = sub.range(of: "\"") {
                            currentLogo = String(sub[..<end.lowerBound])
                        }
                    }
                    
                    // Name parsing
                    if let comma = clean.range(of: ",", options: .backwards) {
                        currentName = String(clean[comma.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } else if !clean.hasPrefix("#") {
                    if currentName.isEmpty {
                        // Extract filename from the URL as fallback name if metadata was missing or unparsed
                        let urlFilename = URL(string: clean)?.lastPathComponent ?? "Desteklenmeyen Yayın"
                        currentName = urlFilename.isEmpty ? "Bilinmeyen Kanal" : urlFilename
                    }
                    
                    // Classify content types dynamically
                    let grpLower = currentGroup.lowercased()
                    let contentType: String
                    
                    let isVideoFileSuf = clean.lowercased().hasSuffix(".mkv") || clean.lowercased().hasSuffix(".mp4") || clean.lowercased().hasSuffix(".avi") || clean.lowercased().hasSuffix(".mov") || clean.lowercased().hasSuffix(".m4v")
                    let isXtreamMoviePath = clean.lowercased().contains("/movie/") || clean.lowercased().contains("/movies/")
                    let isXtreamSeriesPath = clean.lowercased().contains("/series/")
                    
                    let groupIsSeries = grpLower.contains("dizi") || grpLower.contains("series") || grpLower.contains("sezon") || grpLower.contains("season")
                    
                    if isXtreamSeriesPath {
                        contentType = "series"
                    } else if isXtreamMoviePath {
                        contentType = "movie"
                    } else if isVideoFileSuf {
                        if groupIsSeries {
                            contentType = "series"
                        } else {
                            contentType = "movie"
                        }
                    } else {
                        contentType = "live"
                    }
                    
                    loaded.append(Channel(name: currentName, logo: currentLogo, group: currentGroup, url: clean, contentType: contentType))
                    currentName = ""
                    currentLogo = ""
                }
            }
            
            DispatchQueue.main.async {
                self.channels = loaded
                // Step 2 is set to true during parse. Now, sequentially tick Steps 3, 4, 5.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation {
                        self.loadStep3 = true
                        self.loadingMessage = "Filmler eşitleniyor..."
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        withAnimation {
                            self.loadStep4 = true
                            self.loadingMessage = "Diziler eşitleniyor..."
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            withAnimation {
                                self.loadStep5 = true
                                self.loadingMessage = "İçerik eşleştiriliyor..."
                            }
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                withAnimation {
                                    self.loadStepFinished = true
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Dedicated In-Sheet Setup Handlers
    func fetchM3uDataInSheet(_ urlString: String, epgUrl: String? = nil) {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean) else {
            self.sheetError = "Geçersiz M3U Listesi URL adresi!"
            return
        }
        
        showSyncOverlay = true
        isLoading = true
        showAccountsSheet = false
        loadStep1 = false
        loadStep2 = false
        loadStep3 = false
        loadStep4 = false
        loadStep5 = false
        loadStepFinished = false
        loadingMessage = "Bağlanılıyor..."
        sheetError = nil
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, err in
            if let err = err {
                DispatchQueue.main.async {
                    self.showSyncOverlay = false
                    self.isLoading = false
                    self.showAccountsSheet = true
                    self.sheetError = "Bağlantı Hatası: \(err.localizedDescription)"
                }
                return
            }
            
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
                    self.showSyncOverlay = false
                    self.isLoading = false
                    self.showAccountsSheet = true
                    self.sheetError = "M3U listesi boş veya okunamaz formatta."
                }
                return
            }
            
            DispatchQueue.main.async {
                self.loadStep1 = true
                let hostName = URL(string: clean)?.host ?? "M3U Playlist"
                let newAccountId = UUID()
                let cleanedEpgUrl = epgUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalEpgUrl = (cleanedEpgUrl == nil || cleanedEpgUrl!.isEmpty) ? nil : cleanedEpgUrl
                
                let newAcc = IPTVAccount(id: newAccountId, name: hostName, mode: 0, m3uUrl: clean, epgUrl: finalEpgUrl)
                
                if !self.accounts.contains(where: { $0.m3uUrl == clean }) {
                    self.accounts.append(newAcc)
                    self.saveAccounts()
                    self.activeAccountIdString = newAccountId.uuidString
                } else if let idx = self.accounts.firstIndex(where: { $0.m3uUrl == clean }) {
                    self.accounts[idx].epgUrl = finalEpgUrl
                    self.saveAccounts()
                    self.activeAccountIdString = self.accounts[idx].id.uuidString
                }
                
                // Save to partitioned cache file safely
                try? text.write(to: self.getM3uFilePath(), atomically: true, encoding: .utf8)
                
                self.m3uUrl = clean
                
                if let creds = self.extractXtreamCredentials(from: clean) {
                    self.fetchServerInfo(host: creds.host, user: creds.user, pass: creds.pass)
                } else {
                    self.serverExpiry = "M3U Bağlantısı"
                    self.serverActiveCons = "N/A"
                    self.serverMaxCons = "N/A"
                    self.serverStatus = "Aktif"
                }
                
                // Parse and keep Sync UI going
                self.parseM3UContent(text)
            }
        }.resume()
    }
    
    func fetchXtreamDataInSheet(host: String, user: String, pass: String) {
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanHost.hasPrefix("http://") && !cleanHost.hasPrefix("https://") {
            cleanHost = "http://\(cleanHost)"
        }
        
        if cleanHost.hasSuffix("/") {
            cleanHost.removeLast()
        }
        
        guard let liveCategoriesUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_live_categories"),
              let liveStreamsUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_live_streams"),
              let vodCategoriesUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_vod_categories"),
              let vodStreamsUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_vod_streams"),
              let seriesCategoriesUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_series_categories"),
              let seriesStreamsUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_series") else {
            self.sheetError = "Giriş bilgileriyle bir bağlantı şeması oluşturulamadı."
            return
        }
        
        showSyncOverlay = true
        isLoading = true
        showAccountsSheet = false
        loadStep1 = false
        loadStep2 = false
        loadStep3 = false
        loadStep4 = false
        loadStep5 = false
        loadStepFinished = false
        loadingMessage = "Sunucuya bağlanılıyor..."
        sheetError = nil
        
        let dispatchGroup = DispatchGroup()
        var fetchedCategories: [String: String] = [:]
        var fetchedChannels: [Channel] = []
        var internalError: String? = nil
        
        // 1. Live categories
        dispatchGroup.enter()
        URLSession.shared.dataTask(with: liveCategoriesUrl) { data, _, _ in
            defer { dispatchGroup.leave() }
            if let data = data, let list = try? JSONDecoder().decode([SafeDecodable<XtreamCategory>].self, from: data) {
                for element in list {
                    if let cat = element.value, let catName = cat.category_name {
                        fetchedCategories["live_" + cat.id] = catName
                    }
                }
            }
        }.resume()
        
        // 2. Movie categories
        dispatchGroup.enter()
        URLSession.shared.dataTask(with: vodCategoriesUrl) { data, _, _ in
            defer { dispatchGroup.leave() }
            if let data = data, let list = try? JSONDecoder().decode([SafeDecodable<XtreamCategory>].self, from: data) {
                for element in list {
                    if let cat = element.value, let catName = cat.category_name {
                        fetchedCategories["movie_" + cat.id] = catName
                    }
                }
            }
        }.resume()
        
        // 3. Series categories
        dispatchGroup.enter()
        URLSession.shared.dataTask(with: seriesCategoriesUrl) { data, _, _ in
            defer { dispatchGroup.leave() }
            if let data = data, let list = try? JSONDecoder().decode([SafeDecodable<XtreamCategory>].self, from: data) {
                for element in list {
                    if let cat = element.value, let catName = cat.category_name {
                        fetchedCategories["series_" + cat.id] = catName
                    }
                }
            }
        }.resume()
        
        dispatchGroup.notify(queue: .global(qos: .userInitiated)) {
            DispatchQueue.main.async {
                self.loadStep1 = true
                self.loadStep2 = false
                self.loadingMessage = "Canlı kanallar eşitleniyor..."
            }
            
            // 4. Fetch Live streams
            URLSession.shared.dataTask(with: liveStreamsUrl) { data, _, err in
                if let err = err { internalError = err.localizedDescription }
                if let data = data, let rawStreams = try? JSONDecoder().decode([SafeDecodable<XtreamStream>].self, from: data) {
                    let streams = rawStreams.compactMap { $0.value }
                    for s in streams {
                        guard let sIdSec = s.stream_id else { continue }
                        let sId = sIdSec.intValue
                        guard sId != 0 else { continue }
                        let name = s.name ?? s.stream_name ?? "Kanal #\(sId)"
                        let catIdStr = s.category_id?.stringValue ?? ""
                        let grp = fetchedCategories["live_" + catIdStr] ?? "Canlı Yayın"
                        let ext = s.container_extension ?? "ts"
                        let url = "\(cleanHost)/live/\(user)/\(pass)/\(sId).\(ext)"
                        fetchedChannels.append(Channel(name: name, logo: s.stream_icon ?? "", group: grp, url: url, contentType: "live", streamId: String(sId)))
                    }
                }
                
                DispatchQueue.main.async {
                    self.loadStep2 = true
                    self.loadStep3 = false
                    self.loadingMessage = "Filmler eşitleniyor..."
                }
                
                // 5. Fetch Movie streams
                URLSession.shared.dataTask(with: vodStreamsUrl) { data, _, _ in
                    struct XtreamMovie: Codable {
                        let name: String?
                        let stream_name: String?
                        let stream_id: SafeStringOrInt?
                    let stream_icon: String?
                    let category_id: SafeStringOrInt?
                    let container_extension: String?
                    let added: SafeStringOrInt?
                }
                if let data = data, let rawStreams = try? JSONDecoder().decode([SafeDecodable<XtreamMovie>].self, from: data) {
                    let streams = rawStreams.compactMap { $0.value }
                    for s in streams {
                        guard let sIdSec = s.stream_id else { continue }
                        let sId = sIdSec.intValue
                        guard sId != 0 else { continue }
                        let name = s.name ?? s.stream_name ?? "Sinema #\(sId)"
                        let catIdStr = s.category_id?.stringValue ?? ""
                        let grp = fetchedCategories["movie_" + catIdStr] ?? "Sinema"
                        let ext = s.container_extension ?? "mp4"
                        let url = "\(cleanHost)/movie/\(user)/\(pass)/\(sId).\(ext)"
                        fetchedChannels.append(Channel(name: name, logo: s.stream_icon ?? "", group: grp, url: url, contentType: "movie", added: s.added?.intValue ?? 0))
                    }
                }
                
                DispatchQueue.main.async {
                    self.loadStep3 = true
                    self.loadStep4 = false
                    self.loadingMessage = "Diziler eşitleniyor..."
                }
                
                // 6. Fetch Series streams
                URLSession.shared.dataTask(with: seriesStreamsUrl) { data, _, _ in
                    DispatchQueue.main.async {
                        self.loadStep4 = true
                        self.loadStep5 = false
                        self.loadingMessage = "İçerik eşleştiriliyor..."
                    }
                    
                    struct XtreamSeries: Codable {
                        let name: String?
                        let stream_name: String?
                    let series_id: SafeStringOrInt?
                    let cover: String?
                    let category_id: SafeStringOrInt?
                    let last_modified: SafeStringOrInt?
                }
                if let data = data, let rawStreams = try? JSONDecoder().decode([SafeDecodable<XtreamSeries>].self, from: data) {
                    let streams = rawStreams.compactMap { $0.value }
                    for s in streams {
                        guard let sIdSec = s.series_id else { continue }
                        let sId = sIdSec.intValue
                        guard sId != 0 else { continue }
                        let name = s.name ?? s.stream_name ?? "Dizi #\(sId)"
                        let catIdStr = s.category_id?.stringValue ?? ""
                        let grp = fetchedCategories["series_" + catIdStr] ?? "Diziler"
                        let url = "\(cleanHost)/series/\(user)/\(pass)/\(sId).mp4"
                        fetchedChannels.append(Channel(name: name, logo: s.cover ?? "", group: grp, url: url, contentType: "series", added: s.last_modified?.intValue ?? 0))
                    }
                }
                
                DispatchQueue.main.async {
                    self.sheetIsLoading = false
                    
                    if fetchedChannels.isEmpty {
                        self.showSyncOverlay = false
                        self.isLoading = false
                        self.showAccountsSheet = true
                        self.sheetError = internalError ?? "Girilen bilgilerle aktif bir yayın listesine ulaşılamadı. Lütfen sunucu durumunu veya bilgilerinizi kontrol edin."
                    } else {
                        self.channels = fetchedChannels
                        self.xtreamHost = cleanHost
                        self.xtreamUser = user
                        self.xtreamPass = pass
                        
                        let hostName = URL(string: cleanHost)?.host ?? cleanHost
                        let accountName = "\(user)@\(hostName)"
                        let newAccountId = UUID()
                        let newAcc = IPTVAccount(id: newAccountId, name: accountName, mode: 1, xtreamHost: cleanHost, xtreamUser: user, xtreamPass: pass)
                    
                    if !self.accounts.contains(where: { $0.xtreamHost == cleanHost && $0.xtreamUser == user }) {
                        self.accounts.append(newAcc)
                        self.saveAccounts()
                        self.activeAccountIdString = newAccountId.uuidString
                    } else if let matched = self.accounts.first(where: { $0.xtreamHost == cleanHost && $0.xtreamUser == user }) {
                        self.activeAccountIdString = matched.id.uuidString
                    }
                    
                    self.fetchServerInfo(host: cleanHost, user: user, pass: pass)
                    
                    // Cache locally under partition
                    if let encoded = try? JSONEncoder().encode(fetchedChannels) {
                        try? encoded.write(to: self.getXtreamFilePath())
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        withAnimation {
                            self.loadStep5 = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            withAnimation {
                                self.loadStepFinished = true
                            }
                            
                            UniqueChannelsCache.clear()
                            EPGManager.shared.fetchEPG(for: newAcc)
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.showSyncOverlay = false
                                self.isLoading = false
                                self.isInitializingChannels = false
                            }
                        }
                    }
                } // End else
            }
        }.resume() // series
        }.resume() // vod
    }.resume() // live
    } // End dispatchGroup.notify
}

// MARK: - Legacy direct API fetch handler
    func fetchXtreamData(host: String, user: String, pass: String) {
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanHost.lowercased().hasPrefix("http://") && !cleanHost.lowercased().hasPrefix("https://") {
            cleanHost = "http://\(cleanHost)"
        }
        while cleanHost.hasSuffix("/") {
            cleanHost.removeLast()
        }
        
        guard let liveCategoriesUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_live_categories"),
              let liveStreamsUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_live_streams"),
              let vodCategoriesUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_vod_categories"),
              let vodStreamsUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_vod_streams"),
              let seriesCategoriesUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_series_categories"),
              let seriesStreamsUrl = URL(string: "\(cleanHost)/player_api.php?username=\(user)&password=\(pass)&action=get_series") else {
            return
        }
        
        let dispatchGroup = DispatchGroup()
        var fetchedCategories: [String: String] = [:]
        var fetchedChannels: [Channel] = []
        
        // 1. Live categories
        dispatchGroup.enter()
        URLSession.shared.dataTask(with: liveCategoriesUrl) { data, _, _ in
            defer { dispatchGroup.leave() }
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in json {
                    if let id = item["category_id"] as? String, let name = item["category_name"] as? String {
                        fetchedCategories["live_" + id] = name
                    }
                }
            }
        }.resume()
        
        // 2. Movie categories
        dispatchGroup.enter()
        URLSession.shared.dataTask(with: vodCategoriesUrl) { data, _, _ in
            defer { dispatchGroup.leave() }
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in json {
                    if let id = item["category_id"] as? String, let name = item["category_name"] as? String {
                        fetchedCategories["movie_" + id] = name
                    }
                }
            }
        }.resume()
        
        // 3. Series categories
        dispatchGroup.enter()
        URLSession.shared.dataTask(with: seriesCategoriesUrl) { data, _, _ in
            defer { dispatchGroup.leave() }
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in json {
                    if let id = item["category_id"] as? String, let name = item["category_name"] as? String {
                        fetchedCategories["series_" + id] = name
                    }
                }
            }
        }.resume()
        
        dispatchGroup.notify(queue: .global(qos: .userInitiated)) {
            let streamGroup = DispatchGroup()
            
            // 4. Fetch Live streams
            streamGroup.enter()
            URLSession.shared.dataTask(with: liveStreamsUrl) { data, _, _ in
                defer { streamGroup.leave() }
                if let data = data, let rawStreams = try? JSONDecoder().decode([SafeDecodable<XtreamStream>].self, from: data) {
                    let streams = rawStreams.compactMap { $0.value }
                    for s in streams {
                        guard let sIdSec = s.stream_id else { continue }
                        let sId = sIdSec.intValue
                        guard sId != 0 else { continue }
                        let name = s.name ?? s.stream_name ?? "Kanal #\(sId)"
                        let catIdStr = s.category_id?.stringValue ?? ""
                        let grp = fetchedCategories["live_" + catIdStr] ?? "Canlı Yayın"
                        let ext = s.container_extension ?? "ts"
                        let url = "\(cleanHost)/live/\(user)/\(pass)/\(sId).\(ext)"
                        fetchedChannels.append(Channel(name: name, logo: s.stream_icon ?? "", group: grp, url: url, contentType: "live", streamId: String(sId)))
                    }
                }
            }.resume()
            
            // 5. Fetch Movie streams
            streamGroup.enter()
            URLSession.shared.dataTask(with: vodStreamsUrl) { data, _, _ in
                defer { streamGroup.leave() }
                struct XtreamMovieSilent: Codable {
                    let name: String?
                    let stream_name: String?
                    let stream_id: SafeStringOrInt?
                    let stream_icon: String?
                    let category_id: SafeStringOrInt?
                    let container_extension: String?
                    let added: SafeStringOrInt?
                }
                if let data = data, let rawStreams = try? JSONDecoder().decode([SafeDecodable<XtreamMovieSilent>].self, from: data) {
                    let streams = rawStreams.compactMap { $0.value }
                    for s in streams {
                        guard let sIdSec = s.stream_id else { continue }
                        let sId = sIdSec.intValue
                        guard sId != 0 else { continue }
                        let name = s.name ?? s.stream_name ?? "Sinema #\(sId)"
                        let catIdStr = s.category_id?.stringValue ?? ""
                        let grp = fetchedCategories["movie_" + catIdStr] ?? "Sinema"
                        let ext = s.container_extension ?? "mp4"
                        let url = "\(cleanHost)/movie/\(user)/\(pass)/\(sId).\(ext)"
                        fetchedChannels.append(Channel(name: name, logo: s.stream_icon ?? "", group: grp, url: url, contentType: "movie", added: s.added?.intValue ?? 0))
                    }
                }
            }.resume()
            
            // 6. Fetch Series streams
            streamGroup.enter()
            URLSession.shared.dataTask(with: seriesStreamsUrl) { data, _, _ in
                defer { streamGroup.leave() }
                struct XtreamSeriesSilent: Codable {
                    let name: String?
                    let stream_name: String?
                    let series_id: SafeStringOrInt?
                    let cover: String?
                    let category_id: SafeStringOrInt?
                    let last_modified: SafeStringOrInt?
                }
                if let data = data, let rawStreams = try? JSONDecoder().decode([SafeDecodable<XtreamSeriesSilent>].self, from: data) {
                    let streams = rawStreams.compactMap { $0.value }
                    for s in streams {
                        guard let sIdSec = s.series_id else { continue }
                        let sId = sIdSec.intValue
                        guard sId != 0 else { continue }
                        let name = s.name ?? s.stream_name ?? "Dizi #\(sId)"
                        let catIdStr = s.category_id?.stringValue ?? ""
                        let grp = fetchedCategories["series_" + catIdStr] ?? "Diziler"
                        let url = "\(cleanHost)/series/\(user)/\(pass)/\(sId).mp4"
                        fetchedChannels.append(Channel(name: name, logo: s.cover ?? "", group: grp, url: url, contentType: "series", added: s.last_modified?.intValue ?? 0))
                    }
                }
            }.resume()
            
            streamGroup.notify(queue: .main) {
                self.isInitializingChannels = false
                if !fetchedChannels.isEmpty {
                    self.channels = fetchedChannels
                    // Sync silent local cache as well
                    if let encoded = try? JSONEncoder().encode(fetchedChannels) {
                        try? encoded.write(to: self.getXtreamFilePath())
                    }
                }
            }
        }
    }

    // MARK: - Premium Dion Accounts Drawer Sheet
    var accountsDrawerSheet: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            
            // Premium Blurry Neon Fluid Backgrounds
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: "6D28D9"), Color(hex: "007FFF")], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 300, height: 300)
                    .offset(x: 100, y: -150)
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: "FF007F"), Color(hex: "7B2CBF")], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 320, height: 320)
                    .offset(x: -120, y: 120)
            }
            .blur(radius: 80)
            .opacity(0.12)
            .ignoresSafeArea()

            if providerSheetState == 0 {
                providersMainList
            } else if providerSheetState == 1 {
                addM3UView
            } else if providerSheetState == 2 {
                addXtreamView
            } else if providerSheetState == 3 {
                accountDetailView
            } else if providerSheetState == 4 {
                editProviderView
            }

            if let msg = cacheClearedMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.green)
                        Text(msg)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .sexyGlass()
                    .padding(.bottom, 150)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(99)
            }
        }
    }
    
    // MARK: - Providers Main List
    var providersMainList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Sağlayıcılar")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                
                // Active or Loaded Accounts (IPTV profiles)
                if !accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SAĞLAYICILARINIZ")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.horizontal, 20)
                        
                        VStack(spacing: 0) {
                            ForEach(0..<accounts.count, id: \.self) { index in
                                let acc = accounts[index]
                                Button(action: {
                                    switchAccount(to: acc)
                                    selectedDetailAccount = acc
                                    providerSheetState = 3
                                }) {
                                    HStack {
                                        ZStack {
                                            LinearGradient(colors: [Color(hex: "6D28D9"), Color(hex: "007FFF")], startPoint: .topLeading, endPoint: .bottomTrailing)
                                                .frame(width: 32, height: 32)
                                                .cornerRadius(8)
                                            
                                            Image(systemName: acc.mode == 0 ? "doc.richtext" : "server.rack")
                                                .foregroundColor(.white)
                                                .font(.system(size: 14, weight: .semibold))
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(acc.name)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundColor(.white)
                                            Text(acc.mode == 0 ? "M3U Playlist kütüphanesi" : "Xtream Canlı & Sinema")
                                                .font(.system(size: 11))
                                                .foregroundColor(.white.opacity(0.5))
                                        }
                                        .padding(.leading, 8)
                                        
                                        Spacer()
                                        
                                        if activeAccountIdString == acc.id.uuidString {
                                            Text("AKTİF")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.green)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.15))
                                                .cornerRadius(4)
                                                .padding(.trailing, 4)
                                        }
                                        
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.white.opacity(0.4))
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                }
                                if index < accounts.count - 1 {
                                    Divider().background(Color.white.opacity(0.1)).padding(.leading, 56)
                                }
                             }
                        }
                        .sexyGlass(cornerRadius: 16)
                        .padding(.horizontal, 20)
                    }
                }
                
                // IPTV Providers section
                VStack(alignment: .leading, spacing: 10) {
                    Text("IPTV")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 0) {
                        // M3U Provider button
                        Button(action: {
                            providerSheetState = 1
                        }) {
                            HStack {
                                ZStack {
                                    Color.blue
                                        .frame(width: 32, height: 32)
                                        .cornerRadius(8)
                                    
                                    Image(systemName: "doc.text.fill")
                                        .foregroundColor(.white)
                                        .font(.system(size: 15))
                                }
                                
                                Text("M3U")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.leading, 8)
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.white.opacity(0.4))
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                        }
                        
                        Divider().background(Color.white.opacity(0.1)).padding(.leading, 56)
                        
                        // Xtream Codes button
                        Button(action: {
                            providerSheetState = 2
                        }) {
                            HStack {
                                ZStack {
                                    Color(hex: "E0218A")
                                        .frame(width: 32, height: 32)
                                        .cornerRadius(8)
                                    
                                    Image(systemName: "server.rack")
                                        .foregroundColor(.white)
                                        .font(.system(size: 15))
                                }
                                
                                Text("Xtream")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.leading, 8)
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.white.opacity(0.4))
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                        }
                    }
                    .sexyGlass(cornerRadius: 16)
                    .padding(.horizontal, 20)
                }
                
                // Diğer Ayarlar List (Clear Cache & Version)
                VStack(alignment: .leading, spacing: 10) {
                    Text("SİSTEM SEÇENEKLERİ")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 0) {
                        Button(action: {
                            // Clear states
                            self.channels = []
                            self.favourites = []
                            UserDefaults.standard.removeObject(forKey: "favourites")
                            withAnimation {
                                cacheClearedMessage = "Önbellek ve Favoriler Temizlendi!"
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    cacheClearedMessage = nil
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "trash.fill")
                                    .foregroundColor(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.red)
                                    .cornerRadius(6)
                                Text("Önbelleği Temizle")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white)
                                    .padding(.leading, 8)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.white.opacity(0.4))
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                        }
                        
                        Divider().background(Color.white.opacity(0.1)).padding(.leading, 56)
                        
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.secondary)
                                .cornerRadius(6)
                            Text("Versiyon")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .padding(.leading, 8)
                            Spacer()
                            Text("v1.5.0 Premium")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                    }
                    .sexyGlass(cornerRadius: 16)
                    .padding(.horizontal, 20)
                }
                
                Spacer().frame(height: 150)
            }
        }
    }

    // MARK: - Import Settings Form sheet
    var settingsView: some View {
        EmptyView()
    }

    // MARK: - Provider Subviews
    var addM3UView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    providerSheetState = 0
                }) {
                    Text("Geri")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .sexyGlass(cornerRadius: 16)
                }
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("M3U OYNATMA LİSTESİ BAĞLANTISI")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(hex: "6D28D9"))
                        
                        TextField("http://sunucu.com/playlist.m3u", text: $tempM3uUrl)
                            .padding()
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(12)
                            .foregroundColor(.white)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        
                        Text("İçerisinde film, canlı tv barındıran tam M3U playlist linkinizi girin.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                            
                        Spacer().frame(height: 8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    
                    if let sErr = sheetError, !sErr.isEmpty {
                        Text(sErr)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    
                    Button(action: {
                        sheetError = nil
                        if tempM3uUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            sheetError = "Lütfen geçerli bir M3U playlist URL adresi girin."
                        } else {
                            fetchM3uDataInSheet(tempM3uUrl, epgUrl: tempM3uEpgUrl)
                        }
                    }) {
                        Text(sheetIsLoading ? "Bağlanıyor..." : "PLAYLIST'İ YÜKLE")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(sheetIsLoading ? Color.gray : Color(hex: "6D28D9"))
                            .cornerRadius(14)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 120)
                    }
                    .disabled(sheetIsLoading)
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }
    
    var addXtreamView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    providerSheetState = 0
                }) {
                    Text("Geri")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .sexyGlass(cornerRadius: 16)
                }
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SUNUCU ADRESİ (HOST URL)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(hex: "6D28D9"))
                    
                    TextField("http://sunucum.xyz:8080", text: $tempXtreamHost)
                        .padding()
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("KULLANICI ADI")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(hex: "6D28D9"))
                    
                    TextField("örn: mtsc_2391", text: $tempXtreamUser)
                        .padding()
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                        .autocorrectionDisabled()
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("ŞİFRE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(hex: "6D28D9"))
                    
                    SecureField("Şifrenizi girin", text: $tempXtreamPass)
                        .padding()
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                        .autocorrectionDisabled()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            
            if let sErr = sheetError, !sErr.isEmpty {
                Text(sErr)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            
            Button(action: {
                sheetError = nil
                if tempXtreamHost.isEmpty || tempXtreamUser.isEmpty || tempXtreamPass.isEmpty {
                    sheetError = "Lütfen tüm bağlantı bilgilerini eksiksiz doldurun."
                } else {
                    fetchXtreamDataInSheet(host: tempXtreamHost, user: tempXtreamUser, pass: tempXtreamPass)
                }
            }) {
                Text(sheetIsLoading ? "Bağlanıyor..." : "HESABA BAĞLAN")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(sheetIsLoading ? Color.gray : Color(hex: "6D28D9"))
                    .cornerRadius(14)
                    .padding(.horizontal, 20)
            }
            .disabled(sheetIsLoading)
            .padding(.top, 16)
            .padding(.bottom, 120) // Provide massive padding to clear bottom overlapping floating tab bar
            .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    var accountDetailView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    providerSheetState = 0
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                        Text("Geri")
                            .font(.system(size: 14))
                    }
                    .foregroundColor(Color(hex: "007FFF"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .sexyGlass(cornerRadius: 16)
                }
                Spacer()
            }
            .frame(height: 44)
            .overlay(
                Text("IPTV")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            )
            .overlay(
                Button(action: {
                    providerSheetState = 0
                    showAccountsSheet = false
                }) {
                    Text("Bitti")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .sexyGlass(cornerRadius: 16)
                }
                , alignment: .trailing
            )
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    if let acc = selectedDetailAccount {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sunucu bilgisi")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.horizontal, 20)
                            
                            VStack(spacing: 0) {
                                HStack {
                                    Image(systemName: "wifi")
                                        .foregroundColor(.white.opacity(0.7))
                                        .frame(width: 24)
                                    Text("Durum:")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white.opacity(0.7))
                                        .padding(.leading, 4)
                                    Text((acc.status ?? serverStatus).isEmpty ? "AKTİF" : (acc.status ?? serverStatus).uppercased())
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor((acc.status ?? serverStatus).lowercased() == "expired" ? .red : .white)
                                        .padding(.leading, 4)
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                
                                if acc.mode == 1 {
                                    Divider().background(Color.white.opacity(0.1)).padding(.leading, 48)
                                    
                                    HStack {
                                        Image(systemName: "point.3.connected.trianglepath.dotted")
                                            .foregroundColor(.white.opacity(0.7))
                                            .frame(width: 24)
                                        Text("Bağlantılar:")
                                            .font(.system(size: 16))
                                            .foregroundColor(.white.opacity(0.7))
                                            .padding(.leading, 4)
                                        Text("\((acc.activeConnections ?? serverActiveCons).isEmpty ? "0" : (acc.activeConnections ?? serverActiveCons))/\((acc.maxConnections ?? serverMaxCons).isEmpty ? "1" : (acc.maxConnections ?? serverMaxCons))")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.leading, 4)
                                        Spacer()
                                    }
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                    
                                    Divider().background(Color.white.opacity(0.1)).padding(.leading, 48)
                                    
                                    HStack {
                                        Image(systemName: "calendar")
                                            .foregroundColor(.white.opacity(0.7))
                                            .frame(width: 24)
                                        Text("Sona eriyor:")
                                            .font(.system(size: 16))
                                            .foregroundColor(.white.opacity(0.7))
                                            .padding(.leading, 4)
                                        Text((acc.expDate ?? serverExpiry).isEmpty ? "Bilinmiyor" : (acc.expDate ?? serverExpiry))
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.leading, 4)
                                        Spacer()
                                    }
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                }
                            }
                            .sexyGlass(cornerRadius: 16)
                            .padding(.horizontal, 20)
                        }
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Ayarlar")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.horizontal, 20)
                            
                            VStack(spacing: 0) {
                                Button(action: {
                                // Reload
                                if acc.mode == 0 {
                                    fetchM3uDataInSheet(acc.m3uUrl, epgUrl: acc.epgUrl)
                                } else {
                                    fetchXtreamDataInSheet(host: acc.xtreamHost, user: acc.xtreamUser, pass: acc.xtreamPass)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundColor(.white.opacity(0.7))
                                        .frame(width: 24)
                                    Text("Yeniden yükle")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                        .padding(.leading, 4)
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                            }
                            
                            Divider().background(Color.white.opacity(0.1)).padding(.leading, 48)
                            
                            Button(action: {
                                tempEditAccountName = acc.name
                                if acc.mode == 0 {
                                    tempEditUrl = acc.m3uUrl
                                    tempEditEpgUrl = acc.epgUrl ?? ""
                                    tempEditUser = ""
                                    tempEditPass = ""
                                } else {
                                    tempEditUrl = acc.xtreamHost
                                    tempEditEpgUrl = acc.epgUrl ?? ""
                                    tempEditUser = acc.xtreamUser
                                    tempEditPass = acc.xtreamPass
                                }
                                providerSheetState = 4
                            }) {
                                HStack {
                                    Image(systemName: "pencil")
                                        .foregroundColor(.white.opacity(0.7))
                                        .frame(width: 24)
                                    Text("Detayları düzenle")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                        .padding(.leading, 4)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.4)).font(.system(size: 14, weight: .semibold))
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                            }
                            
                            Divider().background(Color.white.opacity(0.1)).padding(.leading, 48)
                            
                            Button(action: {}) {
                                HStack {
                                    Image(systemName: "slider.horizontal.3")
                                        .foregroundColor(.white.opacity(0.7))
                                        .frame(width: 24)
                                    Text("İçeriği yönet")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                        .padding(.leading, 4)
                                    Spacer()
                                    Text("PRO")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue)
                                        .cornerRadius(4)
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                            }
                            
                            Divider().background(Color.white.opacity(0.1)).padding(.leading, 48)
                            
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Button(action: {}) {
                                    EmptyView()
                                }
                                
                                HStack {
                                    EmptyView()
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                            }
                            
                            Divider().background(Color.white.opacity(0.1)).padding(.leading, 48)
                            
                            Button(action: {
                                if let idx = accounts.firstIndex(where: { $0.id == acc.id }) {
                                    if activeAccountIdString == acc.id.uuidString {
                                        activeAccountIdString = ""
                                        channels = []
                                    }
                                    accounts.remove(at: idx)
                                    saveAccounts()
                                    providerSheetState = 0
                                }
                            }) {
                                HStack {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                        .frame(width: 24)
                                    Text("Sil")
                                        .font(.system(size: 16))
                                        .foregroundColor(.red)
                                        .padding(.leading, 4)
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                            }
                        }
                        .sexyGlass(cornerRadius: 16)
                        .padding(.horizontal, 20)
                    }
                }
                
                Spacer().frame(height: 50)
            }
        }
    }
}

    var editProviderView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: {
                    providerSheetState = 3 // back to details
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                        Text("İptal")
                            .font(.system(size: 14))
                    }
                    .foregroundColor(Color(hex: "007FFF"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .sexyGlass(cornerRadius: 16)
                }
                Spacer()
            }
            .frame(height: 44)
            .overlay(
                Text("Detayları Düzenle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            )
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Account Name Field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Oynatıcı Başlığı (İsteğe bağlı)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                        
                        TextField("My Server, IPTV vb.", text: $tempEditAccountName)
                            .padding(16)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(12)
                            .foregroundColor(.white)
                    }
                    
                    if let acc = selectedDetailAccount {
                        if acc.mode == 0 {
                            // M3U URL
                            VStack(alignment: .leading, spacing: 8) {
                                Text("M3U URL")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                                
                                TextField("http://...", text: $tempEditUrl)
                                    .padding(16)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(12)
                                    .foregroundColor(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                        } else {
                            // Xtream fields
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Sunucu Adresi")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                                
                                TextField("http://sunucuadresi.com:port", text: $tempEditUrl)
                                    .padding(16)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(12)
                                    .foregroundColor(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Kullanıcı Adı")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                                
                                TextField("Kullanıcı adınız", text: $tempEditUser)
                                    .padding(16)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(12)
                                    .foregroundColor(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Şifre")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                                
                                TextField("Şifreniz", text: $tempEditPass)
                                    .padding(16)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(12)
                                    .foregroundColor(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                        }
                    }
                    
                    if let sErr = sheetError, !sErr.isEmpty {
                        Text(sErr)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                    
                    Button(action: {
                        sheetError = nil
                        guard let acc = selectedDetailAccount else { return }
                        
                        if acc.mode == 0 {
                            if tempEditUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                sheetError = "M3U URL adresi boş olamaz."
                                return
                            }
                        } else {
                            if tempEditUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                               tempEditUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                               tempEditPass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                sheetError = "Lütfen tüm sunucu alanlarını eksiksiz doldurun."
                                return
                            }
                        }
                        
                        // Save edits back into accounts
                        if let idx = accounts.firstIndex(where: { $0.id == acc.id }) {
                            let oldMode = accounts[idx].mode
                            
                            let newName = tempEditAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (oldMode == 0 ? "M3U Playlist" : "Xtream Server") : tempEditAccountName
                            
                            accounts[idx].name = newName
                            accounts[idx].epgUrl = tempEditEpgUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            if oldMode == 0 {
                                accounts[idx].m3uUrl = tempEditUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                            } else {
                                accounts[idx].xtreamHost = tempEditUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                                accounts[idx].xtreamUser = tempEditUser.trimmingCharacters(in: .whitespacesAndNewlines)
                                accounts[idx].xtreamPass = tempEditPass.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            
                            saveAccounts()
                            
                            // If this edited account is currently the active one, trigger reload cleanly!
                            if activeAccountIdString == acc.id.uuidString {
                                switchAccount(to: accounts[idx])
                            }
                            
                            selectedDetailAccount = accounts[idx]
                            providerSheetState = 3 // back to detail
                            cacheClearedMessage = "Sunucu bilgileri başarıyla güncellendi."
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                cacheClearedMessage = nil
                            }
                        }
                    }) {
                        Text("BİLGİLERİ KAYDET")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(hex: "007FFF"))
                            .cornerRadius(14)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 120)
            }
        }
    }
    
    func contentStatBox(title: String, count: Int, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(Color(hex: "6D28D9"))
            
            VStack(spacing: 4) {
                Text("\(count)")
                    .font(.system(size: 20, weight: .black))
                    .foregroundColor(.white)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(hex: "1F2131"))
        .cornerRadius(16)
    }

    // MARK: - Category Selection Sheet (Solves category navigation pain)
    var categorySelectionSheet: some View {
        NavigationView {
            ZStack {
                Color.clear.ignoresSafeArea()
                
                VStack(spacing: 16) {
                    // Search box
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.white.opacity(0.4))
                        TextField("", text: $categorySearchQuery, prompt: Text("Kategori ara... (Örn: Spor)").foregroundColor(.white.opacity(0.3)))
                            .foregroundColor(.white)
                            .autocorrectionDisabled()
                        
                        if !categorySearchQuery.isEmpty {
                            Button(action: { categorySearchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    
                    // List of matching categories
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            // "Tümü" option
                            Button(action: {
                                selectedCategory = "Tümü"
                                showCategorySheet = false
                            }) {
                                HStack {
                                    Image(systemName: "circle.grid.2x2.fill")
                                        .foregroundColor(Color(hex: "6D28D9"))
                                        .frame(width: 24)
                                    Text("TÜM KATEGORİLER")
                                        .font(.system(size: 14, weight: .bold))
                                    Spacer()
                                    if selectedCategory == "Tümü" {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Color(hex: "6D28D9"))
                                    }
                                }
                                .padding()
                                .background(selectedCategory == "Tümü" ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                                .cornerRadius(12)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(.horizontal, 16)
                            
                            let filteredCats = categories.filter { cat in
                                categorySearchQuery.isEmpty || cat.localizedCaseInsensitiveContains(categorySearchQuery)
                            }
                            
                            if filteredCats.isEmpty {
                                Text("Aramanıza uygun kategori bulunamadı.")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.4))
                                    .padding(.top, 40)
                            } else {
                                ForEach(filteredCats, id: \.self) { cat in
                                    Button(action: {
                                        selectedCategory = cat
                                        showCategorySheet = false
                                    }) {
                                        HStack {
                                            Image(systemName: "folder.fill")
                                                .foregroundColor(.white.opacity(0.4))
                                                .frame(width: 24)
                                            Text(cat)
                                                .font(.system(size: 14, weight: .medium))
                                            Spacer()
                                            if selectedCategory == cat {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(Color(hex: "6D28D9"))
                                            }
                                        }
                                        .foregroundColor(.white)
                                        .padding()
                                        .background(selectedCategory == cat ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                                        .cornerRadius(12)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
                .padding(.top, 16)
            }
            .navigationBarTitle("Kategori Seçimi", displayMode: .inline)
            .navigationBarItems(trailing: Button("Kapat") { showCategorySheet = false }.foregroundColor(.white))
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Modular Custom Segment CategoryButton View
struct CategoryButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isSelected ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color(hex: "6D28D9") : Color.white.opacity(0.06))
                .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle()) // prevents blue focus tint
    }
}

// Custom Swift view offset border modifier
extension View {
    func stroke<S: ShapeStyle>(_ content: S, righteousness width: CGFloat) -> some View {
        self.modifier(StrokeModifier(strokeContent: content, width: width))
    }
}

struct ChannelRowView: View {
    let channel: Channel
    let isSelected: Bool
    let isFavorite: Bool
    let onTapFavorite: () -> Void
    let onTapChannel: () -> Void
    @ObservedObject var epgManager = EPGManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Main Glass Row
            HStack(spacing: 12) {
                // Logo Block
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "11131E"))
                        .frame(width: 54, height: 44)
                    
                    if !channel.logo.isEmpty, let logoUrl = URL(string: channel.logo) {
                        AsyncImage(url: logoUrl) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 44, height: 34)
                                    .cornerRadius(6)
                                    .clipped()
                            default:
                                placeholderIcon()
                            }
                        }
                    } else {
                        placeholderIcon()
                    }
                }
                
                // Info block
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(channel.name)
                            .foregroundColor(.white)
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)
                        if isSelected {
                            Circle()
                                .fill(Color(hex: "6D28D9"))
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text(channel.safeGroup)
                        .foregroundColor(isSelected ? Color(hex: "6D28D9") : Color.white.opacity(0.6))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                
                if channel.contentType == "live" {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(epgManager.currentProgramName(for: channel))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isSelected ? Color(hex: "6D28D9") : .white.opacity(0.8))
                            .lineLimit(1)
                            .frame(maxWidth: 120, alignment: .trailing)
                            
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 2)
                                    .cornerRadius(1)
                                
                                Rectangle()
                                    .fill(isSelected ? Color(hex: "6D28D9") : Color(hex: "007FFF"))
                                    .frame(width: geo.size.width * CGFloat(epgManager.programProgress(for: channel)), height: 2)
                                    .cornerRadius(1)
                            }
                        }
                        .frame(width: 80, height: 2)
                    }
                }
                
                // Right badges
                HStack(spacing: 6) {
                    Button(action: onTapFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .foregroundColor(isFavorite ? Color(hex: "FF3B30") : Color.white.opacity(0.4))
                            .font(.system(size: 16))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .frame(width: 32, height: 32)
                }
            }
            .padding(12)
        }
        .background(isSelected ? Color(hex: "1E2132") : Color(hex: "171926"))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Color(hex: "6D28D9").opacity(0.4) : Color.white.opacity(0.04), lineWidth: 1)
        )
        .onTapGesture(perform: onTapChannel)
    }

    func placeholderIcon() -> some View {
        Image(systemName: channel.contentType == "live" ? "tv.fill" : (channel.contentType == "movie" ? "film.fill" : "play.rectangle.fill"))
            .foregroundColor(Color.white.opacity(0.6))
            .font(.system(size: 16))
    }
}

struct StrokeModifier<S: ShapeStyle>: ViewModifier {
    var strokeContent: S
    var width: CGFloat
    
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(strokeContent, lineWidth: width)
        )
    }
}

struct VisualEffectView: UIViewRepresentable {
    var effect: UIVisualEffect?
    func makeUIView(context: UIViewRepresentableContext<Self>) -> UIVisualEffectView { UIVisualEffectView() }
    func updateUIView(_ uiView: UIVisualEffectView, context: UIViewRepresentableContext<Self>) { uiView.effect = effect }
}

extension View {
    @ViewBuilder
    func sexySheetBackground() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(.ultraThinMaterial)
        } else {
            self
        }
    }
    
    func sexyGlass(cornerRadius: CGFloat = 20) -> some View {
        self.background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
    }
    
    func sexyGlassCircle() -> some View {
        self.background(.ultraThinMaterial)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .clipShape(Circle())
            .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
    }
}

// High-fidelity custom safe Color Hex string initialization
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        self.init(.sRGB, red: Double((int >> 16) & 0xFF) / 255, green: Double((int >> 8) & 0xFF) / 255, blue: Double(int & 0xFF) / 255, opacity: 1)
    }
}

struct VolumeSliderRepresentable: UIViewRepresentable {
    @Binding var volume: CGFloat
    
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.alpha = 0.0001
        
        if let slider = view.subviews.first(where: { $0 is UISlider }) as? UISlider {
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
            slider.addTarget(context.coordinator, action: #selector(Coordinator.volumeChanged(_:)), for: .valueChanged)
            context.coordinator.slider = slider
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let slider = view.subviews.first(where: { $0 is UISlider }) as? UISlider {
                    slider.addTarget(context.coordinator, action: #selector(Coordinator.volumeChanged(_:)), for: .valueChanged)
                    context.coordinator.slider = slider
                }
            }
        }
        return view
    }
    
    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if let slider = uiView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            if abs(slider.value - Float(volume)) > 0.01 {
                slider.setValue(Float(volume), animated: false)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject {
        var parent: VolumeSliderRepresentable
        weak var slider: UISlider?
        
        init(_ parent: VolumeSliderRepresentable) {
            self.parent = parent
        }
        
        @objc func volumeChanged(_ sender: UISlider) {
            DispatchQueue.main.async {
                self.parent.volume = CGFloat(sender.value)
            }
        }
    }
}

// MARK: - Dedicated Caching Engine for GetUniqueChannels (Prunes lag and solves duplicate elements)
class UniqueChannelsCache {
    static let lock = NSRecursiveLock()
    static var cache: [String: [Channel]] = [:]
    static var cleanedTitles: [String: String] = [:]
    static var cacheGroups: [String: [String]] = [:]
    
    static func clear() {
        lock.lock()
        cache.removeAll()
        cleanedTitles.removeAll()
        cacheGroups.removeAll()
        lock.unlock()
    }
    
    static func getGroups(for type: String, channels: [Channel]) -> [String] {
        let cacheKey = "groups_\(type)_\(channels.count)"
        lock.lock()
        if let cached = cacheGroups[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        let groups = Array(Set(channels.filter({ $0.contentType == type }).map({ $0.safeGroup }))).sorted()
        
        lock.lock()
        cacheGroups[cacheKey] = groups
        lock.unlock()
        return groups
    }
}

// MARK: - EPG Management Service (Fetches real-time EPG from Active IPTV account and binds dynamically to channels)
class EPGManager: ObservableObject {
    static let shared = EPGManager()
    
    @Published var currentPrograms: [String: String] = [:] // streamId -> active program title
    @Published var nextPrograms: [String: String] = [:]    // streamId -> upcoming program title
    @Published var progressPercent: [String: Double] = [:]  // streamId -> played progress (0.0 ... 1.0)
    
    private var isLoading = false
    private let xmltvParser = XMLTVParser()
    
    private var lastFetchedAccountId: UUID? = nil
    
    func clearCache() {
        self.lastFetchedAccountId = nil
        self.currentPrograms.removeAll()
        self.nextPrograms.removeAll()
        self.progressPercent.removeAll()
    }
    
    func fetchEPG(for account: IPTVAccount) {
        guard !isLoading else { return }
        // Don't re-fetch if we already have it for this account
        if lastFetchedAccountId == account.id && !currentPrograms.isEmpty { return }
        
        isLoading = true
        lastFetchedAccountId = account.id
        
        let epgUrlStr: String?
        if account.mode == 1 { // Xtream
            let host = account.xtreamHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let user = account.xtreamUser.trimmingCharacters(in: .whitespacesAndNewlines)
            let pass = account.xtreamPass.trimmingCharacters(in: .whitespacesAndNewlines)
            epgUrlStr = "\(host)/xmltv.php?username=\(user)&password=\(pass)"
        } else { // M3U
            epgUrlStr = account.epgUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        guard let urlStr = epgUrlStr, !urlStr.isEmpty, let epgUrl = URL(string: urlStr) else {
            self.isLoading = false
            return
        }
        
        var request = URLRequest(url: epgUrl)
        request.setValue("VLC/3.0.18 LibVLC/3.0.18", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, let data = data else {
                DispatchQueue.main.async { self?.isLoading = false }
                return
            }
            
            self.xmltvParser.parse(data: data) { result in
                DispatchQueue.main.async {
                    self.currentPrograms = result.current
                    self.nextPrograms = result.next
                    self.progressPercent = result.progress
                    self.isLoading = false
                }
            }
        }.resume()
    }
    
    func currentProgramName(for channel: Channel) -> String {
        let keys = [channel.streamId, channel.name.lowercased(), channel.name.replacingOccurrences(of: " ", with: "")].compactMap { $0 }
        for key in keys {
            if let title = currentPrograms[key] { return title }
        }
        
        let categoryLower = channel.safeGroup.lowercased()
        if categoryLower.contains("spor") || categoryLower.contains("sport") {
            return "Canlı Spor Kuşağı"
        } else if categoryLower.contains("belge") || categoryLower.contains("doc") || categoryLower.contains("bilim") || categoryLower.contains("doğa") || categoryLower.contains("nat") {
            return "Doğa ve Bilim Belgeseli"
        } else if categoryLower.contains("sinema") || categoryLower.contains("film") || categoryLower.contains("movie") || categoryLower.contains("vizyon") {
            return "Sinema Şöleni"
        } else if categoryLower.contains("haber") || categoryLower.contains("news") {
            return "Haber Bülteni"
        } else if categoryLower.contains("çocuk") || categoryLower.contains("kids") || categoryLower.contains("animas") {
            return "Çocuk Kuşağı: Eğlence Zamanı"
        } else if categoryLower.contains("müzik") || categoryLower.contains("music") || categoryLower.contains("klip") {
            return "Müzik Keyfi"
        }
        return "Premium Canlı Yayın"
    }
    
    func nextProgramName(for channel: Channel) -> String {
        let keys = [channel.streamId, channel.name.lowercased(), channel.name.replacingOccurrences(of: " ", with: "")].compactMap { $0 }
        for key in keys {
            if let title = nextPrograms[key] { return title }
        }
        
        // Şık zaman dilimi çak
        let now = Date()
        let nextHour = now.addingTimeInterval(3600)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:00"
        let timeStr = timeFormatter.string(from: nextHour)
        return "Sonraki Akış (\(timeStr))"
    }
    
    func programProgress(for channel: Channel) -> Double {
        let keys = [channel.streamId, channel.name.lowercased(), channel.name.replacingOccurrences(of: " ", with: "")].compactMap { $0 }
        for key in keys {
            if let val = progressPercent[key] { return val }
        }
        return 0.0
    }
}

// MARK: - XMLTV Parser Engine
class XMLTVParser: NSObject, XMLParserDelegate {
    private var programs: [String: [(title: String, start: Date, end: Date)]] = [:]
    private var channelMap: [String: [String]] = [:]
    
    private var currentElement = ""
    private var currentChannelId: String?
    private var currentStart: Date?
    private var currentEnd: Date?
    private var currentTitle = ""
    private var currentDisplayName = ""
    private var isParsingChannel = false
    
    struct ParseResult {
        var current: [String: String]
        var next: [String: String]
        var progress: [String: Double]
    }
    
    func parse(data: Data, completion: @escaping (ParseResult) -> Void) {
        programs.removeAll()
        channelMap.removeAll()
        
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        
        var newCurrent: [String: String] = [:]
        var newNext: [String: String] = [:]
        var newProgress: [String: Double] = [:]
        
        let now = Date()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        
        for (chId, progs) in programs {
            let sorted = progs.sorted { $0.start < $1.start }
            var current: (title: String, start: Date, end: Date)?
            var next: (title: String, start: Date, end: Date)?
            
            for p in sorted {
                if now >= p.start && now <= p.end {
                    current = p
                } else if now < p.start && next == nil {
                    next = p
                    break
                }
            }
            
            if current == nil && !sorted.isEmpty && sorted.last!.end > now {
                current = sorted.last
            }
            
            let possibleKeys = [chId] + (channelMap[chId] ?? [])
            
            for key in possibleKeys {
                let safeKey = key.lowercased()
                
                if let curr = current {
                    newCurrent[safeKey] = curr.title
                    let total = curr.end.timeIntervalSince(curr.start)
                    let elapsed = now.timeIntervalSince(curr.start)
                    if total > 0 {
                        newProgress[safeKey] = max(0.0, min(1.0, elapsed / total))
                    }
                }
                
                if let nxt = next {
                    newNext[safeKey] = "\(nxt.title) (\(timeFormatter.string(from: nxt.start)))"
                }
            }
        }
        
        completion(ParseResult(current: newCurrent, next: newNext, progress: newProgress))
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        
        if elementName == "channel" {
            isParsingChannel = true
            currentChannelId = attributeDict["id"]
        } else if elementName == "programme" {
            isParsingChannel = false
            currentChannelId = attributeDict["channel"]
            currentStart = parseXMLDate(attributeDict["start"])
            currentEnd = parseXMLDate(attributeDict["stop"])
            currentTitle = ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return }
        
        if isParsingChannel && currentElement == "display-name" {
            currentDisplayName += string
        } else if !isParsingChannel && currentElement == "title" {
            currentTitle += string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "channel" {
            if let chId = currentChannelId, !currentDisplayName.isEmpty {
                if channelMap[chId] == nil { channelMap[chId] = [] }
                channelMap[chId]?.append(currentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            currentChannelId = nil
            currentDisplayName = ""
        } else if elementName == "programme" {
            if let chId = currentChannelId, let s = currentStart, let e = currentEnd, !currentTitle.isEmpty {
                let cleanTitle = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if programs[chId] == nil { programs[chId] = [] }
                programs[chId]?.append((title: cleanTitle, start: s, end: e))
            }
            currentChannelId = nil
            currentStart = nil
            currentEnd = nil
            currentTitle = ""
        }
    }
    
    private func parseXMLDate(_ string: String?) -> Date? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        if let d = formatter.date(from: s) { return d }
        
        formatter.dateFormat = "yyyyMMddHHmmss"
        if s.count >= 14 {
            return formatter.date(from: String(s.prefix(14)))
        }
        return nil
    }
}

// Helper extensıons to extract streamId for Xtream matching and decode base64

extension String {
    func decodeBase64IfNeeded() -> String {
        guard let data = Data(base64Encoded: self) else { return self }
        return String(data: data, encoding: .utf8) ?? self
    }
}

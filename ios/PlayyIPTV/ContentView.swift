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
}

struct Channel: Identifiable, Codable, Hashable {
    var id = UUID()
    let name: String
    let logo: String
    let group: String
    let url: String
    var contentType: String = "live" // "live", "movie", "series"
    
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
    weak var player: AVPlayer?
    var timer: Timer?
    var hideTimer: Timer?
    
    func start(player: AVPlayer?) {
        self.player = player
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.update()
        }
        userTapped() // initial show
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
    
    deinit {
        timer?.invalidate()
        hideTimer?.invalidate()
    }
    
    func update() {
        guard let item = player?.currentItem else { return }
        
        // Update Resolution & FPS
        let size = item.presentationSize
        var fpsInfo = ""
        var foundVideo = false
        
        for trackItem in item.tracks {
            if let assetTrack = trackItem.assetTrack, assetTrack.mediaType == .video {
                foundVideo = true
                let fps = trackItem.currentVideoFrameRate > 0 ? trackItem.currentVideoFrameRate : assetTrack.nominalFrameRate
                if fps > 0 {
                    var finalFps = 25
                    let rounded = Int(round(fps))
                    if rounded >= 55 { finalFps = 60 }
                    else if rounded >= 45 { finalFps = 50 }
                    else if rounded >= 28 { finalFps = 30 }
                    else { finalFps = 25 } // Default or minimum logical for live streams
                    fpsInfo = " \(finalFps)FPS"
                    break
                }
            }
        }
        
        DispatchQueue.main.async {
            if size.height > 10 {
                self.resolutionString = "\(Int(size.height))p\(fpsInfo)"
                self.isAudioOnly = false
                self.timer?.invalidate() // TRICK: Save battery, only fetch once!
            } else if foundVideo {
                self.resolutionString = "Bağlanıyor..."
                self.isAudioOnly = false
            } else {
                self.resolutionString = "Oynatılıyor"
                self.isAudioOnly = false // Make it neutral so it doesn't look like an error to the user
            }
        }
    }
}

// MARK: - Native iOS High-Performance IPTV AVPlayer
struct NativeVideoPlayerView: UIViewControllerRepresentable {
    let urlString: String
    let videoContentMode: UIView.ContentMode
    @ObservedObject var infoManager: PlayerInfoManager
    
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var currentUrl: String = ""
        var player: AVPlayer?
        var infoManager: PlayerInfoManager
        
        init(infoManager: PlayerInfoManager) {
            self.infoManager = infoManager
        }
        
        @objc func handleTap() {
            infoManager.userTapped()
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(infoManager: infoManager)
    }
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.videoGravity = videoContentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.view.backgroundColor = .black
        
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        controller.view.addGestureRecognizer(tap)
        
        let overlayView = PlayerOverlaySwiftUIView(info: infoManager)
        let hostingController = UIHostingController(rootView: overlayView)
        hostingController.view.backgroundColor = .clear
        hostingController.view.isUserInteractionEnabled = false // Allow touches to pass through to native controls
        
        if let overlay = controller.contentOverlayView {
            hostingController.view.frame = overlay.bounds
            hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.addSubview(hostingController.view)
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.videoGravity = videoContentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect
        
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            uiViewController.player?.pause()
            uiViewController.player = nil
            return
        }
        
        if context.coordinator.currentUrl != normalized {
            context.coordinator.currentUrl = normalized
            
            // Explicitly pause and clean up previous player
            uiViewController.player?.pause()
            uiViewController.player?.replaceCurrentItem(with: nil)
            uiViewController.player = nil
            
            // Magic Trick for IPTV Optimization: Smartly convert any Xtream Codes TS/Live link to HLS (.m3u8) for native AVPlayer
            var optimizedUrlString = normalized
            if let urlObj = URL(string: normalized) {
                let pathParts = urlObj.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
                
                var isLiveXtream = false
                var user = ""
                var pass = ""
                var id = ""
                
                if pathParts.count == 3 {
                    user = pathParts[0]
                    pass = pathParts[1]
                    id = pathParts[2]
                    isLiveXtream = true
                } else if pathParts.count == 4 && pathParts[0].lowercased() == "live" {
                    user = pathParts[1]
                    pass = pathParts[2]
                    id = pathParts[3]
                    isLiveXtream = true
                }
                
                if isLiveXtream {
                    let idLower = id.lowercased()
                    // Don't modify if it's already an explicit VOD extension
                    if !idLower.hasSuffix(".mp4") && !idLower.hasSuffix(".mkv") && !idLower.hasSuffix(".avi") && !idLower.hasSuffix(".m3u8") {
                        if let dotIndex = id.lastIndex(of: ".") {
                            id = String(id[..<dotIndex])
                        }
                        
                        if var components = URLComponents(string: normalized) {
                            components.path = "/live/\(user)/\(pass)/\(id).m3u8"
                            if let newUrl = components.url?.absoluteString {
                                optimizedUrlString = newUrl
                            }
                        }
                    }
                } else {
                    if optimizedUrlString.hasSuffix(".ts") {
                        optimizedUrlString = String(optimizedUrlString.dropLast(3)) + ".m3u8"
                    }
                }
            }
            
            if let url = URL(string: optimizedUrlString) {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
                try? AVAudioSession.sharedInstance().setActive(true)
                
                // TRICK 2: Spoof User-Agent to bypass IPTV server blocks!
                let headers: [String: String] = [
                    "User-Agent": "VLC/3.0.18 LibVLC/3.0.18",
                    "Accept": "*/*"
                ]
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                let playerItem = AVPlayerItem(asset: asset)
                
                // 15 saniye önbellek ile donmaları sıfıra indirme
                playerItem.preferredForwardBufferDuration = 15.0
                
                let player = AVPlayer(playerItem: playerItem)
                player.automaticallyWaitsToMinimizeStalling = true
                
                uiViewController.player = player
                context.coordinator.player = player
                player.play()
                
                infoManager.start(player: player)
            }
        }
    }
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        uiViewController.player?.pause()
        uiViewController.player = nil
    }
}

// MARK: - Modern Player Overlay: Clock, Quality
struct PlayerOverlaySwiftUIView: View {
    @ObservedObject var info: PlayerInfoManager
    
    var body: some View {
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
    @State private var tempXtreamHost: String = ""
    @State private var tempXtreamUser: String = ""
    @State private var tempXtreamPass: String = ""
    @State private var sheetIsLoading: Bool = false
    @State private var sheetLoadingMessage: String = ""
    @State private var sheetError: String? = nil
    @State private var cacheClearedMessage: String? = nil
    
    // MARK: - App Tab Selection
    enum AppTab { case home, live, library, search, settings }
    @State private var currentTab: AppTab = .home
    @State private var isLandscape: Bool = false
    
    var body: some View {
        GeometryReader { geo in
            let _ = geo.size.width > geo.size.height
            ZStack {
                Color(hex: "08090C").ignoresSafeArea()
                
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
        .onAppear {
            loadAccounts()
            configureAudioSession()
            loadFavourites()
            loadSavedData()
        }
        .overlay(
            Group {
                if isLoading {
                    syncOverlayView
                }
            }
        )
        .sheet(isPresented: $showCategorySheet) {
            categorySelectionSheet
        }
        .sheet(isPresented: $showAccountsSheet) {
            accountsDrawerSheet
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
                            isLoading = false
                            showAccountsSheet = false
                            providerSheetState = 0
                            currentTab = .home
                        } else {
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
                if channels.isEmpty { emptyView() } else { homeTabContent }
            case .live:
                if channels.isEmpty { emptyView() } else { liveTVTabContent }
            case .library:
                if channels.isEmpty { emptyView() } else { libraryTabContent }
            case .search:
                if channels.isEmpty { emptyView() } else { searchTabContent }
            case .settings:
                accountsDrawerSheet
            }
        }
    }
    
    @State private var localLiveCategory: String = "Tümü"
    
    var globalPortraitPlayerView: some View {
        ZStack(alignment: .top) {
            GeometryReader { pGeo in
                if let channel = selectedChannel {
                     NativeVideoPlayerView(urlString: channel.url, videoContentMode: playerContentMode, infoManager: globalPlayerInfo)
                } else {
                     Color(hex: "08090C")
                     Text("Kanal Seçin").foregroundColor(.white.opacity(0.3)).position(x: pGeo.size.width/2, y: pGeo.size.height * 0.5)
                }
                
                // Next / Prev Channel buttons
                if selectedChannel != nil {
                    HStack {
                        Button(action: {
                            guard let cur = selectedChannel, let idx = channels.firstIndex(where: { $0.url == cur.url }), idx > 0 else { return }
                            selectedChannel = channels[idx - 1]
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 60)
                                .background(Color.black.opacity(0.3))
                                .cornerRadius(8)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            guard let cur = selectedChannel, let idx = channels.firstIndex(where: { $0.url == cur.url }), idx < channels.count - 1 else { return }
                            selectedChannel = channels[idx + 1]
                        }) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 60)
                                .background(Color.black.opacity(0.3))
                                .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal, 10)
                    .position(x: pGeo.size.width/2, y: pGeo.size.height * 0.5)
                }
                
                // Transparent Blur Buttons overlaid natively
                HStack {
                    Spacer()
                    
                    HStack(spacing: 8) {
                        Button(action: { cycleAspect() }) {
                            Image(systemName: "aspectratio")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        Button(action: { selectedChannel = nil }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.trailing, 16)
                .padding(.top, 12)
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
                
                let liveGroups = Array(Set(channels.filter({ $0.contentType == "live" }).map({ $0.safeGroup }))).sorted()
                
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
                Text("Şimdi")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            
            // Timeline
            epgTimelineGrid(category: category)
        }
    }
    
    func epgTimelineGrid(category: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 12) {
                let filteredLive = channels.filter { $0.contentType == "live" && $0.safeGroup == category && (liveSearchQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(liveSearchQuery)) }
                ForEach(filteredLive, id: \.id) { channel in
                    HStack(spacing: 12) {
                        // Left Logo
                        Button(action: { selectedChannel = channel }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.black.opacity(0.2))
                                    .frame(width: 60, height: 60)
                                
                                if let url = URL(string: channel.logo) {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 40).cornerRadius(6)
                                        } else {
                                            Image(systemName: "tv.fill").foregroundColor(.white.opacity(0.5))
                                        }
                                    }
                                } else {
                                     Image(systemName: "tv.fill").foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selectedChannel == channel ? Color.white : Color.clear, lineWidth: 2))
                        }
                        .padding(.leading, 16)
                        
                        // Horizontal EPG Row
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                epgProgramBox(title: channel.name, time: "Şimdi", width: 220, active: selectedChannel == channel, onPress: { selectedChannel = channel })
                                epgProgramBox(title: "Sonraki Program", time: "Sonra", width: 140, active: false, onPress: {})
                            }
                            .padding(.trailing, 16)
                        }
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 140) // Make room for tabs and player
        }
    }

    func epgProgramBox(title: String, time: String, width: CGFloat, active: Bool, onPress: @escaping () -> Void) -> some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 4) {
                 Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(active ? .black : .white).lineLimit(1)
                 Text(time).font(.system(size: 10, weight: .semibold)).foregroundColor(active ? .black.opacity(0.7) : .white.opacity(0.6)).lineLimit(1)
            }
            .padding(10)
            .frame(minWidth: width, idealHeight: 60, maxHeight: 60, alignment: .leading)
            .background(active ? Color.white : Color.white.opacity(0.08))
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
                    
                    HStack(spacing: 12) {
                        Button(action: {}) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }
                        Button(action: {}) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
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
                    
                    let recentMovies = getUniqueChannels(type: "movie", limit: 15, reversed: true)
                    
                    if !recentMovies.isEmpty {
                        libraryHorizontalPortraitSection(title: "Son eklenen filmler", items: recentMovies)
                    }
                } else if libraryFilter == "Filmler" {
                    let movieGroups = Array(Set(channels.filter({ $0.contentType == "movie" }).map({ $0.safeGroup }))).sorted()
                    libraryCategoryGrid(groups: movieGroups)
                } else if libraryFilter == "Diziler" {
                    let seriesGroups = Array(Set(channels.filter({ $0.contentType == "series" }).map({ $0.safeGroup }))).sorted()
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
                            .frame(width: 120, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
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
                    
                    ForEach(filteredItems, id: \.id) { channel in
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
                     let items = Array(channels.filter { $0.contentType == type || type == "all" }.prefix(15))
                     ForEach(items) { channel in
                         Button(action: { selectedChannel = channel }) {
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
                                            VisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialLight))
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
                tabItem(title: "Ayarlar", icon: "gearshape.fill", tab: .settings)
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

    func getUniqueChannels(type: String, limit: Int, reversed: Bool) -> [Channel] {
        var list = [Channel]()
        var seen = Set<String>()
        let filtered = channels.filter { $0.contentType == type }
        let iterator = reversed ? AnySequence(filtered.reversed()) : AnySequence(filtered)
        
        for ch in iterator {
            if !seen.contains(ch.name) {
                seen.insert(ch.name)
                list.append(ch)
            }
            if list.count >= limit { break }
        }
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
    
    @State private var showingControls: Bool = false
    @State private var controlsTimer: Timer? = nil

    @State private var showBrightnessPill = false
    @State private var showVolumePill = false
    @State private var brightnessLevel: CGFloat = UIScreen.main.brightness
    @State private var volumeLevel: CGFloat = 0.5

        var landscapePlayerView: some View {
        ZStack {
            if let channel = selectedChannel {
                NativeVideoPlayerView(urlString: channel.url, videoContentMode: playerContentMode, infoManager: globalPlayerInfo)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showingControls.toggle() }
                        if showingControls { resetTimer() }
                    }
                
                if showingControls {
                    Color.black.opacity(0.4).ignoresSafeArea() // dim background
                    
                    VStack {
                        // Top Section
                        HStack {
                            // Top Left: Separated Circle buttons
                            HStack(spacing: 12) {
                                Button(action: {
                                    selectedChannel = nil
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.4))
                                        .clipShape(Circle())
                                }
                                
                                Button(action: { cycleAspect() }) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.4))
                                        .clipShape(Circle())
                                }
                                
                                Button(action: { }) {
                                    Image(systemName: "pip.enter")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.4))
                                        .clipShape(Circle())
                                }
                            }
                            
                            Spacer()
                            
                            // Top Right: Kept empty to ensure no watermark/logo
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 20)
                        
                        Spacer()
                        
                        // Center Play/Pause 
                        HStack {
                            Button(action: {
                                if globalPlayerInfo.isPlaying {
                                    globalPlayerInfo.player?.pause()
                                } else {
                                    globalPlayerInfo.player?.play()
                                }
                                globalPlayerInfo.isPlaying.toggle()
                                resetTimer()
                            }) {
                                Image(systemName: globalPlayerInfo.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 44, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 80, height: 80)
                                    .background(Color.black.opacity(0.4))
                                    .clipShape(Circle())
                            }
                        }

                        Spacer()
                        
                        // Bottom Section
                        HStack(alignment: .bottom) {
                            // Bottom Left: Live badge + Channel info
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    // CANLI badge
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.red).frame(width: 6, height: 6)
                                        Text("CANLI")
                                            .font(.system(size: 10, weight: .black))
                                            .foregroundColor(.red)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.5))
                                    .cornerRadius(4)
                                    
                                    // Channel Name & fake EPG
                                    Text(channel.name)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    
                                    Text(channel.safeGroup) // Using safeGroup as EPG placeholder
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundColor(.white.opacity(0.6))
                                        .lineLimit(1)
                                }
                            }
                            
                            Spacer()
                            
                            // Bottom Right: Actions
                            HStack(spacing: 12) {
                                Button(action: {
                                    // Settings toast feedback or action
                                    resetTimer()
                                }) {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.4))
                                        .clipShape(Circle())
                                }
                                Button(action: { cycleAspect(); resetTimer() }) {
                                    Image(systemName: "tv")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.4))
                                        .clipShape(Circle())
                                }
                                Button(action: {
                                    toggleFavourite(channel.url)
                                    resetTimer()
                                }) {
                                    Image(systemName: favourites.contains(channel.url) ? "bookmark.fill" : "bookmark")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(favourites.contains(channel.url) ? .yellow : .white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.4))
                                        .clipShape(Circle())
                                }
                                Button(action: {
                                    // Show channels list
                                    resetTimer()
                                }) {
                                    Image(systemName: "list.bullet")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.white)
                                        .frame(width: 44, height: 44)
                                        .background(Color.black.opacity(0.4))
                                        .clipShape(Circle())
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                        .padding(.bottom, 40)
                    }
                    .zIndex(999)
                }
                
                // Invisible Drag Gesture Areas for Brightness & Volume
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    withAnimation { showBrightnessPill = true; showingControls = true; resetTimer() }
                                    let delta = value.translation.height / -1000
                                    brightnessLevel = max(0.0, min(1.0, brightnessLevel + delta))
                                    UIScreen.main.brightness = brightnessLevel
                                }
                        )
                    
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    withAnimation { showVolumePill = true; showingControls = true; resetTimer() }
                                }
                        )
                }
                .zIndex(99)
                
                // Active indicators
                if showBrightnessPill && showingControls {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "sun.max.fill").foregroundColor(.white)
                            ProgressView(value: brightnessLevel).progressViewStyle(LinearProgressViewStyle(tint: Color(hex: "6D28D9"))).frame(width: 100)
                            Spacer()
                        }
                        .padding(.horizontal, 40)
                        .padding(.bottom, 40)
                    }
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
    
    func emptyView() -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                Spacer().frame(height: 50)
                
                // Welcome / Logo Area
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color(hex: "6D28D9"), Color(hex: "007FFF")], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 80, height: 80)
                            .blur(radius: 12)
                            .opacity(0.6)
                        
                        Image(systemName: "play.tv.fill")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(colors: [.white, .white.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                            )
                    }
                    
                    VStack(spacing: 6) {
                        Text("Playy IPTV'ye Hoş Geldiniz")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        
                        Text("Lütfen başlamak için bir yayın kaynağı ekleyin.")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                
                // Quick Launch Glass Cards
                VStack(spacing: 16) {
                    // Option 1: M3U Playlist
                    Button(action: {
                        providerSheetState = 1
                        currentTab = .settings
                    }) {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.15))
                                    .frame(width: 48, height: 48)
                                    
                                Image(systemName: "doc.text.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.blue)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("M3U Playlist Bağlantısı")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                Text("URL adresi girerek listenizi hızlıca yükleyin")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .padding(16)
                        .sexyGlass(cornerRadius: 20)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Option 2: Xtream Codes
                    Button(action: {
                        providerSheetState = 2
                        currentTab = .settings
                    }) {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: "E0218A").opacity(0.15))
                                    .frame(width: 48, height: 48)
                                    
                                Image(systemName: "list.dash.header.rectangle")
                                    .font(.system(size: 18))
                                    .foregroundColor(Color(hex: "E0218A"))
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Xtream Codes Hesabı")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                Text("Kullanıcı adı ve şifre ile giriş yapın")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .padding(16)
                        .sexyGlass(cornerRadius: 20)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 20)
                
                // Active status section / Quick Info
                HStack(spacing: 12) {
                    Image(systemName: "shield.share")
                        .foregroundColor(.white.opacity(0.4))
                        .font(.system(size: 14))
                    Text("Tüm bilgileriniz cihazınızda tamamen şifreli bir şekilde saklanır.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(2)
                }
                .padding(.horizontal, 32)
                .padding(.top, 10)
                
                Spacer().frame(height: 120) // Keep standard bottom padding to avoid tabbar overlaps
            }
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
                        VisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialLight)) // Glass
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
            }
        }
        
        if iptvMode == 0 {
            // Check M3U Cache
            if let text = try? String(contentsOf: getM3uFilePath(), encoding: .utf8) {
                parseM3UContent(text)
            } else if !m3uUrl.isEmpty {
                fetchM3uData(m3uUrl)
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
            } else if !xtreamHost.isEmpty {
                fetchXtreamData(host: xtreamHost, user: xtreamUser, pass: xtreamPass)
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
        guard let url = URL(string: clean) else {
            self.errorMessage = "Geçersiz M3U Listesi URL adresi!"
            return
        }
        
        isLoading = true
        loadingMessage = "Oynatma listesi indiriliyor..."
        errorMessage = nil
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, err in
            if let err = err {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = "İndirme Hatası: \(err.localizedDescription)"
                }
                return
            }
            
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = "Liste indirildi fakat okunamadı (UTF-8 kodlama sorunu)."
                }
                return
            }
            
            // Save to cached partition
            try? text.write(to: getM3uFilePath(), atomically: true, encoding: .utf8)
            
            DispatchQueue.main.async {
                self.m3uUrl = clean
                self.parseM3UContent(text)
            }
        }.resume()
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
                    let nameLower = currentName.lowercased()
                    let contentType: String
                    
                    let isVideoFile = clean.lowercased().hasSuffix(".mkv") || clean.lowercased().hasSuffix(".mp4") || clean.lowercased().hasSuffix(".avi") || clean.lowercased().hasSuffix(".mov")
                    if grpLower.contains("dizi") || grpLower.contains("series") || grpLower.contains("sezon") || grpLower.contains("season") {
                        contentType = "series"
                    } else if isVideoFile || grpLower.contains("film") || grpLower.contains("movie") || grpLower.contains("sinema") || grpLower.contains("vod") || grpLower.contains("cinema") || nameLower.contains("film:") || nameLower.contains("sinema:") {
                        contentType = "movie"
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
    func fetchM3uDataInSheet(_ urlString: String) {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean) else {
            self.sheetError = "Geçersiz M3U Listesi URL adresi!"
            return
        }
        
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
                    self.isLoading = false
                    self.showAccountsSheet = true
                    self.sheetError = "Bağlantı Hatası: \(err.localizedDescription)"
                }
                return
            }
            
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
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
                let newAcc = IPTVAccount(id: newAccountId, name: hostName, mode: 0, m3uUrl: clean)
                
                if !self.accounts.contains(where: { $0.m3uUrl == clean }) {
                    self.accounts.append(newAcc)
                    self.saveAccounts()
                    self.activeAccountIdString = newAccountId.uuidString
                } else if let matched = self.accounts.first(where: { $0.m3uUrl == clean }) {
                    self.activeAccountIdString = matched.id.uuidString
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
            
            let streamGroup = DispatchGroup()
            
            // 4. Fetch Live streams
            streamGroup.enter()
            URLSession.shared.dataTask(with: liveStreamsUrl) { data, _, err in
                defer { streamGroup.leave() }
                if let err = err { internalError = err.localizedDescription; return }
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
                        fetchedChannels.append(Channel(name: name, logo: s.stream_icon ?? "", group: grp, url: url, contentType: "live"))
                    }
                }
            }.resume()
            
            // 5. Fetch Movie streams
            streamGroup.enter()
            URLSession.shared.dataTask(with: vodStreamsUrl) { data, _, _ in
                defer { streamGroup.leave() }
                DispatchQueue.main.async {
                    self.loadStep2 = true
                    self.loadStep3 = false
                    self.loadingMessage = "Filmler eşitleniyor..."
                }
                struct XtreamMovie: Codable {
                    let name: String?
                    let stream_name: String?
                    let stream_id: SafeStringOrInt?
                    let stream_icon: String?
                    let category_id: SafeStringOrInt?
                    let container_extension: String?
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
                        fetchedChannels.append(Channel(name: name, logo: s.stream_icon ?? "", group: grp, url: url, contentType: "movie"))
                    }
                }
            }.resume()
            
            // 6. Fetch Series streams
            streamGroup.enter()
            URLSession.shared.dataTask(with: seriesStreamsUrl) { data, _, _ in
                defer {
                    DispatchQueue.main.async {
                        self.loadStep4 = true
                        self.loadStep5 = false
                        self.loadingMessage = "İçerik eşleştiriliyor..."
                    }
                    streamGroup.leave()
                }
                struct XtreamSeries: Codable {
                    let name: String?
                    let stream_name: String?
                    let series_id: SafeStringOrInt?
                    let cover: String?
                    let category_id: SafeStringOrInt?
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
                        fetchedChannels.append(Channel(name: name, logo: s.cover ?? "", group: grp, url: url, contentType: "series"))
                    }
                }
            }.resume()
            
            streamGroup.notify(queue: .main) {
                self.sheetIsLoading = false
                
                if fetchedChannels.isEmpty {
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
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Legacy direct API fetch handler
    func fetchXtreamData(host: String, user: String, pass: String) {
        fetchXtreamDataInSheet(host: host, user: user, pass: pass)
    }

    // MARK: - Premium Dion Accounts Drawer Sheet
    var accountsDrawerSheet: some View {
        ZStack {
            Color(hex: "08090C").ignoresSafeArea()
            
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
                
                // Ağınızda Mevcut (Local Network Search) section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ağınızda mevcut")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.6)))
                                .scaleEffect(0.9)
                            
                            Text("Yerel ağ aranıyor...")
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.6))
                            
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                    }
                    .sexyGlass(cornerRadius: 16)
                    .padding(.horizontal, 20)
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
                
                // Medya merkezleri section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Medya merkezleri")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 0) {
                        // Plex row
                        Button(action: {
                            // Show premium feedback alert
                        }) {
                            HStack {
                                ZStack {
                                    Color(hex: "E5A93B")
                                        .frame(width: 32, height: 32)
                                        .cornerRadius(8)
                                    
                                    Image(systemName: "play.tv.fill")
                                        .foregroundColor(.black)
                                        .font(.system(size: 15))
                                }
                                
                                Text("Plex")
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
                        
                        // Jellyfin row
                        Button(action: {
                            // Show premium feedback alert
                        }) {
                            HStack {
                                ZStack {
                                    Color(hex: "10A5F5")
                                        .frame(width: 32, height: 32)
                                        .cornerRadius(8)
                                    
                                    Image(systemName: "circle.grid.cross.fill")
                                        .foregroundColor(.white)
                                        .font(.system(size: 15))
                                }
                                
                                Text("Jellyfin")
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
                
                // Dosya depolama section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Dosya depolama")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 0) {
                        // WebDAV row
                        Button(action: {
                            // Show premium feedback alert
                        }) {
                            HStack {
                                ZStack {
                                    Color(hex: "34D399")
                                        .frame(width: 32, height: 32)
                                        .cornerRadius(8)
                                    
                                    Image(systemName: "folder.badge.gearshape")
                                        .foregroundColor(.white)
                                        .font(.system(size: 15))
                                }
                                
                                Text("WebDAV")
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
                        
                        // SMB row
                        Button(action: {
                            // Show premium feedback alert
                        }) {
                            HStack {
                                ZStack {
                                    Color(hex: "FBBF24")
                                        .frame(width: 32, height: 32)
                                        .cornerRadius(8)
                                    
                                    Image(systemName: "server.rack")
                                        .foregroundColor(.white)
                                        .font(.system(size: 15))
                                }
                                
                                Text("SMB")
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
                            fetchM3uDataInSheet(tempM3uUrl)
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
                Spacer() // For aesthetic balance, if we needed back button it could go left
            }
            .frame(height: 44)
            .overlay(
                Text("IPTV")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            )
            .overlay(
                Button(action: {
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
                                Text(serverStatus.isEmpty ? "ACTIVE" : serverStatus.uppercased())
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(serverStatus.lowercased() == "expired" ? .red : .white)
                                    .padding(.leading, 4)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            
                            Divider().background(Color.white.opacity(0.1)).padding(.leading, 48)
                            
                            HStack {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .foregroundColor(.white.opacity(0.7))
                                    .frame(width: 24)
                                Text("Bağlantılar:")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(.leading, 4)
                                Text(serverMaxCons.isEmpty ? "0/2" : serverMaxCons)
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
                                Text(serverExpiry.isEmpty ? "27 Şub 2027" : serverExpiry)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.leading, 4)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
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
                                    fetchM3uDataInSheet(acc.m3uUrl)
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
                            
                            Button(action: {}) {
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
                            
                            Button(action: {}) {
                                HStack {
                                    Image(systemName: "server.rack")
                                        .foregroundColor(.white.opacity(0.7))
                                        .frame(width: 24)
                                    Text("Meta veriler")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                        .padding(.leading, 4)
                                    Spacer()
                                    Text("TMDB önce")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.5))
                                    Image(systemName: "chevron.up.chevron.down").foregroundColor(.white.opacity(0.4)).font(.system(size: 12))
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                            }
                            
                            Divider().background(Color.white.opacity(0.1)).padding(.leading, 48)
                            
                            Button(action: {}) {
                                HStack {
                                    Image(systemName: "book.pages")
                                        .foregroundColor(.white.opacity(0.7))
                                        .frame(width: 24)
                                    Text("EPG'yi yönet")
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
                Color(hex: "0C0D14").ignoresSafeArea()
                
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
                Spacer()
                
                // Right badges
                HStack(spacing: 6) {
                    Text("FHD")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)
                    
                    Button(action: onTapFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .foregroundColor(isFavorite ? Color(hex: "FF3B30") : Color.white.opacity(0.4))
                            .font(.system(size: 16))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .frame(width: 34, height: 34)
                }
            }
            .padding(12)
            
            // Sub-EPG timeline mock if it's Live TV
            if channel.contentType == "live" {
                VStack(spacing: 8) {
                    // Timeline bar representing elapsed time
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 2)
                                .cornerRadius(1)
                            
                            Rectangle()
                                .fill(isSelected ? Color(hex: "6D28D9") : Color.white.opacity(0.3))
                                .frame(width: geo.size.width * 0.45, height: 2)
                                .cornerRadius(1)
                        }
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    
                    // Shows
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ŞUAN OYNUYOR")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.4))
                            Text("Gündem Belgeseli")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("SIRADAKİ PROGRAM")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color.white.opacity(0.4))
                            Text("Haberler (18:30)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .opacity(0.8)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .background(Color(hex: "121420").opacity(0.3))
            }
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
    func sexyGlass(cornerRadius: CGFloat = 20) -> some View {
        self.background(
            ZStack {
                VisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
                Color.black.opacity(0.2)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: Color.black.opacity(0.5), radius: 15, x: 0, y: 10)
    }
    
    func sexyGlassCircle() -> some View {
        self.background(
            ZStack {
                VisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
                Color.black.opacity(0.2)
            }
        )
        .overlay(
            Circle()
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .clipShape(Circle())
        .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 8)
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
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        }
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

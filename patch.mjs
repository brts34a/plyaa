import fs from "fs"

let txt = fs.readFileSync("ios/PlayyIPTV/ContentView.swift", "utf8")

txt = txt.replace("import KSPlayer", "import AVKit\nimport AVFoundation")

const playerTarget = "struct NativeVideoPlayerView: UIViewRepresentable {"
const playerEnd = "// MARK: - Main IPTV Application UI"
const playerRegex = new RegExp(playerTarget + "[\\s\\S]*?" + playerEnd)
const newPlayer = `struct NativeVideoPlayerView: UIViewControllerRepresentable {
    let urlString: String
    let videoContentMode: UIView.ContentMode
    
    class Coordinator: NSObject {
        var currentUrl: String = ""
        var player: AVPlayer?
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.videoGravity = videoContentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.view.backgroundColor = .black
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.videoGravity = videoContentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect
        
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            uiViewController.player?.pause()
            return
        }
        
        if context.coordinator.currentUrl != normalized {
            context.coordinator.currentUrl = normalized
            if let url = URL(string: normalized) {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
                try? AVAudioSession.sharedInstance().setActive(true)
                
                let playerItem = AVPlayerItem(url: url)
                playerItem.preferredForwardBufferDuration = 15.0 
                let player = AVPlayer(playerItem: playerItem)
                player.automaticallyWaitsToMinimizeStalling = true
                
                uiViewController.player = player
                context.coordinator.player = player
                player.play()
            }
        }
    }
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        uiViewController.player?.pause()
        uiViewController.player = nil
    }
}

// MARK: - Main IPTV Application UI`
txt = txt.replace(playerRegex, newPlayer)

txt = txt.replace(/let items = channels\.filter \{ \$0\.contentType == type \|\| type == "all" \}\.shuffled\(\)\.prefix\(15\)/g, "let items = Array(channels.filter { $0.contentType == type || type == \"all\" }.prefix(15))")
txt = txt.replace(/let hero = channels\.filter\(\{ \$0\.contentType == "movie" \}\)\.randomElement\(\) \?\? channels\.first/g, "let hero = channels.filter({ $0.contentType == \"movie\" }).first ?? channels.first")

txt = txt.replace("enum AppTab { case home, live, library, search }", "enum AppTab { case home, live, library, search, settings }")

txt = txt.replace(/tabItem\(title: "Ara", icon: "magnifyingglass", tab: \.search\)/g, `tabItem(title: "Ara", icon: "magnifyingglass", tab: .search)\n            tabItem(title: "Ayarlar", icon: "gearshape.fill", tab: .settings)`)

const mainTabContentTarget = `    var mainTabContent: some View {
        Group {
            if channels.isEmpty {
                welcomeOnboardingArea
            } else {
                switch currentTab {
                case .home:
                    homeTabContent
                case .live:
                    liveTVTabContent
                case .library:
                    libraryTabContent
                case .search:
                    searchTabContent
                }
            }
        }
    }`
const newMainTabContent = `    var mainTabContent: some View {
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
    }`
txt = txt.replace(mainTabContentTarget, newMainTabContent)

const navItemsTarget = `            .navigationBarItems(trailing: Button(action: {
                if providerSheetState == 0 {
                    showAccountsSheet = false
                } else {
                    providerSheetState = 0
                }
            }) {
                Text(providerSheetState == 0 ? "Kapat" : "Geri")
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .bold))
            })`
const newNavItems = `            .navigationBarItems(trailing: Button(action: {
                if providerSheetState != 0 {
                    providerSheetState = 0
                }
            }) {
                Text(providerSheetState == 0 ? "" : "Geri")
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .bold))
            })`
txt = txt.replace(navItemsTarget, newNavItems)

txt = txt.replace('"Gösterilecek içerik bulunamadı"', '"Listeleriniz boş. Lütfen Ayarlar sekmesinden hesap ekleyin."')

const catOld = `                    let typeOverride: String? = (clean.hasSuffix(".mp4") || clean.hasSuffix(".mkv") || clean.hasSuffix(".avi")) ? "movie" : nil
                    if grpLower.contains("dizi") || grpLower.contains("series") || grpLower.contains("sezon") || grpLower.contains("season") {
                        contentType = "series"
                    } else if typeOverride != nil || grpLower.contains("film") || grpLower.contains("movie") || grpLower.contains("sinema") || grpLower.contains("vod") || grpLower.contains("cinema") {
                        contentType = "movie"
                    } else {
                        contentType = "live"
                    }`
const catAltOld = `                    if grpLower.contains("dizi") || grpLower.contains("series") || grpLower.contains("sezon") || grpLower.contains("season") {
                        contentType = "series"
                    } else if grpLower.contains("film") || grpLower.contains("movie") || grpLower.contains("sinema") || grpLower.contains("vod") || grpLower.contains("cinema") || nameLower.contains("film:") || nameLower.contains("sinema:") {
                        contentType = "movie"
                    } else {
                        contentType = "live"
                    }`
const catNew = `                    let isVideoFile = clean.lowercased().hasSuffix(".mkv") || clean.lowercased().hasSuffix(".mp4") || clean.lowercased().hasSuffix(".avi") || clean.lowercased().hasSuffix(".mov")
                    if grpLower.contains("dizi") || grpLower.contains("series") || grpLower.contains("sezon") || grpLower.contains("season") {
                        contentType = "series"
                    } else if isVideoFile || grpLower.contains("film") || grpLower.contains("movie") || grpLower.contains("sinema") || grpLower.contains("vod") || grpLower.contains("cinema") || nameLower.contains("film:") || nameLower.contains("sinema:") {
                        contentType = "movie"
                    } else {
                        contentType = "live"
                    }`
txt = txt.replace(catOld, catNew).replace(catAltOld, catNew)

const headerOld = `                HStack(spacing: 4) {
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
                .cornerRadius(20)`
const headerNew = `                Menu {
                    let liveGroups = Array(Set(channels.filter({ $0.contentType == "live" }).map({ $0.group }))).sorted()
                    ForEach(liveGroups, id: \\.self) { group in
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
                }`
txt = txt.replace(headerOld, headerNew)

const layoutOld = `                if landscape && selectedChannel != nil {
                    landscapePlayerView
                } else {
                    VStack(spacing: 0) {
                        if selectedChannel != nil {
                            globalPortraitPlayerView
                                .frame(height: geo.size.height * 0.35)
                        }
                        
                        mainTabContent
                            .frame(height: selectedChannel != nil ? geo.size.height * 0.65 : geo.size.height)
                        
                        Spacer(minLength: 0)
                    }
                }`
const layoutNew = `                VStack(spacing: 0) {
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
                                        
                                    Text(channel.group)
                                        .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.6))
                                        .padding(.horizontal, 20)
                                        
                                    Text("Şimdi Oynatılıyor...")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Color(hex: "00FF87"))
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
                }`
txt = txt.replace(layoutOld, layoutNew)

const blurOld = `        .background(
            ZStack {
                // The deep acrylic background mimicking iOS material
                Color.black.opacity(0.12)
                // Built in swiftUI blur effect matching ultraThin
                Rectangle().fill(.ultraThinMaterial)
            }
        )`
const blurNew = `        .background(
            ZStack {
                VisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
                Color.black.opacity(0.2)
            }
        )`
txt = txt.replace(blurOld, blurNew)

if(!txt.includes("struct VisualEffectView")) {
    txt += `\n\nstruct VisualEffectView: UIViewRepresentable {
    var effect: UIVisualEffect?
    func makeUIView(context: UIViewRepresentableContext<Self>) -> UIVisualEffectView { UIVisualEffectView() }
    func updateUIView(_ uiView: UIVisualEffectView, context: UIViewRepresentableContext<Self>) { uiView.effect = effect }
}`
}

const accOld = `    var accountDetailView: some View {
        VStack {
            if let acc = selectedDetailAccount {
                Text("Detaylar: \\(acc.name)")
                    .foregroundColor(.white)
            }
            Spacer()
        }
    }`
const accNew = `    var accountDetailView: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let acc = selectedDetailAccount {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(acc.name)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                        
                        if acc.mode == 1 {
                            HStack { Text("Tür:"); Spacer(); Text("Xtream Codes").foregroundColor(Color(hex: "00FF87")) }
                            HStack { Text("Host:"); Spacer(); Text(acc.xtreamHost).foregroundColor(.white.opacity(0.8)) }
                            HStack { Text("Kullanıcı Adı:"); Spacer(); Text(acc.xtreamUser).foregroundColor(.white.opacity(0.8)) }
                        } else {
                            HStack { Text("Tür:"); Spacer(); Text("M3U Playlist").foregroundColor(Color(hex: "00FF87")) }
                            HStack { Text("URL:"); Spacer(); Text(acc.m3uUrl).foregroundColor(.white.opacity(0.8)) }
                        }
                        
                        Divider().background(Color.white.opacity(0.2))
                        
                        if activeAccountIdString == acc.id.uuidString {
                            HStack { Text("Sunucu Durumu:"); Spacer(); Text(serverStatus.isEmpty ? "Aktif" : serverStatus).foregroundColor(Color(hex: "00FF87")) }
                            HStack { Text("Bitiş Tarihi:"); Spacer(); Text(serverExpiry.isEmpty ? "Yok" : serverExpiry).foregroundColor(.white.opacity(0.8)) }
                            HStack { Text("Maks. Bağlantı:"); Spacer(); Text(serverMaxCons.isEmpty ? "-" : serverMaxCons).foregroundColor(.white.opacity(0.8)) }
                            HStack { Text("Aktif Bağlantı:"); Spacer(); Text(serverActiveCons.isEmpty ? "-" : serverActiveCons).foregroundColor(.white.opacity(0.8)) }
                            
                            Button(action: {
                                // Listeyi yenile
                                if acc.mode == 0 { fetchM3uDataInSheet(acc.m3uUrl) }
                                else { fetchXtreamDataInSheet(host: acc.xtreamHost, user: acc.xtreamUser, pass: acc.xtreamPass) }
                            }) {
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                    Text("LİSTEYİ YENİLE")
                                }
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color(hex: "00FF87"))
                                .cornerRadius(14)
                            }
                        } else {
                            Text("Detayları görmek için bu panele bağlanın.").font(.system(size: 12)).foregroundColor(.white.opacity(0.4))
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .padding()
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(16)
                    .padding(.horizontal, 20)
                    
                    Button(action: {
                        if activeAccountIdString == acc.id.uuidString {
                            activeAccountIdString = ""
                            channels = []
                        }
                        accounts.removeAll(where: { $0.id == acc.id })
                        saveAccounts()
                        providerSheetState = 0
                    }) {
                        Text("BU SUNUCUYU SİL")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(14)
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.top, 24)
        }
    }`
txt = txt.replace(accOld, accNew)

fs.writeFileSync("ios/PlayyIPTV/ContentView.swift", txt)
console.log("Success!!!");

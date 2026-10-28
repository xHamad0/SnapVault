import SwiftUI
import Photos
import AVKit
import AVFoundation
import BackgroundTasks
import LocalAuthentication

// MARK: - 1. نماذج البيانات والإعدادات (Models)

enum MediaFilter: String, CaseIterable, Identifiable {
    case both = "الصور والفيديو"
    case imagesOnly = "الصور فقط"
    case videosOnly = "الفيديو فقط"
    var id: String { self.rawValue }
}

enum SaveMode: String, CaseIterable, Identifiable {
    case separate = "كل حساب لحاله"
    case combined = "مجلد واحد للجميع"
    case both = "الاثنين معاً (خاص + عام)"
    var id: String { self.rawValue }
}

struct SnapAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var username: String
    var isSelected: Bool = true
}

struct SnapMediaItem {
    let url: URL
    let isVideo: Bool
    let timestamp: String
}

struct LocalSavedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let fileName: String
    let isVideo: Bool
    let accountName: String
    let dateFormatted: String
    let creationDate: Date
    let fileSize: Int64
}

struct AlertItem: Identifiable {
    let id = UUID()
    let message: String
}

// MARK: - 2. مدير التحميل والتخزين الداخلي (Manager)

@MainActor
class SnapStoryManager: ObservableObject {
    @Published var accounts: [SnapAccount] = [] {
        didSet { saveAccounts() }
    }
    @Published var mediaFilter: MediaFilter = .both
    @Published var saveMode: SaveMode = .both
    
    @Published var isScheduleEnabled: Bool = false
    @Published var scheduledTime: Date = Calendar.current.date(bySettingHour: 1, minute: 0, second: 0, of: Date()) ?? Date()
    
    @Published var isDownloading: Bool = false
    @Published var isMerging: Bool = false
    @Published var statusLog: [String] = []
    @Published var progress: Double = 0.0
    @Published var savedFiles: [LocalSavedFile] = []
    @Published var alertMessage: String? = nil

    // إعدادات الميزات القابلة للتشغيل والإيقاف
    @AppStorage("setting_deduplication") var enableDeduplication: Bool = true
    @AppStorage("setting_storyMode") var enableStoryMode: Bool = true
    @AppStorage("setting_enableMerger") var enableVideoMerger: Bool = true
    @AppStorage("setting_biometricLock") var enableBiometricLock: Bool = false
    @AppStorage("setting_lockVaultOnly") var lockVaultOnly: Bool = true
    @AppStorage("setting_autoCleanup") var enableAutoCleanup: Bool = false
    @AppStorage("setting_cleanupDays") var cleanupDays: Int = 30
    @AppStorage("setting_startMuted") var startVideosMuted: Bool = false
    @AppStorage("setting_haptics") var enableHaptics: Bool = true
    @AppStorage("setting_imageStoryDuration") var imageStoryDuration: Double = 4.0

    private let accountsKey = "SavedSnapAccounts"
    private let downloadedHistoryKey = "SnapVaultDownloadedHistory"

    init() {
        loadAccounts()
        if enableAutoCleanup {
            performAutoCleanup()
        }
        loadSavedFiles()
    }

    func triggerHaptic() {
        guard enableHaptics else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    func addAccount(_ username: String) {
        let clean = username
            .replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !clean.isEmpty, !accounts.contains(where: { $0.username == clean }) else { return }
        accounts.append(SnapAccount(username: clean))
        triggerHaptic()
        log("➕ تمت إضافة الحساب: @\(clean)")
    }

    func confirmDeleteAccount(_ account: SnapAccount) {
        accounts.removeAll { $0.id == account.id }
        triggerHaptic()
        log("🗑️ تم حذف الحساب: @\(account.username)")
    }

    func moveAccountUp(at index: Int) {
        guard index > 0 else { return }
        accounts.swapAt(index, index - 1)
        triggerHaptic()
    }

    func moveAccountDown(at index: Int) {
        guard index < accounts.count - 1 else { return }
        accounts.swapAt(index, index + 1)
        triggerHaptic()
    }

    func selectAllAccounts(_ select: Bool) {
        for i in 0..<accounts.count {
            accounts[i].isSelected = select
        }
        triggerHaptic()
    }

    private func saveAccounts() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: accountsKey)
        }
    }

    private func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([SnapAccount].self, from: data) {
            accounts = decoded
        }
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        statusLog.insert("[\(formatter.string(from: Date()))] \(message)", at: 0)
    }

    // سجل منع التكرار الذكي
    private func isAlreadyDownloaded(username: String, timestamp: String, mediaURL: String) -> Bool {
        let cleanURL = mediaURL.components(separatedBy: "?").first ?? mediaURL
        let key = "\(username)_\(timestamp)_\(cleanURL)"
        let history = UserDefaults.standard.stringArray(forKey: downloadedHistoryKey) ?? []
        return history.contains(key)
    }

    private func markAsDownloaded(username: String, timestamp: String, mediaURL: String) {
        let cleanURL = mediaURL.components(separatedBy: "?").first ?? mediaURL
        let key = "\(username)_\(timestamp)_\(cleanURL)"
        var history = UserDefaults.standard.stringArray(forKey: downloadedHistoryKey) ?? []
        if !history.contains(key) {
            history.append(key)
            UserDefaults.standard.set(history, forKey: downloadedHistoryKey)
        }
    }

    func clearDeduplicationHistory() {
        UserDefaults.standard.removeObject(forKey: downloadedHistoryKey)
        triggerHaptic()
        alertMessage = "✅ تم تصفير سجل منع التكرار، يمكنك الآن إعادة تحميل جميع الستوريات."
    }

    // تحميل حساب واحد محدد بالذات
    func downloadSingleAccount(_ account: SnapAccount) async {
        guard !isDownloading else { return }
        isDownloading = true
        triggerHaptic()
        log("🔍 بدء فحص حساب واحد: @\(account.username)...")

        do {
            let items = try await fetchPublicStoryMedia(for: account.username)
            let filteredItems = items.filter { item in
                switch mediaFilter {
                case .both: return true
                case .imagesOnly: return !item.isVideo
                case .videosOnly: return item.isVideo
                }
            }

            if filteredItems.isEmpty {
                log("ℹ️ لا توجد ستوريات مطابقة في @\(account.username)")
            } else {
                var savedCount = 0
                log("⬇️ جاري فحص وحفظ \(filteredItems.count) عنصر من @\(account.username)...")
                for (itemIndex, media) in filteredItems.enumerated() {
                    if enableDeduplication && isAlreadyDownloaded(username: account.username, timestamp: media.timestamp, mediaURL: media.url.absoluteString) {
                        continue
                    }
                    try await downloadToAppStorage(media: media, username: account.username, index: itemIndex + 1)
                    markAsDownloaded(username: account.username, timestamp: media.timestamp, mediaURL: media.url.absoluteString)
                    savedCount += 1
                }
                if savedCount == 0 {
                    log("ℹ️ كل ستوريات @\(account.username) محملة مسبقاً (منع التكرار مفعل)")
                } else {
                    log("✅ تم حفظ \(savedCount) ستوري جديد من @\(account.username)!")
                }
            }
        } catch {
            log("❌ تعذر جلب @\(account.username): تأكد أن الحساب عام وعنده ستوري")
        }

        loadSavedFiles()
        isDownloading = false
    }

    // التحميل الجماعي بالترتيب للحسابات المحددة يدوياً
    func startBatchDownload() async {
        let selectedAccounts = accounts.filter { $0.isSelected }
        guard !selectedAccounts.isEmpty else {
            log("⚠️ لم تقم بتحديد أي حساب للتحميل.")
            return
        }

        isDownloading = true
        progress = 0.0
        triggerHaptic()
        log("🚀 بدء التحميل الجماعي لـ \(selectedAccounts.count) حسابات المحددة بالترتيب...")

        for (index, account) in selectedAccounts.enumerated() {
            log("🔍 [\(index + 1)/\(selectedAccounts.count)] فحص حساب: @\(account.username)...")
            do {
                let items = try await fetchPublicStoryMedia(for: account.username)
                let filteredItems = items.filter { item in
                    switch mediaFilter {
                    case .both: return true
                    case .imagesOnly: return !item.isVideo
                    case .videosOnly: return item.isVideo
                    }
                }

                if filteredItems.isEmpty {
                    log("ℹ️ لا توجد ستوريات في @\(account.username)")
                } else {
                    var savedCount = 0
                    log("⬇️ حفظ عناصر من @\(account.username)...")
                    for (itemIndex, media) in filteredItems.enumerated() {
                        if enableDeduplication && isAlreadyDownloaded(username: account.username, timestamp: media.timestamp, mediaURL: media.url.absoluteString) {
                            continue
                        }
                        try await downloadToAppStorage(media: media, username: account.username, index: itemIndex + 1)
                        markAsDownloaded(username: account.username, timestamp: media.timestamp, mediaURL: media.url.absoluteString)
                        savedCount += 1
                    }
                    log("✅ انتهى @\(account.username) (حُفظ \(savedCount) جديد)")
                }
            } catch {
                log("❌ خطأ في @\(account.username): تخطي...")
            }
            progress = Double(index + 1) / Double(selectedAccounts.count)
        }

        loadSavedFiles()
        log("🎉 اكتمل تحميل الحسابات المحددة بالترتيب!")
        isDownloading = false
    }

    // دالة السحب الأصلية الشغالة 100% كما هي في كودك
    private func fetchPublicStoryMedia(for username: String) async throws -> [SnapMediaItem] {
        guard let url = URL(string: "https://www.snapchat.com/add/\(username)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8),
              let startRange = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
              let endRange = html.range(of: "</script>", range: startRange.upperBound..<html.endIndex) else {
            throw URLError(.cannotParseResponse)
        }

        let jsonString = String(html[startRange.upperBound..<endRange.lowerBound])
        guard let jsonData = jsonString.data(using: .utf8),
              let rootObj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let props = rootObj["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var results: [SnapMediaItem] = []
        if let story = pageProps["story"] as? [String: Any],
           let snapList = story["snapList"] as? [[String: Any]] {
            for snap in snapList {
                if let snapUrls = snap["snapUrls"] as? [String: Any],
                   let mediaUrlString = snapUrls["mediaUrl"] as? String,
                   let mediaUrl = URL(string: mediaUrlString) {
                    let mediaType = snap["snapMediaType"] as? Int ?? 0
                    let isVideo = (mediaType == 1)
                    let timestamp = String(describing: snap["timestampInSec"] ?? Int(Date().timeIntervalSince1970))
                    results.append(SnapMediaItem(url: mediaUrl, isVideo: isVideo, timestamp: timestamp))
                }
            }
        }
        return results
    }

    // تحويل التوقيت إلى تاريخ مقروء في اسم الملف: username_YYYY-MM-DD_HH-mm-ss_index
    private func formattedDateForFileName(from timestampStr: String) -> String {
        let date: Date
        if let unix = Double(timestampStr), unix > 1_000_000_000 {
            date = Date(timeIntervalSince1970: unix)
        } else {
            date = Date()
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    private func downloadToAppStorage(media: SnapMediaItem, username: String, index: Int) async throws {
        let (tempURL, _) = try await URLSession.shared.download(from: media.url)
        let ext = media.isVideo ? "mp4" : "jpg"
        let readableDate = formattedDateForFileName(from: media.timestamp)
        let fileName = "\(username)_\(readableDate)_\(index).\(ext)"

        let fileManager = FileManager.default
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let rootDir = docsDir.appendingPathComponent("SnapVault", isDirectory: true)

        var targetFolders: [URL] = []
        let mediaSubFolder = media.isVideo ? "Videos" : "Images"

        if saveMode == .separate || saveMode == .both {
            let userDir = rootDir.appendingPathComponent("Accounts/\(username)/\(mediaSubFolder)", isDirectory: true)
            targetFolders.append(userDir)
        }

        if saveMode == .combined || saveMode == .both {
            let allDir = rootDir.appendingPathComponent("All_Accounts/\(mediaSubFolder)", isDirectory: true)
            targetFolders.append(allDir)
        }

        for folder in targetFolders {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destinationURL = folder.appendingPathComponent(fileName)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.copyItem(at: tempURL, to: destinationURL)
            }
        }
    }

    func loadSavedFiles() {
        let fileManager = FileManager.default
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let rootDir = docsDir.appendingPathComponent("SnapVault", isDirectory: true)

        guard let enumerator = fileManager.enumerator(
            at: rootDir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
        ) else { return }

        var loaded: [LocalSavedFile] = []
        var seenNames = Set<String>()

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy/MM/dd hh:mm a"

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "mp4" || ext == "jpg" {
                let name = fileURL.lastPathComponent
                if !seenNames.contains(name) {
                    seenNames.insert(name)
                    let accountName = name.components(separatedBy: "_").first ?? "غير معروف"
                    let res = try? fileURL.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                    let creationDate = res?.creationDate ?? Date()
                    let fileSize = Int64(res?.fileSize ?? 0)

                    loaded.append(LocalSavedFile(
                        url: fileURL,
                        fileName: name,
                        isVideo: ext == "mp4",
                        accountName: accountName,
                        dateFormatted: displayFormatter.string(from: creationDate),
                        creationDate: creationDate,
                        fileSize: fileSize
                    ))
                }
            }
        }
        savedFiles = loaded.sorted { $0.creationDate > $1.creationDate }
    }

    func exportSingleFileToPhotos(_ file: LocalSavedFile) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self.alertMessage = "⚠️ يرجى السماح للتطبيق بالوصول للصور من إعدادات الآيفون."
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                if file.isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file.url)
                } else if let data = try? Data(contentsOf: file.url),
                          let image = UIImage(data: data) {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }) { success, error in
                Task { @MainActor in
                    if success {
                        self.alertMessage = "✅ تم حفظ المقطع في ألبوم الاستوديو!"
                    } else {
                        self.alertMessage = "❌ فشل الحفظ: \(error?.localizedDescription ?? "")"
                    }
                }
            }
        }
    }

    // حذف الملف من جميع المجلدات الداخلية (العام والخاص)
    func deleteFile(_ file: LocalSavedFile) {
        let fileManager = FileManager.default
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let rootDir = docsDir.appendingPathComponent("SnapVault", isDirectory: true)

        if let enumerator = fileManager.enumerator(at: rootDir, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == file.fileName {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }
        triggerHaptic()
        loadSavedFiles()
    }

    func deleteAllFiles() {
        let fileManager = FileManager.default
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let rootDir = docsDir.appendingPathComponent("SnapVault", isDirectory: true)
        try? fileManager.removeItem(at: rootDir)
        triggerHaptic()
        loadSavedFiles()
        alertMessage = "🗑️ تم حذف جميع المحفوظات بنجاح."
    }

    func formattedTotalStorage() -> String {
        let total = savedFiles.reduce(Int64(0)) { $0 + $1.fileSize }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }

    func performAutoCleanup() {
        let fileManager = FileManager.default
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let rootDir = docsDir.appendingPathComponent("SnapVault", isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: rootDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -cleanupDays, to: Date()) ?? Date()

        for case let fileURL as URL in enumerator {
            if let created = (try? fileURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
               created < cutoff {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    // دمج الفيديوهات في مقطع واحد طويل
    func mergeVideos(files: [LocalSavedFile], accountLabel: String) {
        let videos = files.filter { $0.isVideo }.sorted { $0.creationDate < $1.creationDate }
        guard videos.count >= 2 else { return }

        isMerging = true
        triggerHaptic()

        Task {
            let composition = AVMutableComposition()
            guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                self.isMerging = false
                return
            }

            var currentTime = CMTime.zero

            for item in videos {
                let asset = AVURLAsset(url: item.url)
                let duration = (try? await asset.load(.duration)) ?? .zero
                guard duration > .zero else { continue }

                if let vTrack = (try? await asset.loadTracks(withMediaType: .video))?.first {
                    try? compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vTrack, at: currentTime)
                    if let transform = try? await vTrack.load(.preferredTransform) {
                        compVideoTrack.preferredTransform = transform
                    }
                }
                if let aTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first {
                    try? compAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: aTrack, at: currentTime)
                }
                currentTime = CMTimeAdd(currentTime, duration)
            }

            let cleanLabel = accountLabel == "الكل" ? "All" : accountLabel
            let dateStr = formattedDateForFileName(from: "")
            let mergedName = "\(cleanLabel)-مدمج_\(dateStr)_\(videos.count).mp4"

            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let mergedFolder = docsDir.appendingPathComponent("SnapVault/All_Accounts/Videos", isDirectory: true)
            try? FileManager.default.createDirectory(at: mergedFolder, withIntermediateDirectories: true)
            let outputURL = mergedFolder.appendingPathComponent(mergedName)

            if let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) {
                export.outputURL = outputURL
                export.outputFileType = .mp4
                await export.export()
            }

            self.isMerging = false
            self.loadSavedFiles()
            self.alertMessage = "✅ تم دمج \(videos.count) مقاطع فيديو في ملف واحد بنجاح!"
        }
    }

    func scheduleDailyDownload() {
        let request = BGProcessingTaskRequest(identifier: "com.snapvault.dailyfetch")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        var components = Calendar.current.dateComponents([.hour, .minute], from: scheduledTime)
        components.second = 0
        if let nextDate = Calendar.current.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime) {
            request.earliestBeginDate = nextDate
            try? BGTaskScheduler.shared.submit(request)
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            log("⏰ تم ضبط الجدولة التلقائية يومياً الساعة \(formatter.string(from: nextDate))")
        }
    }
}

// MARK: - 3. مشغل الوسائط الكامل بملء الشاشة ووضع القصة (Full Screen Player)

struct NativeFullScreenVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    let isMuted: Bool
    var onEnded: (() -> Void)?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        player.isMuted = isMuted
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            onEnded?()
        }

        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

struct FullScreenStoryPlayer: View {
    @ObservedObject var manager: SnapStoryManager
    let files: [LocalSavedFile]
    @State var currentIndex: Int
    @Environment(\.dismiss) var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var imageTimer: Timer? = nil

    var currentFile: LocalSavedFile {
        files[min(max(currentIndex, 0), files.count - 1)]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // عرض الفيديو أو الصورة مباشرة من ذاكرة التطبيق بملء الشاشة
            if currentFile.isVideo {
                NativeFullScreenVideoPlayer(
                    url: currentFile.url,
                    isMuted: manager.startVideosMuted,
                    onEnded: {
                        if manager.enableStoryMode {
                            nextItem()
                        }
                    }
                )
                .id(currentFile.id)
                .ignoresSafeArea()
            } else {
                if let data = try? Data(contentsOf: currentFile.url),
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { val in scale = max(1.0, min(val, 4.0)) }
                                .onEnded { _ in withAnimation { if scale < 1.2 { scale = 1.0 } } }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation { scale = scale > 1.0 ? 1.0 : 2.5 }
                        }
                        .onAppear { startImageTimer() }
                        .onChange(of: currentIndex) { _ in
                            scale = 1.0
                            startImageTimer()
                        }
                } else {
                    Text("تعذر فتح الصورة")
                        .foregroundColor(.white)
                }
            }

            // شريط التحكم العلوي والسفلي
            VStack {
                if manager.enableStoryMode && files.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(0..<min(files.count, 30), id: \.self) { idx in
                            Capsule()
                                .fill(idx <= currentIndex ? Color.yellow : Color.white.opacity(0.3))
                                .frame(height: 3)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                HStack {
                    Button(action: {
                        imageTimer?.invalidate()
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }

                    Spacer()

                    VStack(spacing: 2) {
                        Text("@\(currentFile.accountName)")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(currentFile.fileName)
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 14) {
                        Button(action: { manager.exportSingleFileToPhotos(currentFile) }) {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                        }

                        ShareLink(item: currentFile.url) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.yellow)
                        }
                    }
                }
                .padding()
                .background(Color.black.opacity(0.6))

                Spacer()

                if files.count > 1 {
                    HStack {
                        Button(action: previousItem) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                Text("السابق")
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(currentIndex > 0 ? .white : .gray)
                            .cornerRadius(20)
                        }
                        .disabled(currentIndex == 0)

                        Spacer()

                        Text("\(currentIndex + 1) / \(files.count)")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(.yellow)
                            .cornerRadius(14)

                        Spacer()

                        Button(action: nextItem) {
                            HStack(spacing: 4) {
                                Text("التالي")
                                Image(systemName: "chevron.left")
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(currentIndex < files.count - 1 ? .white : .gray)
                            .cornerRadius(20)
                        }
                        .disabled(currentIndex >= files.count - 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 35)
                }
            }
        }
        .onDisappear { imageTimer?.invalidate() }
    }

    private func startImageTimer() {
        imageTimer?.invalidate()
        guard manager.enableStoryMode, !currentFile.isVideo else { return }
        imageTimer = Timer.scheduledTimer(withTimeInterval: manager.imageStoryDuration, repeats: false) { _ in
            nextItem()
        }
    }

    private func nextItem() {
        imageTimer?.invalidate()
        if currentIndex < files.count - 1 {
            withAnimation { currentIndex += 1 }
        } else if manager.enableStoryMode {
            dismiss()
        }
    }

    private func previousItem() {
        imageTimer?.invalidate()
        if currentIndex > 0 {
            withAnimation { currentIndex -= 1 }
        }
    }
}

// صورة مصغرة خفيفة وسريعة للفيديو في الشبكة بدل المشغل المصغر الثقيل
struct VideoCardThumbnail: View {
    let url: URL
    @State private var thumbnail: UIImage? = nil

    var body: some View {
        ZStack {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black.opacity(0.4)
            }

            Image(systemName: "play.circle.fill")
                .font(.system(size: 42))
                .foregroundColor(.white.opacity(0.9))
                .shadow(radius: 4)
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let asset = AVAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                let time = CMTime(seconds: 0.2, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    let uiImg = UIImage(cgImage: cgImage)
                    DispatchQueue.main.async { self.thumbnail = uiImg }
                }
            }
        }
    }
}

// MARK: - 4. واجهة المستخدم الرئيسية (UI)

struct ContentView: View {
    @StateObject private var manager = SnapStoryManager()
    @State private var isUnlocked: Bool = false

    var body: some View {
        ZStack {
            if manager.enableBiometricLock && !manager.lockVaultOnly && !isUnlocked {
                BiometricLockView(isUnlocked: $isUnlocked)
            } else {
                TabView {
                    DownloaderHomeView(manager: manager)
                        .tabItem {
                            Label("الحسابات والتحميل", systemImage: "arrow.down.circle.fill")
                        }

                    Group {
                        if manager.enableBiometricLock && manager.lockVaultOnly && !isUnlocked {
                            BiometricLockView(isUnlocked: $isUnlocked)
                        } else {
                            InternalGalleryView(manager: manager)
                        }
                    }
                    .tabItem {
                        Label("محفوظات التطبيق (\(manager.savedFiles.count))", systemImage: "folder.fill")
                    }

                    AppSettingsView(manager: manager)
                        .tabItem {
                            Label("الإعدادات", systemImage: "gearshape.fill")
                        }
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear {
            if !manager.enableBiometricLock {
                isUnlocked = true
            }
        }
        .alert(item: Binding(
            get: { manager.alertMessage.map { AlertItem(message: $0) } },
            set: { _ in manager.alertMessage = nil }
        )) { item in
            Alert(title: Text("تنبيه"), message: Text(item.message), dismissButton: .default(Text("حسناً")))
        }
    }
}

struct BiometricLockView: View {
    @Binding var isUnlocked: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "faceid")
                .font(.system(size: 64))
                .foregroundColor(.yellow)
            Text("المحتوى محمي ببصمة الوجه")
                .font(.title2.bold())
            Button("فتح القفل الآن") {
                authenticate()
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundColor(.black)
        }
        .onAppear { authenticate() }
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "فتح قفل المحفوظات") { success, _ in
                DispatchQueue.main.async { isUnlocked = success }
            }
        } else {
            isUnlocked = true
        }
    }
}

// MARK: - 5. تبويب الحسابات والتحميل (مع الترتيب وتأكيد الحذف)

struct DownloaderHomeView: View {
    @ObservedObject var manager: SnapStoryManager
    @State private var usernameInput: String = ""
    @State private var accountPendingDeletion: SnapAccount? = nil
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("إدارة الحسابات (\(manager.accounts.count) حساب)")) {
                    HStack {
                        TextField("اكتب اليوزر (مثال: snapchat)", text: $usernameInput)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button(action: {
                            manager.addAccount(usernameInput)
                            usernameInput = ""
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.yellow)
                        }
                    }

                    if !manager.accounts.isEmpty {
                        HStack(spacing: 12) {
                            Button("تحديد الكل") { manager.selectAllAccounts(true) }
                                .buttonStyle(.bordered)
                                .font(.caption.bold())

                            Button("إلغاء الكل") { manager.selectAllAccounts(false) }
                                .buttonStyle(.bordered)
                                .font(.caption.bold())
                            
                            Spacer()
                            
                            Text("المحدد: \(manager.accounts.filter { $0.isSelected }.count)")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    if manager.accounts.isEmpty {
                        Text("لم تقم بإضافة حسابات بعد.").foregroundColor(.secondary)
                    } else {
                        ForEach(Array(manager.accounts.enumerated()), id: \.element.id) { index, account in
                            HStack(spacing: 8) {
                                // أزرار تحريك الحساب للأعلى والأسفل
                                VStack(spacing: 4) {
                                    Button(action: { manager.moveAccountUp(at: index) }) {
                                        Image(systemName: "chevron.up")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(index > 0 ? .primary : .gray.opacity(0.3))
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                    .disabled(index == 0)

                                    Button(action: { manager.moveAccountDown(at: index) }) {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(index < manager.accounts.count - 1 ? .primary : .gray.opacity(0.3))
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                    .disabled(index >= manager.accounts.count - 1)
                                }
                                .frame(width: 20)

                                // زر التحديد
                                Button(action: {
                                    manager.accounts[index].isSelected.toggle()
                                    manager.triggerHaptic()
                                }) {
                                    Image(systemName: account.isSelected ? "checkmark.square.fill" : "square")
                                        .foregroundColor(account.isSelected ? .blue : .gray)
                                        .font(.title3)
                                }
                                .buttonStyle(BorderlessButtonStyle())

                                Text("@\(account.username)")
                                    .bold()
                                    .lineLimit(1)

                                Spacer()

                                // زر تحميل الحساب لحاله
                                Button(action: {
                                    Task { await manager.downloadSingleAccount(account) }
                                }) {
                                    Text("تحميل هذا لحاله")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color.yellow.opacity(0.3))
                                        .foregroundColor(.primary)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .disabled(manager.isDownloading)

                                // زر الحذف مع نافذة تأكيد لمنع اللمس بالخطأ
                                Button(action: {
                                    accountPendingDeletion = account
                                    showDeleteConfirm = true
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                        .padding(.leading, 4)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    }
                }

                Section(header: Text("إعدادات التخزين والفلترة")) {
                    Picker("نوع الوسائط", selection: $manager.mediaFilter) {
                        ForEach(MediaFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }

                    Picker("طريقة تنظيم المجلدات", selection: $manager.saveMode) {
                        ForEach(SaveMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }

                Section(header: Text("الجدولة التلقائية")) {
                    Toggle("تفعيل التحميل التلقائي اليومي", isOn: $manager.isScheduleEnabled)
                        .onChange(of: manager.isScheduleEnabled) { enabled in
                            if enabled { manager.scheduleDailyDownload() }
                        }

                    if manager.isScheduleEnabled {
                        DatePicker("وقت التحميل", selection: $manager.scheduledTime, displayedComponents: .hourAndMinute)
                            .onChange(of: manager.scheduledTime) { _ in
                                manager.scheduleDailyDownload()
                            }
                    }
                }

                Section {
                    Button(action: {
                        Task { await manager.startBatchDownload() }
                    }) {
                        HStack {
                            Spacer()
                            if manager.isDownloading {
                                ProgressView().padding(.trailing, 6)
                                Text("جاري التحميل... \(Int(manager.progress * 100))%")
                            } else {
                                Image(systemName: "list.bullet.rectangle.portrait.fill")
                                Text("تحميل الحسابات المحددة يدوياً بالترتيب")
                                    .bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(manager.isDownloading || manager.accounts.isEmpty)
                }

                Section(header: HStack {
                    Text("سجل العمليات المباشر")
                    Spacer()
                    if !manager.statusLog.isEmpty {
                        Button("مسح") { manager.statusLog.removeAll() }
                            .font(.caption)
                    }
                }) {
                    if manager.statusLog.isEmpty {
                        Text("جاهز للعمل...").font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                    } else {
                        ForEach(manager.statusLog, id: \.self) { log in
                            Text(log).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("محمل السناب")
            .alert("تأكيد حذف الحساب", isPresented: $showDeleteConfirm, presenting: accountPendingDeletion) { account in
                Button("حذف @\(account.username)", role: .destructive) {
                    manager.confirmDeleteAccount(account)
                }
                Button("إلغاء", role: .cancel) {
                    accountPendingDeletion = nil
                }
            } message: { account in
                Text("هل أنت متأكد من حذف الحساب @\(account.username) من القائمة؟")
            }
        }
    }
}

// MARK: - 6. تبويب محفوظات التطبيق (مع المشغل الكامل والدمج)

struct InternalGalleryView: View {
    @ObservedObject var manager: SnapStoryManager
    @State private var selectedAccountFilter: String = "الكل"
    @State private var selectedTypeFilter: MediaFilter = .both
    @State private var showFullScreenPlayer: Bool = false
    @State private var selectedFileIndex: Int = 0

    var availableAccounts: [String] {
        let names = Set(manager.savedFiles.map { $0.accountName })
        return ["الكل"] + names.sorted()
    }

    var filteredFiles: [LocalSavedFile] {
        manager.savedFiles.filter { file in
            let matchAccount = (selectedAccountFilter == "الكل" || file.accountName == selectedAccountFilter)
            let matchType: Bool
            switch selectedTypeFilter {
            case .both: matchType = true
            case .imagesOnly: matchType = !file.isVideo
            case .videosOnly: matchType = file.isVideo
            }
            return matchAccount && matchType
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                HStack {
                    Picker("الحساب", selection: $selectedAccountFilter) {
                        ForEach(availableAccounts, id: \.self) { acc in
                            Text(acc == "الكل" ? "كل الحسابات" : "@\(acc)").tag(acc)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())

                    Spacer()

                    Picker("النوع", selection: $selectedTypeFilter) {
                        ForEach(MediaFilter.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                .padding(.horizontal)

                // أزرار عرض القصة ودمج المقاطع
                if !filteredFiles.isEmpty {
                    HStack(spacing: 10) {
                        if manager.enableStoryMode {
                            Button(action: {
                                selectedFileIndex = 0
                                showFullScreenPlayer = true
                            }) {
                                Label("تشغيل الكل كقصة", systemImage: "play.fill")
                                    .font(.caption.bold())
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.yellow)
                                    .foregroundColor(.black)
                                    .cornerRadius(10)
                            }
                        }

                        if manager.enableVideoMerger && filteredFiles.filter({ $0.isVideo }).count >= 2 {
                            Button(action: {
                                manager.mergeVideos(files: filteredFiles, accountLabel: selectedAccountFilter)
                            }) {
                                Label(manager.isMerging ? "جاري الدمج..." : "دمج الفيديوهات (\(filteredFiles.filter({ $0.isVideo }).count))", systemImage: "film.stack.fill")
                                    .font(.caption.bold())
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.blue.opacity(0.25))
                                    .foregroundColor(.blue)
                                    .cornerRadius(10)
                            }
                            .disabled(manager.isMerging)
                        }
                    }
                    .padding(.horizontal)
                }

                if filteredFiles.isEmpty {
                    Spacer()
                    Text("لا توجد ملفات محفوظة بعد.").foregroundColor(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(Array(filteredFiles.enumerated()), id: \.element.id) { index, file in
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .topLeading) {
                                        if file.isVideo {
                                            VideoCardThumbnail(url: file.url)
                                                .frame(height: 210)
                                                .clipped()
                                                .cornerRadius(10)
                                        } else if let data = try? Data(contentsOf: file.url),
                                                  let uiImage = UIImage(data: data) {
                                            Image(uiImage: uiImage)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(height: 210)
                                                .clipped()
                                                .cornerRadius(10)
                                        }

                                        Text("@\(file.accountName)")
                                            .font(.caption2.bold())
                                            .padding(5)
                                            .background(Color.black.opacity(0.65))
                                            .foregroundColor(.white)
                                            .cornerRadius(6)
                                            .padding(6)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // فتح الفيديو أو الصورة مباشرة في المشغل الكامل بملء الشاشة
                                        manager.triggerHaptic()
                                        selectedFileIndex = index
                                        showFullScreenPlayer = true
                                    }

                                    // عرض اسم الملف (اسم الحساب + التاريخ)
                                    Text(file.fileName)
                                        .font(.caption2.bold())
                                        .lineLimit(1)

                                    Text(file.dateFormatted)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)

                                    HStack {
                                        Button(action: {
                                            manager.exportSingleFileToPhotos(file)
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "square.and.arrow.down.fill")
                                                Text("للاستوديو").font(.caption2.bold())
                                            }
                                            .padding(.vertical, 6)
                                            .frame(maxWidth: .infinity)
                                            .background(Color.blue)
                                            .foregroundColor(.white)
                                            .cornerRadius(8)
                                        }

                                        Button(action: {
                                            manager.deleteFile(file)
                                        }) {
                                            Image(systemName: "trash.fill")
                                                .foregroundColor(.red)
                                                .padding(6)
                                                .background(Color.red.opacity(0.15))
                                                .cornerRadius(8)
                                        }
                                    }
                                }
                                .padding(8)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("محفوظات التطبيق")
            .onAppear { manager.loadSavedFiles() }
            .fullScreenCover(isPresented: $showFullScreenPlayer) {
                FullScreenStoryPlayer(
                    manager: manager,
                    files: filteredFiles,
                    currentIndex: selectedFileIndex
                )
            }
        }
    }
}

// MARK: - 7. تبويب الإعدادات الشاملة والعامة

struct AppSettingsView: View {
    @ObservedObject var manager: SnapStoryManager
    @State private var showConfirmDeleteAll: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("تشغيل وإيقاف الميزات الذكية")) {
                    Toggle("منع تكرار التحميل الذكي", isOn: $manager.enableDeduplication)
                    Toggle("وضع القصة المتتابع (Story Mode)", isOn: $manager.enableStoryMode)
                    Toggle("إظهار أداة دمج الفيديوهات", isOn: $manager.enableVideoMerger)
                }

                Section(header: Text("الأمان والخصوصية (FaceID)")) {
                    Toggle("قفل التطبيق ببصمة الوجه", isOn: $manager.enableBiometricLock)
                    if manager.enableBiometricLock {
                        Toggle("قفل قسم المحفوظات فقط", isOn: $manager.lockVaultOnly)
                    }
                }

                Section(header: Text("إعدادات المشغل والعرض العامة")) {
                    Toggle("بدء الفيديو بدون صوت (Mute)", isOn: $manager.startVideosMuted)
                    Toggle("تفعيل الاهتزاز التفاعلي (Haptics)", isOn: $manager.enableHaptics)
                    Stepper("مدة عرض الصورة: \(Int(manager.imageStoryDuration)) ثواني", value: $manager.imageStoryDuration, in: 2...15, step: 1)
                }

                Section(header: Text("المساحة والتنظيف التلقائي")) {
                    HStack {
                        Text("المساحة المستخدمة حالياً")
                        Spacer()
                        Text(manager.formattedTotalStorage())
                            .bold()
                            .foregroundColor(.yellow)
                    }

                    Toggle("حذف المقاطع القديمة تلقائياً", isOn: $manager.enableAutoCleanup)
                    if manager.enableAutoCleanup {
                        Picker("حذف الأقدم من", selection: $manager.cleanupDays) {
                            Text("7 أيام").tag(7)
                            Text("14 يوماً").tag(14)
                            Text("30 يوماً").tag(30)
                            Text("60 يوماً").tag(60)
                        }
                    }

                    Button("تصفير سجل منع التكرار (لإعادة تحميل الكل)") {
                        manager.clearDeduplicationHistory()
                    }
                    .foregroundColor(.orange)

                    Button("حذف جميع المحفوظات نهائياً") {
                        showConfirmDeleteAll = true
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("الإعدادات")
            .alert("حذف جميع المحفوظات", isPresented: $showConfirmDeleteAll) {
                Button("نعم، احذف الكل", role: .destructive) {
                    manager.deleteAllFiles()
                }
                Button("إلغاء", role: .cancel) {}
            } message: {
                Text("هل أنت متأكد من مسح كافة الصور والفيديوهات المحفوظة داخل التطبيق؟")
            }
        }
    }
}

import SwiftUI
import AVKit
import AVFoundation
import LocalAuthentication
import Photos
import UIKit
import Network
import ImageIO

// MARK: - 1. Models

struct SnapAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var username: String
    var category: Int = 0 // 0: خانة 1, 1: خانة 2, 2: خانة 3
    var isSelectedForDownload: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, username, category, isSelectedForDownload
    }

    init(id: UUID = UUID(), username: String, category: Int = 0, isSelectedForDownload: Bool = true) {
        self.id = id
        self.username = username
        self.category = category
        self.isSelectedForDownload = isSelectedForDownload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.username = try container.decode(String.self, forKey: .username)
        self.category = try container.decodeIfPresent(Int.self, forKey: .category) ?? 0
        self.isSelectedForDownload = try container.decodeIfPresent(Bool.self, forKey: .isSelectedForDownload) ?? true
    }
}

struct FailedAccountItem: Identifiable, Equatable {
    var id: String { account.username.lowercased() }
    let account: SnapAccount
    let reason: String
}

struct MediaItem: Identifiable, Equatable, Hashable {
    let id: String
    let snapID: String
    let url: URL
    let isVideo: Bool
    let creationDate: Date
    let timestamp: TimeInterval
    let username: String
    let fileSize: Int64
}

struct PlayerSession: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let startIndex: Int
}

// MARK: - 2. فاحص الشبكة (لخيار التحميل عبر Wi-Fi فقط)

final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private(set) var isOnWiFi: Bool = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isOnWiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        }
        monitor.start(queue: DispatchQueue(label: "SnapVaultNetworkMonitor"))
    }
}

// MARK: - 3. كاش الصور المصغرة على القرص والرام (لحل ثقل الـ 2000+ ملف نهائياً)

final class ThumbnailCacheManager: @unchecked Sendable {
    static let shared = ThumbnailCacheManager()
    private let memoryCache = NSCache<NSString, UIImage>()
    private var durationCache: [String: String] = [:]
    private let diskCacheURL: URL
    private let durationFileURL: URL
    private let lock = NSLock()

    private init() {
        memoryCache.countLimit = 280
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = caches.appendingPathComponent("SnapVaultThumbnails", isDirectory: true)
        durationFileURL = caches.appendingPathComponent("SnapVaultDurations.json")
        if !FileManager.default.fileExists(atPath: diskCacheURL.path) {
            try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: durationFileURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            durationCache = dict
        }
    }

    func getThumbnail(for item: MediaItem) async -> (UIImage?, String?) {
        let key = item.id as NSString
        let safeDiskName = item.id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_") + ".jpg"
        let thumbFileURL = diskCacheURL.appendingPathComponent(safeDiskName)

        if let memImg = memoryCache.object(forKey: key) {
            let dur = getDuration(for: item.id)
            if !item.isVideo || dur != nil {
                return (memImg, dur)
            }
        }

        return await Task.detached(priority: .utility) { () -> (UIImage?, String?) in
            let manager = ThumbnailCacheManager.shared

            if FileManager.default.fileExists(atPath: thumbFileURL.path),
               let data = try? Data(contentsOf: thumbFileURL),
               let diskImg = UIImage(data: data) {
                manager.memoryCache.setObject(diskImg, forKey: key)
                if item.isVideo {
                    if let cachedDur = manager.getDuration(for: item.id) {
                        return (diskImg, cachedDur)
                    } else {
                        let asset = AVURLAsset(url: item.url)
                        let durStr = ThumbnailCacheManager.formatDuration(asset: asset)
                        manager.setDuration(durStr, for: item.id)
                        return (diskImg, durStr)
                    }
                }
                return (diskImg, nil)
            }

            if !item.isVideo {
                guard let downsampled = ThumbnailCacheManager.downsampleImage(at: item.url, maxPixelSize: 260) else {
                    return (nil, nil)
                }
                if let jpg = downsampled.jpegData(compressionQuality: 0.72) {
                    try? jpg.write(to: thumbFileURL, options: .atomic)
                }
                manager.memoryCache.setObject(downsampled, forKey: key)
                return (downsampled, nil)
            } else {
                let asset = AVURLAsset(url: item.url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 280, height: 280)

                var generatedImage: UIImage? = nil
                let time = CMTime(seconds: 0.05, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    let uiImg = UIImage(cgImage: cgImage)
                    generatedImage = uiImg
                    if let jpg = uiImg.jpegData(compressionQuality: 0.72) {
                        try? jpg.write(to: thumbFileURL, options: .atomic)
                    }
                    manager.memoryCache.setObject(uiImg, forKey: key)
                }

                let durStr = ThumbnailCacheManager.formatDuration(asset: asset)
                manager.setDuration(durStr, for: item.id)
                return (generatedImage, durStr)
            }
        }.value
    }

    func getDuration(for id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return durationCache[id]
    }

    func setDuration(_ dur: String, for id: String) {
        lock.lock()
        durationCache[id] = dur
        let snapshot = durationCache
        lock.unlock()
        if snapshot.count % 15 == 0, let encoded = try? JSONEncoder().encode(snapshot) {
            try? encoded.write(to: durationFileURL, options: .atomic)
        }
    }

    static func formatDuration(asset: AVURLAsset) -> String {
        let secsDouble = CMTimeGetSeconds(asset.duration)
        let totalSecs = secsDouble.isFinite ? Int(round(secsDouble)) : 0
        let mins = max(0, totalSecs) / 60
        let secs = max(0, totalSecs) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    static func downsampleImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - 4. محرك البقاء نشطاً في الخلفية (مطور ومضاد لتوقف التحميل عند الخروج)

final class BackgroundKeepAliveManager: NSObject, @unchecked Sendable {
    static let shared = BackgroundKeepAliveManager()
    private var audioPlayer: AVAudioPlayer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var keepAliveTimer: Timer?
    private(set) var isRunning: Bool = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    func startKeepAlive() {
        isRunning = true
        renewBackgroundTask()
        activateSubAudibleAudio()

        keepAliveTimer?.invalidate()
        let timer = Timer(timeInterval: 6.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            if self.audioPlayer?.isPlaying != true {
                self.activateSubAudibleAudio()
            }
            if UIApplication.shared.backgroundTimeRemaining < 25 {
                self.renewBackgroundTask()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    func stopKeepAlive() {
        isRunning = false
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        audioPlayer?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endCurrentBackgroundTask()
    }

    @objc private func handleDidEnterBackground() {
        guard isRunning else { return }
        renewBackgroundTask()
        activateSubAudibleAudio()
    }

    @objc private func handleWillEnterForeground() {
        guard isRunning else { return }
        activateSubAudibleAudio()
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.activateSubAudibleAudio()
        }
    }

    private func activateSubAudibleAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if audioPlayer == nil {
                let wavData = Self.makeSubAudibleWavData()
                let player = try AVAudioPlayer(data: wavData)
                player.numberOfLoops = -1
                player.volume = 0.02
                player.prepareToPlay()
                audioPlayer = player
            }
            if audioPlayer?.isPlaying == false {
                audioPlayer?.play()
            }
        } catch {
            print("KeepAlive Audio Error: \(error)")
        }
    }

    private func renewBackgroundTask() {
        let newID = UIApplication.shared.beginBackgroundTask(withName: "SnapVaultActiveDownload") { [weak self] in
            guard let self = self else { return }
            if self.isRunning {
                self.activateSubAudibleAudio()
            }
            self.endCurrentBackgroundTask()
        }
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
        }
        backgroundTaskID = newID
    }

    private func endCurrentBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private static func makeSubAudibleWavData() -> Data {
        let sampleRate: Int32 = 8000
        let numSamples: Int32 = 16000
        let dataSize: Int32 = numSamples * 2
        let fileSize: Int32 = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        data.append("WAVEfmt ".data(using: .ascii)!)
        var fmtSize: Int32 = 16
        var audioFormat: Int16 = 1
        var numChannels: Int16 = 1
        var byteRate: Int32 = sampleRate * 2
        var blockAlign: Int16 = 2
        var bitsPerSample: Int16 = 16
        data.append(withUnsafeBytes(of: fmtSize.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        for i in 0..<Int(numSamples) {
            let t = Double(i) / Double(sampleRate)
            let sample = Int16(sin(2.0 * .pi * 8.0 * t) * 45.0)
            data.append(withUnsafeBytes(of: sample.littleEndian) { Data($0) })
        }
        return data
    }
}

// MARK: - 5. دمج الفيديوهات (Video Merger Engine)

enum VideoMergerEngine {
    static func mergeVideos(items: [MediaItem], progressHandler: @escaping @Sendable (String) -> Void) async throws -> URL {
        let videoItems = items.filter { $0.isVideo }
        guard !videoItems.isEmpty else {
            throw NSError(domain: "SnapVault", code: 10, userInfo: [NSLocalizedDescriptionKey: "لا توجد مقاطع فيديو للدمج في القائمة المحددة"])
        }

        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "SnapVault", code: 11, userInfo: [NSLocalizedDescriptionKey: "تعذر إنشاء مسار الفيديو للدمج"])
        }
        let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var currentTime = CMTime.zero
        var firstTransformApplied = false

        for (idx, item) in videoItems.enumerated() {
            progressHandler("🎬 جاري دمج المقطع (\(idx + 1)/\(videoItems.count))...")

            let asset = AVURLAsset(url: item.url)
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0 else { continue }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let assetVideoTrack = videoTracks.first else { continue }

            let timeRange = CMTimeRange(start: .zero, duration: duration)
            try compVideoTrack.insertTimeRange(timeRange, of: assetVideoTrack, at: currentTime)

            if !firstTransformApplied {
                if let preferredTransform = try? await assetVideoTrack.load(.preferredTransform) {
                    compVideoTrack.preferredTransform = preferredTransform
                    firstTransformApplied = true
                }
            }

            if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
               let assetAudioTrack = audioTracks.first {
                try? compAudioTrack?.insertTimeRange(timeRange, of: assetAudioTrack, at: currentTime)
            }

            currentTime = CMTimeAdd(currentTime, duration)
        }

        progressHandler("⏳ جاري تصدير الفيديو المدمج النهائي...")

        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("SnapVault_Merged_\(Int(Date().timeIntervalSince1970)).mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "SnapVault", code: 12, userInfo: [NSLocalizedDescriptionKey: "تعذر بدء جلسة تصدير الفيديو"])
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        await exporter.export()

        if exporter.status == .completed {
            return outputURL
        } else {
            let errMsg = exporter.error?.localizedDescription ?? "حدث خطأ غير معروف أثناء دمج المقاطع"
            throw NSError(domain: "SnapVault", code: 13, userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
    }
}

// MARK: - 6. ViewModel (المحرك الأساسي + الفهرس السريع + جميع التعديلات الـ 12)

@MainActor
class VaultViewModel: ObservableObject {
    static let shared = VaultViewModel()

    @Published var accounts: [SnapAccount] = []
    @Published var failedAccounts: [FailedAccountItem] = []
    @Published var logs: [String] = []

    @Published var isDownloading: Bool = false
    @Published var isPaused: Bool = false
    @Published var progressText: String = ""

    @Published private(set) var mediaByUser: [String: [MediaItem]] = [:]
    @Published private(set) var allIndexedItems: [MediaItem] = []
    @Published private(set) var cachedVaultSizeText: String = "جاري الحساب..."
    @Published var isIndexingMedia: Bool = false

    private var downloadedSnapIDsByUser: [String: Set<String>] = [:]

    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    @Published var autoDownloadEnabled: Bool = false
    @Published var autoDownloadHour: Int = 1
    @Published var autoDownloadMinute: Int = 0
    @Published var autoDownloadTargetCategory: Int = -1
    @Published var useFaceID: Bool = false
    @Published var autoCleanEnabled: Bool = false
    @Published var autoCleanDays: Int = 7

    @Published var wifiOnlyDownload: Bool = false
    @Published var keepScreenAwake: Bool = true
    @Published var autoAdvancePlayer: Bool = true
    @Published var startVideosMuted: Bool = false
    @Published var hapticOnComplete: Bool = true
    @Published var hideEmptyFolders: Bool = false

    @Published var isUnlocked: Bool = true

    private var downloadTask: Task<Void, Never>?
    private var lastAutoDownloadDateKey = "SnapVault_LastAutoRunDate"

    init() {
        _ = NetworkMonitor.shared
        loadAccountsPersistently()
        loadSettings()
        if useFaceID {
            isUnlocked = false
        }
        rebuildMediaIndexInBackground(performCleanupAfter: autoCleanEnabled)
    }

    func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: Date())
        logs.insert("[\(timeStr)] \(text)", at: 0)
        if logs.count > 150 {
            logs.removeLast()
        }
    }

    // MARK: - حفظ دائم للحسابات ضد الضياع عند التحديث + نسخ واستعادة

    private var accountsBackupFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SnapVault_Accounts_Backup.json")
    }

    private var legacyAccountsFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("accounts.json")
    }

    func loadAccountsPersistently() {
        var loaded: [SnapAccount] = []

        if let fileData = try? Data(contentsOf: accountsBackupFileURL),
           let decoded = try? JSONDecoder().decode([SnapAccount].self, from: fileData),
           !decoded.isEmpty {
            loaded = decoded
        } else if let udData = UserDefaults.standard.data(forKey: "SnapVault_Accounts"),
                  let decoded = try? JSONDecoder().decode([SnapAccount].self, from: udData),
                  !decoded.isEmpty {
            loaded = decoded
        } else if let legData = try? Data(contentsOf: legacyAccountsFileURL),
                  let decoded = try? JSONDecoder().decode([SnapAccount].self, from: legData),
                  !decoded.isEmpty {
            loaded = decoded
        }

        if let folderNames = try? FileManager.default.contentsOfDirectory(at: baseVaultDirectory, includingPropertiesForKeys: nil) {
            for folderURL in folderNames where folderURL.hasDirectoryPath {
                let folderUser = folderURL.lastPathComponent
                guard !folderUser.hasPrefix(".") else { continue }
                if !loaded.contains(where: { $0.username.lowercased() == folderUser.lowercased() }) {
                    loaded.append(SnapAccount(username: folderUser, category: 0, isSelectedForDownload: true))
                }
            }
        }

        accounts = loaded
        saveAccounts()
    }

    func saveAccounts() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: "SnapVault_Accounts")
            try? encoded.write(to: accountsBackupFileURL, options: .atomic)
        }
    }

    func exportAccountsToClipboard() -> String {
        struct ExportItem: Codable {
            let username: String
            let category: Int
            let isSelected: Bool
        }
        let items = accounts.map { ExportItem(username: $0.username, category: $0.category, isSelected: $0.isSelectedForDownload) }
        if let data = try? JSONEncoder().encode(items),
           let jsonStr = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = jsonStr
            return "تم نسخ \(accounts.count) حساب مع تقسيماتها وترتيبها إلى الحافظة بنجاح ✅"
        }
        return "تعذر نسخ الحسابات"
    }

    func importAccountsFromClipboard() -> String {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "الحافظة فارغة! انسخ كود الحسابات أو قائمة اليوزرات أولاً."
        }

        struct ExportItem: Codable {
            let username: String
            let category: Int
            let isSelected: Bool?
        }

        var addedCount = 0

        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ExportItem].self, from: data) {
            for item in decoded {
                let clean = item.username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
                guard !clean.isEmpty else { continue }
                let safeCat = min(max(0, item.category), 2)
                if let idx = accounts.firstIndex(where: { $0.username.lowercased() == clean.lowercased() }) {
                    accounts[idx].category = safeCat
                } else {
                    accounts.append(SnapAccount(username: clean, category: safeCat, isSelectedForDownload: item.isSelected ?? true))
                    addedCount += 1
                }
            }
            saveAccounts()
            return "تمت استعادة وتحديث الحسابات بنجاح (أضيف \(addedCount) حساب جديد) ✅"
        } else {
            let separators = CharacterSet.newlines.union(.whitespaces).union(CharacterSet(charactersIn: ",;"))
            let lines = raw.components(separatedBy: separators)
            for word in lines {
                let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "https://www.snapchat.com/add/", with: "")
                    .replacingOccurrences(of: "@", with: "")
                    .replacingOccurrences(of: "/", with: "")
                guard clean.count >= 2 else { continue }
                if !accounts.contains(where: { $0.username.lowercased() == clean.lowercased() }) {
                    accounts.append(SnapAccount(username: clean, category: 0, isSelectedForDownload: true))
                    addedCount += 1
                }
            }
            saveAccounts()
            return addedCount > 0 ? "تم استيراد \(addedCount) حساب من النص بنجاح ✅" : "لم يتم العثور على حسابات جديدة للاستيراد"
        }
    }

    func accounts(for category: Int) -> [SnapAccount] {
        accounts.filter { $0.category == category }
    }

    func selectedAccounts(for category: Int) -> [SnapAccount] {
        accounts.filter { $0.category == category && $0.isSelectedForDownload }
    }

    var allSelectedAccounts: [SnapAccount] {
        accounts.filter { $0.isSelectedForDownload }
    }

    func toggleAccountSelection(_ account: SnapAccount) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx].isSelectedForDownload.toggle()
            saveAccounts()
        }
    }

    func setCategorySelection(_ category: Int, selected: Bool) {
        for idx in accounts.indices where accounts[idx].category == category {
            accounts[idx].isSelectedForDownload = selected
        }
        saveAccounts()
    }

    func addAccount(username: String, to category: Int) {
        let clean = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://www.snapchat.com/add/", with: "")
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "/", with: "")
        guard !clean.isEmpty else { return }
        if accounts.contains(where: { $0.username.lowercased() == clean.lowercased() }) {
            appendLog("⚠️ الحساب @\(clean) مضاف مسبقاً")
            return
        }
        accounts.append(SnapAccount(username: clean, category: category, isSelectedForDownload: true))
        saveAccounts()
        appendLog("✅ تمت إضافة @\(clean) إلى خانة \(category + 1)")
    }

    func deleteAccount(_ account: SnapAccount) {
        accounts.removeAll { $0.id == account.id }
        failedAccounts.removeAll { $0.account.username.lowercased() == account.username.lowercased() }
        saveAccounts()
    }

    func moveAccountToCategory(_ account: SnapAccount, newCategory: Int) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx].category = newCategory
            saveAccounts()
            appendLog("⇄ تم نقل @\(account.username) إلى خانة \(newCategory + 1)")
        }
    }

    func moveAccounts(in category: Int, from source: IndexSet, to destination: Int) {
        var categoryItems = accounts.filter { $0.category == category }
        categoryItems.move(fromOffsets: source, toOffset: destination)

        var rebuilt: [SnapAccount] = []
        for cat in 0..<3 {
            if cat == category {
                rebuilt.append(contentsOf: categoryItems)
            } else {
                rebuilt.append(contentsOf: accounts.filter { $0.category == cat })
            }
        }
        accounts = rebuilt
        saveAccounts()
    }

    // MARK: - إدارة الإعدادات
    func loadSettings() {
        let d = UserDefaults.standard
        autoDownloadEnabled = d.bool(forKey: "SV_AutoDownloadEnabled")
        if d.object(forKey: "SV_AutoDownloadHour") != nil {
            autoDownloadHour = d.integer(forKey: "SV_AutoDownloadHour")
            autoDownloadMinute = d.integer(forKey: "SV_AutoDownloadMinute")
        }
        if d.object(forKey: "SV_AutoDownloadCategory") != nil {
            autoDownloadTargetCategory = d.integer(forKey: "SV_AutoDownloadCategory")
        }
        useFaceID = d.bool(forKey: "SV_UseFaceID")
        autoCleanEnabled = d.bool(forKey: "SV_AutoCleanEnabled")
        let savedDays = d.integer(forKey: "SV_AutoCleanDays")
        autoCleanDays = savedDays > 0 ? savedDays : 7

        wifiOnlyDownload = d.bool(forKey: "SV_WifiOnlyDownload")
        keepScreenAwake = d.object(forKey: "SV_KeepScreenAwake") == nil ? true : d.bool(forKey: "SV_KeepScreenAwake")
        autoAdvancePlayer = d.object(forKey: "SV_AutoAdvancePlayer") == nil ? true : d.bool(forKey: "SV_AutoAdvancePlayer")
        startVideosMuted = d.bool(forKey: "SV_StartVideosMuted")
        hapticOnComplete = d.object(forKey: "SV_HapticOnComplete") == nil ? true : d.bool(forKey: "SV_HapticOnComplete")
        hideEmptyFolders = d.bool(forKey: "SV_HideEmptyFolders")
    }

    func applyAndSaveSettings(
        autoDownload: Bool,
        hour: Int,
        minute: Int,
        targetCategory: Int,
        faceID: Bool,
        cleanEnabled: Bool,
        cleanDays: Int,
        wifiOnly: Bool,
        keepAwake: Bool,
        autoAdvance: Bool,
        startMuted: Bool,
        haptic: Bool,
        hideEmpty: Bool
    ) {
        self.autoDownloadEnabled = autoDownload
        self.autoDownloadHour = hour
        self.autoDownloadMinute = minute
        self.autoDownloadTargetCategory = targetCategory
        self.useFaceID = faceID
        self.autoCleanEnabled = cleanEnabled
        self.autoCleanDays = cleanDays
        self.wifiOnlyDownload = wifiOnly
        self.keepScreenAwake = keepAwake
        self.autoAdvancePlayer = autoAdvance
        self.startVideosMuted = startMuted
        self.hapticOnComplete = haptic
        self.hideEmptyFolders = hideEmpty

        let d = UserDefaults.standard
        d.set(autoDownload, forKey: "SV_AutoDownloadEnabled")
        d.set(hour, forKey: "SV_AutoDownloadHour")
        d.set(minute, forKey: "SV_AutoDownloadMinute")
        d.set(targetCategory, forKey: "SV_AutoDownloadCategory")
        d.set(faceID, forKey: "SV_UseFaceID")
        d.set(cleanEnabled, forKey: "SV_AutoCleanEnabled")
        d.set(cleanDays, forKey: "SV_AutoCleanDays")
        d.set(wifiOnly, forKey: "SV_WifiOnlyDownload")
        d.set(keepAwake, forKey: "SV_KeepScreenAwake")
        d.set(autoAdvance, forKey: "SV_AutoAdvancePlayer")
        d.set(startMuted, forKey: "SV_StartVideosMuted")
        d.set(haptic, forKey: "SV_HapticOnComplete")
        d.set(hideEmpty, forKey: "SV_HideEmptyFolders")

        d.removeObject(forKey: lastAutoDownloadDateKey)
        appendLog("💾 تم حفظ واعتماد جميع الإعدادات الجديدة بنجاح")
    }

    func checkForegroundAutoDownload() {
        guard autoDownloadEnabled, !isDownloading else { return }

        let now = Date()
        let cal = Calendar.current
        let currentHour = cal.component(.hour, from: now)
        let currentMinute = cal.component(.minute, from: now)

        let scheduledTotalMinutes = autoDownloadHour * 60 + autoDownloadMinute
        let currentTotalMinutes = currentHour * 60 + currentMinute
        let diff = currentTotalMinutes - scheduledTotalMinutes

        guard diff >= 0 && diff <= 3 else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayKey = "\(formatter.string(from: now))_\(autoDownloadHour):\(autoDownloadMinute)"

        let lastRun = UserDefaults.standard.string(forKey: lastAutoDownloadDateKey) ?? ""
        guard lastRun != todayKey else { return }

        UserDefaults.standard.set(todayKey, forKey: lastAutoDownloadDateKey)
        appendLog("⏰ بدأ التحميل التلقائي المجدول الآن!")

        if autoDownloadTargetCategory == -1 {
            startDownloadAll()
        } else {
            startDownloadCategory(autoDownloadTargetCategory)
        }
    }

    // MARK: - أوامر التحميل
    func startDownloadAll() {
        let targets = allSelectedAccounts
        startBatchDownload(targetAccounts: targets, title: "الحسابات المحددة في جميع الخانات")
    }

    func startDownloadCategory(_ category: Int) {
        let list = selectedAccounts(for: category)
        startBatchDownload(targetAccounts: list, title: "الحسابات المحددة في خانة \(category + 1)")
    }

    func startDownloadSingle(_ account: SnapAccount) {
        startBatchDownload(targetAccounts: [account], title: "@\(account.username)")
    }

    func retryFailedAccounts() {
        let list = failedAccounts.map { $0.account }
        guard !list.isEmpty else { return }
        startBatchDownload(targetAccounts: list, title: "الحسابات المتعثرة")
    }

    func togglePauseResume() {
        guard isDownloading else { return }
        isPaused.toggle()
        if isPaused {
            appendLog("⏸️ تم إيقاف التحميل مؤقتاً...")
        } else {
            appendLog("▶️ تم استئناف التحميل...")
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        isDownloading = false
        isPaused = false
        progressText = ""
        UIApplication.shared.isIdleTimerDisabled = false
        BackgroundKeepAliveManager.shared.stopKeepAlive()
        appendLog("⏹️ تم إيقاف وإلغاء عملية التحميل")
    }

    private func startBatchDownload(targetAccounts: [SnapAccount], title: String) {
        guard !isDownloading else {
            appendLog("⚠️ يوجد تحميل جارٍ حالياً!")
            return
        }
        guard !targetAccounts.isEmpty else {
            appendLog("⚠️ لا توجد حسابات محددة للتحميل في (\(title))")
            return
        }

        if wifiOnlyDownload && !NetworkMonitor.shared.isOnWiFi {
            appendLog("📡 تم إيقاف التحميل: خيار (التحميل عبر الواي فاي فقط) مفعّل وأنت غير متصل بـ Wi-Fi")
            return
        }

        isDownloading = true
        isPaused = false
        if keepScreenAwake {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        BackgroundKeepAliveManager.shared.startKeepAlive()
        appendLog("🚀 بدء تحميل (\(title)) - العدد: \(targetAccounts.count)")

        downloadTask = Task(priority: .userInitiated) {
            for (index, acc) in targetAccounts.enumerated() {
                if Task.isCancelled { break }

                while isPaused && !Task.isCancelled {
                    progressText = "⏸️ متوقف مؤقتاً عند @\(acc.username) (\(index + 1)/\(targetAccounts.count))"
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                if Task.isCancelled { break }

                progressText = "⏳ جاري فحص @\(acc.username) (\(index + 1)/\(targetAccounts.count))..."

                let result = await downloadStoriesForAccount(acc)
                if Task.isCancelled { break }

                switch result {
                case .success(let savedCount):
                    failedAccounts.removeAll { $0.account.username.lowercased() == acc.username.lowercased() }
                    if savedCount > 0 {
                        appendLog("✅ @\(acc.username): تم حفظ \(savedCount) ستوري جديد")
                    } else {
                        appendLog("ℹ️ @\(acc.username): لا توجد ستوريات جديدة (محدث)")
                    }
                case .failure(let err):
                    let reason = err.localizedDescription
                    appendLog("❌ خطأ في @\(acc.username): \(reason)")
                    if let existingIdx = failedAccounts.firstIndex(where: { $0.account.username.lowercased() == acc.username.lowercased() }) {
                        failedAccounts[existingIdx] = FailedAccountItem(account: acc, reason: reason)
                    } else {
                        failedAccounts.append(FailedAccountItem(account: acc, reason: reason))
                    }
                }
            }

            isDownloading = false
            isPaused = false
            progressText = ""
            UIApplication.shared.isIdleTimerDisabled = false
            BackgroundKeepAliveManager.shared.stopKeepAlive()

            if !Task.isCancelled {
                appendLog("🏁 اكتملت دورة التحميل (\(title))")
                if hapticOnComplete {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                }
            }
        }
    }

    // MARK: - محرك التحميل الأساسي (__NEXT_DATA__) - للستوري فقط + منع التكرار 100% + ترتيب زمني دقيق

    private struct StorySnapInfo {
        let id: String
        let mediaUrl: String
        let isVideo: Bool
        let timestamp: TimeInterval
        let sequenceIndex: Int
    }

    private func downloadStoriesForAccount(_ account: SnapAccount) async -> Result<Int, Error> {
        let username = account.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://www.snapchat.com/add/\(username)") else {
            return .failure(NSError(domain: "SnapVault", code: 1, userInfo: [NSLocalizedDescriptionKey: "رابط الحساب غير صالح"]))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("ar,en-US;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await downloadSession.data(for: request)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode >= 400 {
                return .failure(NSError(domain: "SnapVault", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "الحساب غير موجود أو خاص (\(httpResp.statusCode))"]))
            }

            guard let html = String(data: data, encoding: .utf8) else {
                return .failure(NSError(domain: "SnapVault", code: 2, userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة صفحة الحساب"]))
            }

            guard let jsonString = extractNextDataJSON(from: html),
                  let jsonData = jsonString.data(using: .utf8),
                  let rootObj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return .failure(NSError(domain: "SnapVault", code: 3, userInfo: [NSLocalizedDescriptionKey: "لم يتم العثور على بيانات __NEXT_DATA__"]))
            }

            let snaps = parseStoryOnlyFromNextData(rootObj)
            if snaps.isEmpty {
                return .failure(NSError(domain: "SnapVault", code: 4, userInfo: [NSLocalizedDescriptionKey: "لا توجد ستوريات يومية نشطة حالياً"]))
            }

            let folderURL = accountFolder(for: username)
            var knownIDs = existingSnapIDs(for: username)
            var savedCount = 0
            var newlyAddedItems: [MediaItem] = []

            for snap in snaps {
                if Task.isCancelled { break }
                while isPaused && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                if Task.isCancelled { break }

                let safeID = Self.sanitizeSnapID(snap.id)

                if knownIDs.contains(safeID) {
                    continue
                }

                let ext = snap.isVideo ? "mp4" : "jpg"
                let preciseTimestamp = snap.timestamp + (Double(snap.sequenceIndex) * 0.001)
                let fileName = String(format: "%.3f_%@.%@", preciseTimestamp, safeID, ext)
                let fileURL = folderURL.appendingPathComponent(fileName)

                if FileManager.default.fileExists(atPath: fileURL.path) {
                    knownIDs.insert(safeID)
                    continue
                }

                guard let mediaURL = URL(string: snap.mediaUrl) else { continue }
                let (mediaData, mediaResp) = try await downloadSession.data(from: mediaURL)
                if let httpMedia = mediaResp as? HTTPURLResponse, httpMedia.statusCode == 200, !mediaData.isEmpty {
                    try mediaData.write(to: fileURL, options: .atomic)
                    let snapDate = Date(timeIntervalSince1970: preciseTimestamp)
                    try? FileManager.default.setAttributes(
                        [.creationDate: snapDate, .modificationDate: snapDate],
                        ofItemAtPath: fileURL.path
                    )

                    knownIDs.insert(safeID)
                    savedCount += 1

                    let newItem = MediaItem(
                        id: "\(username)_\(fileName)",
                        snapID: safeID,
                        url: fileURL,
                        isVideo: snap.isVideo,
                        creationDate: snapDate,
                        timestamp: preciseTimestamp,
                        username: username,
                        fileSize: Int64(mediaData.count)
                    )
                    newlyAddedItems.append(newItem)
                }
            }

            downloadedSnapIDsByUser[username.lowercased()] = knownIDs

            if !newlyAddedItems.isEmpty {
                insertNewItemsIntoIndex(newlyAddedItems, for: username)
            }

            return .success(savedCount)
        } catch {
            return .failure(error)
        }
    }

    private func extractNextDataJSON(from html: String) -> String? {
        let pattern = #"<script\s+id="__NEXT_DATA__"\s+type="application/json"[^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    private func parseStoryOnlyFromNextData(_ root: [String: Any]) -> [StorySnapInfo] {
        var results: [StorySnapInfo] = []
        guard let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any] else {
            return results
        }

        if let story = pageProps["story"] as? [String: Any],
           let snapList = story["snapList"] as? [[String: Any]] {
            for (idx, item) in snapList.enumerated() {
                if let info = extractSingleSnap(from: item, sequenceIndex: idx) {
                    results.append(info)
                }
            }
        }

        return results
    }

    private func extractSingleSnap(from item: [String: Any], sequenceIndex: Int) -> StorySnapInfo? {
        guard let snapUrls = item["snapUrls"] as? [String: Any],
              let mediaUrl = snapUrls["mediaUrl"] as? String,
              !mediaUrl.isEmpty else {
            return nil
        }

        var snapId = ""
        if let idDict = item["snapId"] as? [String: Any], let val = idDict["value"] as? String, !val.isEmpty {
            snapId = val
        } else if let val = item["snapId"] as? String, !val.isEmpty {
            snapId = val
        } else {
            let cleanUrl = mediaUrl.components(separatedBy: "?").first ?? mediaUrl
            snapId = URL(string: cleanUrl)?.lastPathComponent ?? cleanUrl
        }

        let mediaType = item["snapMediaType"] as? Int ?? 0
        let isVideo = (mediaType == 1) || mediaUrl.lowercased().contains(".mp4")

        var timestamp: TimeInterval = 0
        if let tsDict = item["timestampInSec"] as? [String: Any] {
            if let valStr = tsDict["value"] as? String, let valDouble = Double(valStr) {
                timestamp = valDouble
            } else if let valNum = tsDict["value"] as? Double {
                timestamp = valNum
            } else if let valInt = tsDict["value"] as? Int64 {
                timestamp = TimeInterval(valInt)
            }
        } else if let valNum = item["timestampInSec"] as? Double {
            timestamp = valNum
        } else if let valStr = item["timestampInSec"] as? String, let valDouble = Double(valStr) {
            timestamp = valDouble
        }

        if timestamp > 10_000_000_000 {
            timestamp = timestamp / 1000.0
        }
        if timestamp <= 0 {
            timestamp = Date().timeIntervalSince1970
        }

        return StorySnapInfo(
            id: snapId,
            mediaUrl: mediaUrl,
            isVideo: isVideo,
            timestamp: timestamp,
            sequenceIndex: sequenceIndex
        )
    }

    nonisolated private static func sanitizeSnapID(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<> ")
        return raw.components(separatedBy: invalid).joined(separator: "_")
    }

    private func existingSnapIDs(for username: String) -> Set<String> {
        let lower = username.lowercased()
        if let cached = downloadedSnapIDsByUser[lower] {
            return cached
        }
        var set = Set<String>()
        for item in mediaItems(for: username) {
            set.insert(item.snapID)
        }
        downloadedSnapIDsByUser[lower] = set
        return set
    }

    // MARK: - محرك الفهرسة السريع في الخلفية

    var baseVaultDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("SnapVault", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func accountFolder(for username: String) -> URL {
        let folder = baseVaultDirectory.appendingPathComponent(username, isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    func rebuildMediaIndexInBackground(performCleanupAfter: Bool = false) {
        isIndexingMedia = true
        let baseDir = baseVaultDirectory
        let shouldClean = performCleanupAfter
        let cleanDays = autoCleanDays

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -cleanDays, to: Date()) ?? Date()

            var userMap: [String: [MediaItem]] = [:]
            var allItems: [MediaItem] = []
            var snapIDMap: [String: Set<String>] = [:]
            var totalBytes: Int64 = 0

            if let folders = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for folderURL in folders where folderURL.hasDirectoryPath {
                    let username = folderURL.lastPathComponent
                    guard let files = try? fm.contentsOfDirectory(
                        at: folderURL,
                        includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    var itemsForUser: [MediaItem] = []
                    var idSet = Set<String>()

                    for fileURL in files {
                        let ext = fileURL.pathExtension.lowercased()
                        guard ["mp4", "mov", "jpg", "jpeg", "png"].contains(ext) else { continue }

                        let resourceValues = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
                        let fileNameNoExt = fileURL.deletingPathExtension().lastPathComponent
                        let fallback = resourceValues?.creationDate ?? resourceValues?.contentModificationDate ?? Date()
                        let parsed = VaultViewModel.parseTimestampAndSnapID(from: fileNameNoExt, fallbackDate: fallback)

                        if shouldClean && parsed.date < cutoffDate {
                            try? fm.removeItem(at: fileURL)
                            continue
                        }

                        let fSize = Int64(resourceValues?.fileSize ?? 0)
                        totalBytes += fSize

                        let mediaItem = MediaItem(
                            id: "\(username)_\(fileURL.lastPathComponent)",
                            snapID: parsed.snapID,
                            url: fileURL,
                            isVideo: (ext == "mp4" || ext == "mov"),
                            creationDate: parsed.date,
                            timestamp: parsed.timestamp,
                            username: username,
                            fileSize: fSize
                        )

                        itemsForUser.append(mediaItem)
                        idSet.insert(parsed.snapID)
                    }

                    itemsForUser.sort { $0.timestamp > $1.timestamp }
                    userMap[username] = itemsForUser
                    allItems.append(contentsOf: itemsForUser)
                    snapIDMap[username.lowercased()] = idSet
                }
            }

            allItems.sort { $0.timestamp > $1.timestamp }

            let byteFormatter = ByteCountFormatter()
            byteFormatter.allowedUnits = [.useMB, .useGB]
            byteFormatter.countStyle = .file
            let sizeStr = byteFormatter.string(fromByteCount: totalBytes)

            let finalUserMap = userMap
            let finalAllItems = allItems
            let finalSnapIDMap = snapIDMap

            await MainActor.run {
                VaultViewModel.shared.mediaByUser = finalUserMap
                VaultViewModel.shared.allIndexedItems = finalAllItems
                VaultViewModel.shared.downloadedSnapIDsByUser = finalSnapIDMap
                VaultViewModel.shared.cachedVaultSizeText = sizeStr
                VaultViewModel.shared.isIndexingMedia = false
            }
        }
    }

    nonisolated private static func parseTimestampAndSnapID(from fileNameNoExt: String, fallbackDate: Date) -> (timestamp: TimeInterval, date: Date, snapID: String) {
        if let underscoreIdx = fileNameNoExt.firstIndex(of: "_") {
            let prefixStr = String(fileNameNoExt[..<underscoreIdx])
            let idPart = String(fileNameNoExt[fileNameNoExt.index(after: underscoreIdx)...])
            if let ts = Double(prefixStr), ts > 1_000_000_000 {
                return (ts, Date(timeIntervalSince1970: ts), idPart.isEmpty ? fileNameNoExt : idPart)
            }
        }
        let ts = fallbackDate.timeIntervalSince1970
        return (ts, fallbackDate, fileNameNoExt)
    }

    private func insertNewItemsIntoIndex(_ newItems: [MediaItem], for username: String) {
        var currentList = mediaByUser[username] ?? []
        let existingIDs = Set(currentList.map { $0.snapID })
        let uniqueNew = newItems.filter { !existingIDs.contains($0.snapID) }
        guard !uniqueNew.isEmpty else { return }

        currentList.append(contentsOf: uniqueNew)
        currentList.sort { $0.timestamp > $1.timestamp }
        mediaByUser[username] = currentList

        allIndexedItems.append(contentsOf: uniqueNew)
        allIndexedItems.sort { $0.timestamp > $1.timestamp }
        recalculateVaultSizeText()
    }

    private func recalculateVaultSizeText() {
        let totalBytes = allIndexedItems.reduce(Int64(0)) { $0 + $1.fileSize }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        cachedVaultSizeText = formatter.string(fromByteCount: totalBytes)
    }

    func fetchOrderedUserFolders() -> [String] {
        let diskFolders = Set(mediaByUser.keys)
        var ordered: [String] = []
        var seenLower = Set<String>()

        for acc in accounts {
            let lower = acc.username.lowercased()
            guard !seenLower.contains(lower) else { continue }
            if let matchedDiskName = diskFolders.first(where: { $0.lowercased() == lower }) {
                ordered.append(matchedDiskName)
                seenLower.insert(lower)
            } else if !hideEmptyFolders {
                ordered.append(acc.username)
                seenLower.insert(lower)
            }
        }

        for folder in diskFolders.sorted() {
            let lower = folder.lowercased()
            if !seenLower.contains(lower) {
                ordered.append(folder)
                seenLower.insert(lower)
            }
        }

        if hideEmptyFolders {
            return ordered.filter { !mediaItems(for: $0).isEmpty }
        }
        return ordered
    }

    func mediaItems(for username: String) -> [MediaItem] {
        if let direct = mediaByUser[username] {
            return direct
        }
        if let matchKey = mediaByUser.keys.first(where: { $0.lowercased() == username.lowercased() }) {
            return mediaByUser[matchKey] ?? []
        }
        return []
    }

    func accountDailySnapRank(for item: MediaItem) -> (index: Int, total: Int) {
        let cal = Calendar.current
        let userItems = mediaItems(for: item.username)
        let sameDayItems = userItems
            .filter { cal.isDate($0.creationDate, inSameDayAs: item.creationDate) }
            .sorted { $0.timestamp < $1.timestamp }

        if let idx = sameDayItems.firstIndex(where: { $0.id == item.id }) {
            return (idx + 1, sameDayItems.count)
        }
        return (1, max(1, sameDayItems.count))
    }

    func deleteAccountFolderCompletely(username: String) {
        let folderURL = accountFolder(for: username)
        try? FileManager.default.removeItem(at: folderURL)

        if let key = mediaByUser.keys.first(where: { $0.lowercased() == username.lowercased() }) {
            mediaByUser.removeValue(forKey: key)
        }
        allIndexedItems.removeAll { $0.username.lowercased() == username.lowercased() }
        downloadedSnapIDsByUser.removeValue(forKey: username.lowercased())
        recalculateVaultSizeText()
        appendLog("🗑️ تم حذف مجلد المقاطع للحساب @\(username) بالكامل")
    }

    func deleteMediaItem(_ item: MediaItem) {
        deleteMultipleMediaItems([item])
    }

    func deleteMultipleMediaItems(_ itemsToDelete: [MediaItem]) {
        guard !itemsToDelete.isEmpty else { return }
        let idsToDelete = Set(itemsToDelete.map { $0.id })

        for item in itemsToDelete {
            try? FileManager.default.removeItem(at: item.url)
            downloadedSnapIDsByUser[item.username.lowercased()]?.remove(item.snapID)
        }

        for (user, list) in mediaByUser {
            mediaByUser[user] = list.filter { !idsToDelete.contains($0.id) }
        }
        allIndexedItems.removeAll { idsToDelete.contains($0.id) }
        recalculateVaultSizeText()
    }

    func authenticateFaceID() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "فتح خزنة SnapVault") { success, _ in
                Task { @MainActor in
                    self.isUnlocked = success
                }
            }
        } else {
            isUnlocked = true
        }
    }
}

// MARK: - 7. الواجهة الرئيسية (ContentView)

struct ContentView: View {
    @StateObject private var vm = VaultViewModel.shared
    private let autoTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !vm.isUnlocked {
                lockScreenView
            } else {
                TabView {
                    AccountsAndDownloadView(vm: vm)
                        .tabItem {
                            Label("الحسابات والتحميل", systemImage: "arrow.down.circle.fill")
                        }

                    GalleryFoldersView(vm: vm)
                        .tabItem {
                            Label("المعرض والمجلدات", systemImage: "photo.on.rectangle.angled")
                        }

                    SettingsScreenView(vm: vm)
                        .tabItem {
                            Label("الإعدادات", systemImage: "gearshape.fill")
                        }
                }
                .environment(\.layoutDirection, .rightToLeft)
            }
        }
        .onReceive(autoTimer) { _ in
            vm.checkForegroundAutoDownload()
        }
    }

    private var lockScreenView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 72))
                .foregroundColor(.yellow)
            Text("SnapVault مقفل")
                .font(.title.bold())
            Text("الرجاء تأكيد الهوية ببصمة الوجه لفتح الخزنة")
                .foregroundColor(.secondary)
            Button {
                vm.authenticateFaceID()
            } label: {
                Label("فتح القفل الآن", systemImage: "faceid")
                    .font(.headline)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 14)
                    .background(Color.yellow)
                    .foregroundColor(.black)
                    .cornerRadius(14)
            }
        }
        .onAppear {
            vm.authenticateFaceID()
        }
    }
}

// MARK: - 8. شاشة الحسابات والتحميل

struct AccountsAndDownloadView: View {
    @ObservedObject var vm: VaultViewModel
    @State private var selectedCategory: Int = 0
    @State private var newUsername: String = ""
    @State private var isReorderMode: Bool = true

    var currentCategoryAccounts: [SnapAccount] {
        vm.accounts(for: selectedCategory)
    }

    var currentSelectedCount: Int {
        vm.selectedAccounts(for: selectedCategory).count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    Picker("أقسام الحسابات", selection: $selectedCategory) {
                        Text("خانة 1 (\(vm.selectedAccounts(for: 0).count)/\(vm.accounts(for: 0).count))").tag(0)
                        Text("خانة 2 (\(vm.selectedAccounts(for: 1).count)/\(vm.accounts(for: 1).count))").tag(1)
                        Text("خانة 3 (\(vm.selectedAccounts(for: 2).count)/\(vm.accounts(for: 2).count))").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    HStack(spacing: 10) {
                        TextField("أضف اسم الحساب في خانة \(selectedCategory + 1)...", text: $newUsername)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button {
                            vm.addAccount(username: newUsername, to: selectedCategory)
                            newUsername = ""
                        } label: {
                            Label("إضافة", systemImage: "plus.circle.fill")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Color.yellow)
                                .foregroundColor(.black)
                                .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("حسابات خانة \(selectedCategory + 1)")
                                .font(.headline)

                            Spacer()

                            if !currentCategoryAccounts.isEmpty {
                                Button {
                                    let allSelected = currentSelectedCount == currentCategoryAccounts.count
                                    vm.setCategorySelection(selectedCategory, selected: !allSelected)
                                } label: {
                                    Text(currentSelectedCount == currentCategoryAccounts.count ? "إلغاء تحديد الكل" : "تحديد الكل")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color.green.opacity(0.2))
                                        .foregroundColor(.green)
                                        .cornerRadius(8)
                                }
                            }

                            Button {
                                withAnimation {
                                    isReorderMode.toggle()
                                }
                            } label: {
                                Label(isReorderMode ? "السحب ☰" : "تفعيل السحب", systemImage: "line.3.horizontal")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(isReorderMode ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal)

                        if currentCategoryAccounts.isEmpty {
                            Text("لا توجد حسابات في خانة \(selectedCategory + 1) حالياً")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                                .padding(.horizontal)
                        } else {
                            List {
                                ForEach(currentCategoryAccounts) { acc in
                                    HStack(spacing: 10) {
                                        Button {
                                            vm.toggleAccountSelection(acc)
                                        } label: {
                                            Image(systemName: acc.isSelectedForDownload ? "checkmark.square.fill" : "square")
                                                .font(.title2)
                                                .foregroundColor(acc.isSelectedForDownload ? .green : .gray)
                                        }
                                        .buttonStyle(.borderless)

                                        Text("@\(acc.username)")
                                            .font(.body.weight(.semibold))
                                            .foregroundColor(acc.isSelectedForDownload ? .primary : .secondary)
                                            .strikethrough(!acc.isSelectedForDownload, color: .secondary)

                                        Spacer()

                                        Menu {
                                            ForEach(0..<3, id: \.self) { targetCat in
                                                if targetCat != selectedCategory {
                                                    Button("نقل إلى خانة \(targetCat + 1)") {
                                                        vm.moveAccountToCategory(acc, newCategory: targetCat)
                                                    }
                                                }
                                            }
                                        } label: {
                                            Image(systemName: "arrow.left.arrow.right.circle")
                                                .foregroundColor(.secondary)
                                                .font(.title3)
                                        }
                                        .buttonStyle(.borderless)

                                        Button {
                                            vm.startDownloadSingle(acc)
                                        } label: {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .foregroundColor(.blue)
                                                .font(.title3)
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(vm.isDownloading)

                                        Button {
                                            vm.deleteAccount(acc)
                                        } label: {
                                            Image(systemName: "trash.fill")
                                                .foregroundColor(.red)
                                                .font(.subheadline)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .onMove { source, destination in
                                    vm.moveAccounts(in: selectedCategory, from: source, to: destination)
                                }
                            }
                            .listStyle(.plain)
                            .environment(\.editMode, .constant(isReorderMode ? .active : .inactive))
                            .frame(height: CGFloat(currentCategoryAccounts.count * 56 + 12))
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .padding(.horizontal)
                        }
                    }

                    VStack(spacing: 10) {
                        Button {
                            vm.startDownloadCategory(selectedCategory)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.doc.fill")
                                Text("تحميل المحدد في (خانة \(selectedCategory + 1)) فقط (\(currentSelectedCount))")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(currentSelectedCount > 0 ? Color.yellow : Color.gray.opacity(0.3))
                            .foregroundColor(.black)
                            .cornerRadius(12)
                        }
                        .disabled(vm.isDownloading || currentSelectedCount == 0)

                        Button {
                            vm.startDownloadAll()
                        } label: {
                            HStack {
                                Image(systemName: "bolt.horizontal.circle.fill")
                                Text("تحميل المحدد في جميع الخانات (\(vm.allSelectedAccounts.count))")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.blue.opacity(0.18))
                            .foregroundColor(.blue)
                            .cornerRadius(12)
                        }
                        .disabled(vm.isDownloading || vm.allSelectedAccounts.isEmpty)

                        if vm.isDownloading {
                            VStack(spacing: 8) {
                                Text(vm.progressText)
                                    .font(.caption.bold())
                                    .foregroundColor(.orange)

                                HStack(spacing: 12) {
                                    Button {
                                        vm.togglePauseResume()
                                    } label: {
                                        Label(
                                            vm.isPaused ? "استئناف التحميل" : "إيقاف مؤقت",
                                            systemImage: vm.isPaused ? "play.fill" : "pause.fill"
                                        )
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(vm.isPaused ? Color.green : Color.orange)
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                    }

                                    Button {
                                        vm.cancelDownload()
                                    } label: {
                                        Label("إلغاء", systemImage: "stop.fill")
                                            .font(.subheadline.bold())
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 10)
                                            .background(Color.red)
                                            .foregroundColor(.white)
                                            .cornerRadius(10)
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("سجل العمليات", systemImage: "terminal.fill")
                                .font(.headline)
                            Spacer()
                            Button("مسح السجل") {
                                vm.logs.removeAll()
                            }
                            .font(.caption)
                        }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                if vm.logs.isEmpty {
                                    Text("السجل فارغ حالياً...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(Array(vm.logs.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 12, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 130)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("الحسابات التي حدث فيها خطأ (\(vm.failedAccounts.count))", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundColor(vm.failedAccounts.isEmpty ? .secondary : .orange)
                            Spacer()
                            if !vm.failedAccounts.isEmpty {
                                Button("مسح القائمة") {
                                    vm.failedAccounts.removeAll()
                                }
                                .font(.caption)
                                .foregroundColor(.red)
                            }
                        }

                        if vm.failedAccounts.isEmpty {
                            Text("لا توجد أخطاء تحميل حالياً ✅")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                        } else {
                            VStack(spacing: 6) {
                                ForEach(vm.failedAccounts) { item in
                                    HStack {
                                        Text("@\(item.account.username)")
                                            .font(.subheadline.bold())
                                        Text("— \(item.reason)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Button {
                                            vm.startDownloadSingle(item.account)
                                        } label: {
                                            Image(systemName: "arrow.clockwise.circle.fill")
                                                .foregroundColor(.orange)
                                        }
                                        .disabled(vm.isDownloading)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemBackground))
                                    .cornerRadius(8)
                                }

                                Button {
                                    vm.retryFailedAccounts()
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.clockwise")
                                        Text("إعادة تحميل الحسابات المتعثرة فقط (\(vm.failedAccounts.count))")
                                            .fontWeight(.bold)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(Color.orange)
                                    .foregroundColor(.black)
                                    .cornerRadius(10)
                                }
                                .disabled(vm.isDownloading)
                            }
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
                .padding(.top, 10)
            }
            .navigationTitle("SnapVault 👻")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - 9. شاشة المعرض والمجلدات

struct GalleryFoldersView: View {
    @ObservedObject var vm: VaultViewModel
    @State private var folderToDelete: String? = nil

    var orderedFolders: [String] {
        vm.fetchOrderedUserFolders()
    }

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("المجلد الشامل")) {
                    let allItems = vm.allIndexedItems
                    let totalPhotos = allItems.filter { !$0.isVideo }.count
                    let totalVideos = allItems.filter { $0.isVideo }.count

                    NavigationLink {
                        AccountMediaDetailView(vm: vm, username: nil)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.yellow.opacity(0.2))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "photo.stack.fill")
                                    .font(.title2)
                                    .foregroundColor(.yellow)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("جميع التحميلات (كل الحسابات)")
                                    .font(.headline.bold())
                                Text("\(totalPhotos) صورة، \(totalVideos) مقطعاً — الإجمالي: \(allItems.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(header: Text("مجلدات الحسابات حسب ترتيبك (\(orderedFolders.count))")) {
                    if orderedFolders.isEmpty {
                        Text("لا توجد مجلدات حسابات محفوظة بعد.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(orderedFolders, id: \.self) { username in
                            let items = vm.mediaItems(for: username)
                            let photosCount = items.filter { !$0.isVideo }.count
                            let videosCount = items.filter { $0.isVideo }.count

                            NavigationLink {
                                AccountMediaDetailView(vm: vm, username: username)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .font(.title2)
                                        .foregroundColor(.yellow)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("@\(username)")
                                            .font(.headline)
                                        Text("\(photosCount) صورة، \(videosCount) مقطعاً")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    folderToDelete = username
                                } label: {
                                    Label("حذف المجلد", systemImage: "trash.fill")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    folderToDelete = username
                                } label: {
                                    Label("حذف مجلد @\(username) بالكامل", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("خزنة المقاطع 📁")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        vm.rebuildMediaIndexInBackground()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .alert(
                "حذف مجلد الحساب؟",
                isPresented: Binding(
                    get: { folderToDelete != nil },
                    set: { if !$0 { folderToDelete = nil } }
                )
            ) {
                Button("حذف المجلد ومقاطعه", role: .destructive) {
                    if let target = folderToDelete {
                        vm.deleteAccountFolderCompletely(username: target)
                    }
                    folderToDelete = nil
                }
                Button("إلغاء", role: .cancel) {
                    folderToDelete = nil
                }
            } message: {
                if let target = folderToDelete {
                    Text("هل أنت متأكد من حذف مجلد @\(target) وجميع الصور والفيديوهات المحفوظة بداخله؟ (لن يتم حذف الحساب من قائمة الحسابات).")
                }
            }
        }
    }
}

// MARK: - 10. داخل مجلد الحساب

enum MediaOrderMode: Int {
    case todayStoryOrder = 0
    case allNewestFirst = 1
    case allOldestFirst = 2
}

struct AccountMediaDetailView: View {
    @ObservedObject var vm: VaultViewModel
    let username: String?

    @State private var orderMode: MediaOrderMode = .allNewestFirst
    @State private var filterToday: Bool = false
    @State private var filterYesterday: Bool = false

    @State private var isSelectionMode: Bool = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var isMergingVideos: Bool = false
    @State private var mergeProgressText: String = ""
    @State private var showDeleteFolderConfirm: Bool = false

    @State private var activePlayerSession: PlayerSession? = nil
    @State private var statusAlertMessage: String? = nil

    var filteredAndSortedItems: [MediaItem] {
        let baseItems = (username == nil) ? vm.allIndexedItems : vm.mediaItems(for: username!)
        let cal = Calendar.current

        if orderMode == .todayStoryOrder {
            let todayItems = baseItems.filter { cal.isDateInToday($0.creationDate) }
            let targetList = todayItems.isEmpty ? baseItems : todayItems
            return targetList.sorted { a, b in
                if a.timestamp == b.timestamp { return a.id < b.id }
                return a.timestamp < b.timestamp
            }
        }

        let dateFiltered = baseItems.filter { item in
            if !filterToday && !filterYesterday {
                return true
            }
            var match = false
            if filterToday && cal.isDateInToday(item.creationDate) {
                match = true
            }
            if filterYesterday && cal.isDateInYesterday(item.creationDate) {
                match = true
            }
            return match
        }

        return dateFiltered.sorted { a, b in
            if a.timestamp == b.timestamp {
                return (orderMode == .allNewestFirst) ? (a.id > b.id) : (a.id < b.id)
            }
            return (orderMode == .allNewestFirst) ? (a.timestamp > b.timestamp) : (a.timestamp < b.timestamp)
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 1.5),
        GridItem(.flexible(), spacing: 1.5),
        GridItem(.flexible(), spacing: 1.5)
    ]

    var body: some View {
        let items = filteredAndSortedItems
        let photoCount = items.filter { !$0.isVideo }.count
        let videoCount = items.filter { $0.isVideo }.count
        let titleText = (username == nil) ? "جميع الحسابات 🌟" : "@\(username!) 👻"

        VStack(spacing: 6) {

            VStack(spacing: 8) {
                Picker("نظام الترتيب", selection: $orderMode) {
                    Text("ترتيب سنابات اليوم 📅").tag(MediaOrderMode.todayStoryOrder)
                    Text("الكل (الأحدث ⬇️)").tag(MediaOrderMode.allNewestFirst)
                    Text("الكل (الأقدم ⬆️)").tag(MediaOrderMode.allOldestFirst)
                }
                .pickerStyle(.segmented)

                if orderMode != .todayStoryOrder {
                    HStack(spacing: 8) {
                        Text("عرض أيام:")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)

                        Button {
                            filterToday = false
                            filterYesterday = false
                        } label: {
                            Text("الكل")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background((!filterToday && !filterYesterday) ? Color.yellow : Color(.secondarySystemBackground))
                                .foregroundColor((!filterToday && !filterYesterday) ? .black : .primary)
                                .cornerRadius(8)
                        }

                        Button {
                            filterToday.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: filterToday ? "checkmark.circle.fill" : "circle")
                                Text("اليوم")
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(filterToday ? Color.green : Color(.secondarySystemBackground))
                            .foregroundColor(filterToday ? .white : .primary)
                            .cornerRadius(8)
                        }

                        Button {
                            filterYesterday.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: filterYesterday ? "checkmark.circle.fill" : "circle")
                                Text("أمس")
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(filterYesterday ? Color.blue : Color(.secondarySystemBackground))
                            .foregroundColor(filterYesterday ? .white : .primary)
                            .cornerRadius(8)
                        }

                        Spacer()
                    }
                }

                if isSelectionMode {
                    HStack(spacing: 8) {
                        Button {
                            if selectedItemIDs.count == items.count {
                                selectedItemIDs.removeAll()
                            } else {
                                selectedItemIDs = Set(items.map { $0.id })
                            }
                        } label: {
                            Text(selectedItemIDs.count == items.count ? "إلغاء تحديد الكل" : "تحديد الكل (\(items.count))")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.blue.opacity(0.2))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                        }

                        Button {
                            mergeSelectedOrVisibleVideos(from: items)
                        } label: {
                            Label("دمج الفيديو (\(selectedVideosCount(in: items)))", systemImage: "film.stack.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.purple)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .disabled(isMergingVideos || selectedVideosCount(in: items) < 2)

                        Spacer()

                        Button(role: .destructive) {
                            let toDelete = items.filter { selectedItemIDs.contains($0.id) }
                            vm.deleteMultipleMediaItems(toDelete)
                            selectedItemIDs.removeAll()
                        } label: {
                            Label("حذف (\(selectedItemIDs.count))", systemImage: "trash.fill")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(selectedItemIDs.isEmpty ? Color.gray.opacity(0.3) : Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .disabled(selectedItemIDs.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            if isMergingVideos {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(mergeProgressText)
                        .font(.caption.bold())
                        .foregroundColor(.purple)
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal, 10)
            }

            if items.isEmpty {
                Spacer()
                Text("لا توجد مقاطع مطابقة للفلتر المحدد")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 1.5) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            let isSelected = selectedItemIDs.contains(item.id)
                            MediaThumbnailCell(
                                item: item,
                                showUsernameBadge: username == nil,
                                isSelectionMode: isSelectionMode,
                                isSelected: isSelected
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelectionMode {
                                    if isSelected {
                                        selectedItemIDs.remove(item.id)
                                    } else {
                                        selectedItemIDs.insert(item.id)
                                    }
                                } else {
                                    activePlayerSession = PlayerSession(items: items, startIndex: index)
                                }
                            }
                            .contextMenu {
                                Button {
                                    saveToCameraRoll(item)
                                } label: {
                                    Label("حفظ في ألبوم الكاميرا", systemImage: "square.and.arrow.down")
                                }
                                Button {
                                    isSelectionMode = true
                                    selectedItemIDs.insert(item.id)
                                } label: {
                                    Label("تحديد متعدد", systemImage: "checkmark.circle")
                                }
                                Button(role: .destructive) {
                                    vm.deleteMediaItem(item)
                                } label: {
                                    Label("حذف من الخزنة", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .background(Color.black)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(titleText)
                        .font(.headline.bold())
                    Text("\(photoCount) صورة، \(videoCount) مقطعاً")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation {
                            isSelectionMode.toggle()
                            if !isSelectionMode {
                                selectedItemIDs.removeAll()
                            }
                        }
                    } label: {
                        Text(isSelectionMode ? "تم" : "تحديد")
                            .font(.subheadline.bold())
                            .foregroundColor(isSelectionMode ? .green : .yellow)
                    }

                    Menu {
                        Button {
                            mergeAllVisibleVideos(from: items)
                        } label: {
                            Label("🎬 دمج جميع الفيديوهات المعروضة (\(videoCount))", systemImage: "film.stack")
                        }
                        .disabled(videoCount < 2 || isMergingVideos)

                        if username != nil {
                            Button(role: .destructive) {
                                showDeleteFolderConfirm = true
                            } label: {
                                Label("🗑️ حذف هذا المجلد بالكامل", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title3)
                            .foregroundColor(.yellow)
                    }
                }
            }
        }
        .fullScreenCover(item: $activePlayerSession) { session in
            SwipeableMediaPlayerView(
                vm: vm,
                items: session.items,
                startIndex: session.startIndex,
                onClose: { activePlayerSession = nil }
            )
        }
        .alert("حذف المجلد بالكامل؟", isPresented: $showDeleteFolderConfirm) {
            Button("حذف نهائي", role: .destructive) {
                if let user = username {
                    vm.deleteAccountFolderCompletely(username: user)
                }
            }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("سيتم حذف جميع الصور والفيديوهات داخل هذا المجلد دفعة واحدة.")
        }
        .alert(statusAlertMessage ?? "", isPresented: Binding(
            get: { statusAlertMessage != nil },
            set: { if !$0 { statusAlertMessage = nil } }
        )) {
            Button("حسناً", role: .cancel) {}
        }
    }

    private func selectedVideosCount(in items: [MediaItem]) -> Int {
        items.filter { selectedItemIDs.contains($0.id) && $0.isVideo }.count
    }

    private func mergeSelectedOrVisibleVideos(from items: [MediaItem]) {
        let selectedVideos = items.filter { selectedItemIDs.contains($0.id) && $0.isVideo }
            .sorted { $0.timestamp < $1.timestamp }
        runVideoMerge(videos: selectedVideos)
    }

    private func mergeAllVisibleVideos(from items: [MediaItem]) {
        let videos = items.filter { $0.isVideo }.sorted { $0.timestamp < $1.timestamp }
        runVideoMerge(videos: videos)
    }

    private func runVideoMerge(videos: [MediaItem]) {
        guard videos.count >= 2 else {
            statusAlertMessage = "يجب أن يكون هناك مقطعا فيديو على الأقل لدمجهما."
            return
        }
        isMergingVideos = true
        mergeProgressText = "جاري تحضير \(videos.count) مقطع للدمج..."

        Task {
            do {
                let mergedURL = try await VideoMergerEngine.mergeVideos(items: videos) { progress in
                    Task { @MainActor in
                        self.mergeProgressText = progress
                    }
                }
                isMergingVideos = false
                saveMergedVideoToCameraRoll(mergedURL)
            } catch {
                isMergingVideos = false
                statusAlertMessage = "❌ فشل الدمج: \(error.localizedDescription)"
            }
        }
    }

    private func saveMergedVideoToCameraRoll(_ fileURL: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    statusAlertMessage = "الرجاء السماح بصلاحية الصور لحفظ الفيديو المدمج."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }) { success, _ in
                try? FileManager.default.removeItem(at: fileURL)
                Task { @MainActor in
                    statusAlertMessage = success ? "🎬 تم دمج المقاطع وحفظ الفيديو الموحد في ألبوم الكاميرا بنجاح ✅" : "تعذر حفظ الفيديو المدمج في الألبوم"
                }
            }
        }
    }

    private func saveToCameraRoll(_ item: MediaItem) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                if item.isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: item.url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: item.url)
                }
            }) { success, _ in
                Task { @MainActor in
                    statusAlertMessage = success ? "تم الحفظ في ألبوم الكاميرا ✅" : "تعذر الحفظ في الألبوم"
                }
            }
        }
    }
}

struct MediaThumbnailCell: View {
    let item: MediaItem
    var showUsernameBadge: Bool = false
    var isSelectionMode: Bool = false
    var isSelected: Bool = false

    @State private var thumbnailImage: UIImage? = nil
    @State private var durationText: String? = nil

    var body: some View {
        Color(white: 0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                Group {
                    if let img = thumbnailImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView()
                            .tint(.white.opacity(0.6))
                    }
                }
            )
            .overlay(
                Group {
                    if isSelectionMode && isSelected {
                        Color.yellow.opacity(0.28)
                    }
                }
            )
            .overlay(alignment: .topLeading) {
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(isSelected ? .yellow : .white)
                        .shadow(color: .black.opacity(0.8), radius: 2)
                        .padding(6)
                } else if showUsernameBadge {
                    Text("@\(item.username)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(4)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    Image(systemName: item.isVideo ? "video.fill" : "photo.fill")
                        .font(.system(size: 9, weight: .bold))
                    if item.isVideo, let dur = durationText {
                        Text(dur)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55))
                .cornerRadius(5)
                .padding(5)
            }
            .clipped()
            .environment(\.layoutDirection, .leftToRight)
            .task(id: item.id) {
                let (img, dur) = await ThumbnailCacheManager.shared.getThumbnail(for: item)
                thumbnailImage = img
                durationText = dur
            }
    }
}

// MARK: - 11. مشغل الصور والفيديو الخفيف (Windowed Pager + 2x يسار الشاشة + تكبير بإصبعين)

struct SwipeableMediaPlayerView: View {
    @ObservedObject var vm: VaultViewModel
    let items: [MediaItem]
    let startIndex: Int
    let onClose: () -> Void

    @State private var currentIndex: Int
    @State private var isMuted: Bool = false
    @State private var saveToast: String? = nil

    init(vm: VaultViewModel, items: [MediaItem], startIndex: Int, onClose: @escaping () -> Void) {
        self.vm = vm
        self.items = items
        self.startIndex = startIndex
        self.onClose = onClose
        _currentIndex = State(initialValue: min(max(0, startIndex), max(0, items.count - 1)))
        _isMuted = State(initialValue: vm.startVideosMuted)
    }

    private var currentItem: MediaItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    private func isNearCurrentIndex(_ index: Int) -> Bool {
        abs(index - currentIndex) <= 2
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !items.isEmpty {
                TabView(selection: $currentIndex) {
                    ForEach(items.indices, id: \.self) { index in
                        Group {
                            if isNearCurrentIndex(index) {
                                SingleMediaPageView(
                                    item: items[index],
                                    isCurrentPage: currentIndex == index,
                                    isMuted: isMuted,
                                    autoAdvance: vm.autoAdvancePlayer,
                                    onVideoEnded: {
                                        if vm.autoAdvancePlayer && currentIndex < items.count - 1 {
                                            withAnimation {
                                                currentIndex += 1
                                            }
                                        }
                                    }
                                )
                            } else {
                                Color.black
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .environment(\.layoutDirection, .leftToRight)
                .ignoresSafeArea()
            }

            VStack {
                HStack(spacing: 14) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }

                    if let item = currentItem {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(item.username)")
                                .font(.subheadline.bold())
                                .foregroundColor(.yellow)
                            Text(formattedDateTime(item.creationDate))
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }

                    Spacer()

                    if let item = currentItem, item.isVideo {
                        Button {
                            isMuted.toggle()
                        } label: {
                            Image(systemName: isMuted ? "speaker.slash.circle.fill" : "speaker.wave.2.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                        }
                    }

                    if let item = currentItem {
                        Button {
                            saveCurrentItemToPhotos(item)
                        } label: {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                Spacer()

                if let toast = saveToast {
                    Text(toast)
                        .font(.caption.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.9))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.bottom, 6)
                }

                if let item = currentItem {
                    let dailyRank = vm.accountDailySnapRank(for: item)

                    VStack(spacing: 6) {
                        HStack(spacing: 10) {
                            HStack(spacing: 4) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.caption2)
                                Text("الكل: \(currentIndex + 1) / \(items.count)")
                                    .font(.caption.bold())
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.18))
                            .foregroundColor(.white)
                            .cornerRadius(10)

                            HStack(spacing: 4) {
                                Image(systemName: "person.fill")
                                    .font(.caption2)
                                Text("سنابات @\(item.username) لليوم: \(dailyRank.index) / \(dailyRank.total)")
                                    .font(.caption.bold())
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.yellow.opacity(0.88))
                            .foregroundColor(.black)
                            .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(14)
                    .padding(.bottom, 22)
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }

    private func formattedDateTime(_ date: Date) -> String {
        let cal = Calendar.current
        let tf = DateFormatter()
        tf.dateFormat = "hh:mm a"
        let timeStr = tf.string(from: date)
        if cal.isDateInToday(date) { return "اليوم \(timeStr)" }
        if cal.isDateInYesterday(date) { return "أمس \(timeStr)" }
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd hh:mm a"
        return df.string(from: date)
    }

    private func saveCurrentItemToPhotos(_ item: MediaItem) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                if item.isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: item.url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: item.url)
                }
            }) { success, _ in
                Task { @MainActor in
                    saveToast = success ? "تم الحفظ في ألبوم الكاميرا ✅" : "تعذر الحفظ"
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    saveToast = nil
                }
            }
        }
    }
}

struct SingleMediaPageView: View {
    let item: MediaItem
    let isCurrentPage: Bool
    let isMuted: Bool
    let autoAdvance: Bool
    let onVideoEnded: () -> Void

    @State private var player: AVPlayer? = nil
    @State private var loadedImage: UIImage? = nil
    @State private var endObserver: NSObjectProtocol? = nil

    @State private var isSpeed2x: Bool = false

    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                Group {
                    if item.isVideo {
                        if let player = player {
                            VideoPlayer(player: player)
                                .ignoresSafeArea()
                        } else {
                            ProgressView()
                                .tint(.yellow)
                                .scaleEffect(1.3)
                        }
                    } else {
                        if let uiImage = loadedImage {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ProgressView()
                                .tint(.yellow)
                        }
                    }
                }
                .scaleEffect(zoomScale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { val in
                            let newScale = lastZoomScale * val
                            zoomScale = min(max(1.0, newScale), 4.5)
                        }
                        .onEnded { _ in
                            if zoomScale <= 1.05 {
                                withAnimation(.spring()) {
                                    zoomScale = 1.0
                                    lastZoomScale = 1.0
                                }
                            } else {
                                lastZoomScale = zoomScale
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if zoomScale > 1.05 {
                            zoomScale = 1.0
                            lastZoomScale = 1.0
                        } else {
                            zoomScale = 2.4
                            lastZoomScale = 2.4
                        }
                    }
                }

                // منطقة الجهة اليسرى لتسريع الفيديو 2x عند الضغط المطول
                if item.isVideo {
                    HStack(spacing: 0) {
                        Color.white.opacity(0.001)
                            .frame(width: geo.size.width * 0.35)
                            .padding(.vertical, 95)
                            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, pressing: { pressing in
                                if pressing {
                                    isSpeed2x = true
                                    player?.rate = 2.0
                                } else if isSpeed2x {
                                    isSpeed2x = false
                                    player?.rate = 1.0
                                }
                            }, perform: {})

                        Spacer()
                    }
                    .environment(\.layoutDirection, .leftToRight)
                }

                if isSpeed2x {
                    VStack {
                        HStack(spacing: 6) {
                            Image(systemName: "forward.fill")
                            Text("السرعة 2x")
                                .font(.subheadline.bold())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.yellow)
                        .foregroundColor(.black)
                        .cornerRadius(20)
                        .shadow(radius: 6)
                        .padding(.top, 64)

                        Spacer()
                    }
                }
            }
        }
        .onAppear {
            if isCurrentPage {
                activateMedia()
            } else if !item.isVideo && loadedImage == nil {
                loadPhotoOptimized()
            }
        }
        .onChange(of: isCurrentPage) { active in
            zoomScale = 1.0
            lastZoomScale = 1.0
            isSpeed2x = false

            if active {
                activateMedia()
            } else {
                deactivateVideo()
            }
        }
        .onChange(of: isMuted) { muted in
            player?.isMuted = muted
        }
        .onDisappear {
            deactivateVideo()
        }
    }

    private func loadPhotoOptimized() {
        let fileURL = item.url
        Task.detached(priority: .userInitiated) {
            let img = ThumbnailCacheManager.downsampleImage(at: fileURL, maxPixelSize: 1600)
            await MainActor.run {
                self.loadedImage = img
            }
        }
    }

    private func activateMedia() {
        if item.isVideo {
            if player == nil {
                let playerItem = AVPlayerItem(url: item.url)
                let avPlayer = AVPlayer(playerItem: playerItem)
                avPlayer.isMuted = isMuted
                player = avPlayer

                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: playerItem,
                    queue: .main
                ) { _ in
                    if autoAdvance {
                        onVideoEnded()
                    } else {
                        avPlayer.seek(to: .zero)
                        avPlayer.play()
                    }
                }
            }
            player?.isMuted = isMuted
            player?.seek(to: .zero)
            player?.play()
        } else if loadedImage == nil {
            loadPhotoOptimized()
        }
    }

    private func deactivateVideo() {
        isSpeed2x = false
        player?.pause()
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        player = nil
    }
}

// MARK: - 12. شاشة الإعدادات

struct SettingsScreenView: View {
    @ObservedObject var vm: VaultViewModel

    @State private var draftAutoDownload: Bool = false
    @State private var draftScheduleTime: Date = Date()
    @State private var draftTargetCategory: Int = -1
    @State private var draftUseFaceID: Bool = false
    @State private var draftAutoCleanEnabled: Bool = false
    @State private var draftAutoCleanDays: Int = 7

    @State private var draftWifiOnly: Bool = false
    @State private var draftKeepAwake: Bool = true
    @State private var draftAutoAdvance: Bool = true
    @State private var draftStartMuted: Bool = false
    @State private var draftHaptic: Bool = true
    @State private var draftHideEmpty: Bool = false

    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var showAlert: Bool = false

    private var hasUnsavedChanges: Bool {
        let cal = Calendar.current
        let h = cal.component(.hour, from: draftScheduleTime)
        let m = cal.component(.minute, from: draftScheduleTime)
        return draftAutoDownload != vm.autoDownloadEnabled ||
               h != vm.autoDownloadHour ||
               m != vm.autoDownloadMinute ||
               draftTargetCategory != vm.autoDownloadTargetCategory ||
               draftUseFaceID != vm.useFaceID ||
               draftAutoCleanEnabled != vm.autoCleanEnabled ||
               draftAutoCleanDays != vm.autoCleanDays ||
               draftWifiOnly != vm.wifiOnlyDownload ||
               draftKeepAwake != vm.keepScreenAwake ||
               draftAutoAdvance != vm.autoAdvancePlayer ||
               draftStartMuted != vm.startVideosMuted ||
               draftHaptic != vm.hapticOnComplete ||
               draftHideEmpty != vm.hideEmptyFolders
    }

    var body: some View {
        NavigationStack {
            Form {
                if hasUnsavedChanges {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.orange)
                            Text("لديك تعديلات غير محفوظة! اضغط على زر (حفظ الإعدادات) بالأسفل لاعتمادها.")
                                .font(.caption.bold())
                                .foregroundColor(.orange)
                        }
                    }
                }

                Section(header: Text("نسخ واستعادة الحسابات (\(vm.accounts.count) حساب)")) {
                    Button {
                        alertTitle = "نسخ الحسابات 📋"
                        alertMessage = vm.exportAccountsToClipboard()
                        showAlert = true
                    } label: {
                        Label("نسخ جميع الحسابات وتقسيماتها للحافظة", systemImage: "doc.on.doc.fill")
                            .foregroundColor(.yellow)
                    }

                    Button {
                        alertTitle = "استعادة الحسابات 📥"
                        alertMessage = vm.importAccountsFromClipboard()
                        showAlert = true
                    } label: {
                        Label("استعادة / لصق الحسابات من الحافظة", systemImage: "arrow.down.doc.fill")
                            .foregroundColor(.green)
                    }
                }

                Section(header: Text("التحميل التلقائي اليومي")) {
                    Toggle("تفعيل التحميل التلقائي", isOn: $draftAutoDownload)

                    DatePicker("وقت التحميل اليومي", selection: $draftScheduleTime, displayedComponents: .hourAndMinute)

                    Picker("الخانة المستهدفة بالتحميل", selection: $draftTargetCategory) {
                        Text("جميع الخانات (الحسابات المحددة)").tag(-1)
                        Text("خانة 1 فقط").tag(0)
                        Text("خانة 2 فقط").tag(1)
                        Text("خانة 3 فقط").tag(2)
                    }
                }

                Section(header: Text("خيارات التحميل الذكية")) {
                    Toggle("التحميل عبر الواي فاي (Wi-Fi) فقط", isOn: $draftWifiOnly)
                    Toggle("منع قفل شاشة الجوال أثناء التحميل", isOn: $draftKeepAwake)
                    Toggle("اهتزاز تنبيهي عند اكتمال التحميل", isOn: $draftHaptic)
                }

                Section(header: Text("خيارات مشغل الصور والفيديو والمعرض")) {
                    Toggle("الانتقال التلقائي للسنابة التالية بعد انتهاء الفيديو", isOn: $draftAutoAdvance)
                    Toggle("بدء تشغيل الفيديوهات بدون صوت (كتم افتراضي)", isOn: $draftStartMuted)
                    Toggle("إخفاء مجلدات الحسابات الفارغة في المعرض", isOn: $draftHideEmpty)
                }

                Section(header: Text("الأمان والخصوصية")) {
                    Toggle("قفل التطبيق ببصمة الوجه (FaceID)", isOn: $draftUseFaceID)
                }

                Section(header: Text("تنظيف الذاكرة والمساحة (\(vm.cachedVaultSizeText))")) {
                    Toggle("حذف المقاطع القديمة تلقائياً", isOn: $draftAutoCleanEnabled)
                    Stepper("الاحتفاظ بالمقاطع لمدة: \(draftAutoCleanDays) أيام", value: $draftAutoCleanDays, in: 1...90)
                }

                Section {
                    Button {
                        let cal = Calendar.current
                        let h = cal.component(.hour, from: draftScheduleTime)
                        let m = cal.component(.minute, from: draftScheduleTime)
                        vm.applyAndSaveSettings(
                            autoDownload: draftAutoDownload,
                            hour: h,
                            minute: m,
                            targetCategory: draftTargetCategory,
                            faceID: draftUseFaceID,
                            cleanEnabled: draftAutoCleanEnabled,
                            cleanDays: draftAutoCleanDays,
                            wifiOnly: draftWifiOnly,
                            keepAwake: draftKeepAwake,
                            autoAdvance: draftAutoAdvance,
                            startMuted: draftStartMuted,
                            haptic: draftHaptic,
                            hideEmpty: draftHideEmpty
                        )
                        alertTitle = "تم الحفظ ✅"
                        alertMessage = "تم حفظ واعتماد جميع إعداداتك بنجاح."
                        showAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                            Text("حفظ الإعدادات واعتماد التغييرات")
                                .font(.headline.bold())
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(hasUnsavedChanges ? Color.green : Color.yellow)
                    .foregroundColor(hasUnsavedChanges ? .white : .black)

                    if hasUnsavedChanges {
                        Button(role: .destructive) {
                            syncDraftsFromViewModel()
                        } label: {
                            HStack {
                                Spacer()
                                Text("إلغاء التعديلات والرجوع للإعدادات المحفوظة")
                                    .font(.caption.bold())
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("الإعدادات ⚙️")
            .onAppear {
                syncDraftsFromViewModel()
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("ممتاز", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    private func syncDraftsFromViewModel() {
        draftAutoDownload = vm.autoDownloadEnabled
        draftTargetCategory = vm.autoDownloadTargetCategory
        draftUseFaceID = vm.useFaceID
        draftAutoCleanEnabled = vm.autoCleanEnabled
        draftAutoCleanDays = vm.autoCleanDays
        draftWifiOnly = vm.wifiOnlyDownload
        draftKeepAwake = vm.keepScreenAwake
        draftAutoAdvance = vm.autoAdvancePlayer
        draftStartMuted = vm.startVideosMuted
        draftHaptic = vm.hapticOnComplete
        draftHideEmpty = vm.hideEmptyFolders

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = vm.autoDownloadHour
        comps.minute = vm.autoDownloadMinute
        draftScheduleTime = Calendar.current.date(from: comps) ?? Date()
    }
}

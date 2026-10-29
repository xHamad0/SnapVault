import SwiftUI
import AVKit
import AVFoundation
import LocalAuthentication
import Photos
import UIKit
import Network

// MARK: - 1. Models

struct SnapAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var username: String
    var category: Int = 0 // 0: خانة 1, 1: خانة 2, 2: خانة 3
    var isSelectedForDownload: Bool = true // التحديد للتحميل (النقطة 1)

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

struct MediaItem: Identifiable, Equatable {
    let id: String
    let url: URL
    let isVideo: Bool
    let creationDate: Date
    let username: String
}

// هيكل جلسة المشغل لمنع الشاشة السوداء نهائياً (النقطة 3)
struct PlayerSession: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let startIndex: Int
}

// MARK: - 2. فاحص الاتصال بالواي فاي (لإعداد التحميل عبر Wi-Fi فقط)

class NetworkMonitor {
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

// MARK: - 3. مستخرج الصور المصغرة للفيديوهات ومدة المقطع (Video Thumbnail & Duration Cache)

class ThumbnailCacheManager {
    static let shared = ThumbnailCacheManager()
    private let imageCache = NSCache<NSString, UIImage>()
    private var durationCache: [String: String] = [:]

    func getThumbnail(for item: MediaItem) async -> (UIImage?, String?) {
        let key = item.url.path as NSString

        if !item.isVideo {
            if let cached = imageCache.object(forKey: key) {
                return (cached, nil)
            }
            let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let data = try? Data(contentsOf: item.url),
                      let img = UIImage(data: data) else { return nil }
                return img
            }.value
            if let img = loaded {
                imageCache.setObject(img, forKey: key)
            }
            return (loaded, nil)
        } else {
            if let cachedImg = imageCache.object(forKey: key),
               let cachedDur = durationCache[item.url.path] {
                return (cachedImg, cachedDur)
            }

            return await Task.detached(priority: .utility) {
                let asset = AVURLAsset(url: item.url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 360, height: 360)

                var generatedImage: UIImage? = nil
                let time = CMTime(seconds: 0.05, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    generatedImage = UIImage(cgImage: cgImage)
                }

                let durationSeconds = Int(round(CMTimeGetSeconds(asset.duration)))
                let mins = max(0, durationSeconds) / 60
                let secs = max(0, durationSeconds) % 60
                let durationStr = String(format: "%d:%02d", mins, secs)

                if let img = generatedImage {
                    self.imageCache.setObject(img, forKey: key)
                }
                await MainActor.run {
                    self.durationCache[item.url.path] = durationStr
                }
                return (generatedImage, durationStr)
            }.value
        }
    }
}

// MARK: - 4. Silent Background Audio Keep-Alive (للعمل في الخلفية أثناء تصفح الجوال)

class BackgroundKeepAliveManager {
    static let shared = BackgroundKeepAliveManager()
    private var audioPlayer: AVAudioPlayer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func startKeepAlive() {
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SnapVaultDownload") { [weak self] in
                self?.stopKeepAlive()
            }
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if audioPlayer == nil {
                let silentWavData = Self.makeSilentWavData()
                audioPlayer = try AVAudioPlayer(data: silentWavData)
                audioPlayer?.numberOfLoops = -1
                audioPlayer?.volume = 0.0
                audioPlayer?.prepareToPlay()
            }
            if audioPlayer?.isPlaying == false {
                audioPlayer?.play()
            }
        } catch {
            print("Background KeepAlive Error: \(error)")
        }
    }

    func stopKeepAlive() {
        audioPlayer?.stop()
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private static func makeSilentWavData() -> Data {
        let sampleRate: Int32 = 8000
        let numSamples: Int32 = 8000
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
        data.append(Data(count: Int(dataSize)))
        return data
    }
}

// MARK: - 5. ViewModel (المحرك الأساسي + جميع الإضافات)

@MainActor
class VaultViewModel: ObservableObject {
    static let shared = VaultViewModel()

    @Published var accounts: [SnapAccount] = []
    @Published var failedAccounts: [FailedAccountItem] = []
    @Published var logs: [String] = []

    @Published var isDownloading: Bool = false
    @Published var isPaused: Bool = false
    @Published var progressText: String = ""

    // الإعدادات الأساسية + الخيارات الإضافية المفيدة (النقطة 5)
    @Published var autoDownloadEnabled: Bool = false
    @Published var autoDownloadHour: Int = 1
    @Published var autoDownloadMinute: Int = 0
    @Published var autoDownloadTargetCategory: Int = -1
    @Published var useFaceID: Bool = false
    @Published var autoCleanEnabled: Bool = false
    @Published var autoCleanDays: Int = 7

    // خيارات الإعدادات الجديدة المفيدة (مع تشغيل وإيقاف)
    @Published var wifiOnlyDownload: Bool = false          // التحميل عبر الواي فاي فقط
    @Published var keepScreenAwake: Bool = true            // منع قفل الشاشة أثناء التحميل
    @Published var autoAdvancePlayer: Bool = true          // الانتقال التلقائي للسنابة التالية بالمشغل
    @Published var startVideosMuted: Bool = false          // بدء تشغيل الفيديو بدون صوت
    @Published var hapticOnComplete: Bool = true           // اهتزاز تنبيهي عند اكتمال التحميل
    @Published var hideEmptyFolders: Bool = false          // إخفاء الحسابات الفارغة في المعرض

    @Published var isUnlocked: Bool = true
    @Published var mediaRefreshTrigger: UUID = UUID()

    private var downloadTask: Task<Void, Never>?
    private var lastAutoDownloadDateKey = "SnapVault_LastAutoRunDate"

    init() {
        _ = NetworkMonitor.shared
        loadAccounts()
        loadSettings()
        if useFaceID {
            isUnlocked = false
        }
        performAutoCleanupIfNeeded()
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

    // MARK: إدارة الحسابات والتحديد
    func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: "SnapVault_Accounts"),
           let decoded = try? JSONDecoder().decode([SnapAccount].self, from: data) {
            accounts = decoded
        }
    }

    func saveAccounts() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: "SnapVault_Accounts")
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
            .replacingOccurrences(of: "@", with: "")
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

    // MARK: إدارة الإعدادات
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

    // MARK: أوامر التحميل (تحترم الحسابات المحددة فقط)
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

        downloadTask = Task {
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
                        appendLog("✅ @\(acc.username): تم حفظ \(savedCount) مقطع جديد")
                    } else {
                        appendLog("ℹ️ @\(acc.username): لا توجد مقاطع جديدة (محدث)")
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

                mediaRefreshTrigger = UUID()
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

    // MARK: - محرك التحميل الأساسي (__NEXT_DATA__) محفوظ بالكامل بدون تغيير

    private struct StorySnapInfo {
        let id: String
        let mediaUrl: String
        let isVideo: Bool
        let timestamp: TimeInterval
    }

    private func downloadStoriesForAccount(_ account: SnapAccount) async -> Result<Int, Error> {
        let username = account.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://www.snapchat.com/add/\(username)") else {
            return .failure(NSError(domain: "SnapVault", code: 1, userInfo: [NSLocalizedDescriptionKey: "رابط الحساب غير صالح"]))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("ar,en-US;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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

            let snaps = parseSnapsFromNextData(rootObj)
            if snaps.isEmpty {
                return .failure(NSError(domain: "SnapVault", code: 4, userInfo: [NSLocalizedDescriptionKey: "لا توجد ستوريات عامة متاحة حالياً"]))
            }

            let folderURL = accountFolder(for: username)
            var savedCount = 0

            for snap in snaps {
                if Task.isCancelled { break }
                while isPaused && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                if Task.isCancelled { break }

                let ext = snap.isVideo ? "mp4" : "jpg"
                let safeID = snap.id.replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_")
                let fileName = "\(Int(snap.timestamp))_\(safeID).\(ext)"
                let fileURL = folderURL.appendingPathComponent(fileName)

                if FileManager.default.fileExists(atPath: fileURL.path) {
                    continue
                }

                guard let mediaURL = URL(string: snap.mediaUrl) else { continue }
                let (mediaData, mediaResp) = try await URLSession.shared.data(from: mediaURL)
                if let httpMedia = mediaResp as? HTTPURLResponse, httpMedia.statusCode == 200, !mediaData.isEmpty {
                    try mediaData.write(to: fileURL, options: .atomic)
                    let snapDate = Date(timeIntervalSince1970: snap.timestamp)
                    try? FileManager.default.setAttributes([.creationDate: snapDate, .modificationDate: snapDate], ofItemAtPath: fileURL.path)
                    savedCount += 1
                }
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

    private func parseSnapsFromNextData(_ root: [String: Any]) -> [StorySnapInfo] {
        var results: [StorySnapInfo] = []
        guard let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any] else {
            return results
        }

        if let story = pageProps["story"] as? [String: Any],
           let snapList = story["snapList"] as? [[String: Any]] {
            for item in snapList {
                if let info = extractSingleSnap(from: item) {
                    results.append(info)
                }
            }
        }

        if results.isEmpty,
           let highlights = pageProps["curatedHighlights"] as? [[String: Any]] {
            for highlight in highlights {
                if let snapList = highlight["snapList"] as? [[String: Any]] {
                    for item in snapList {
                        if let info = extractSingleSnap(from: item) {
                            results.append(info)
                        }
                    }
                }
            }
        }

        return results
    }

    private func extractSingleSnap(from item: [String: Any]) -> StorySnapInfo? {
        guard let snapUrls = item["snapUrls"] as? [String: Any],
              let mediaUrl = snapUrls["mediaUrl"] as? String,
              !mediaUrl.isEmpty else {
            return nil
        }

        var snapId = UUID().uuidString
        if let idDict = item["snapId"] as? [String: Any], let val = idDict["value"] as? String {
            snapId = val
        } else if let val = item["snapId"] as? String {
            snapId = val
        }

        let mediaType = item["snapMediaType"] as? Int ?? 0
        let isVideo = (mediaType == 1) || mediaUrl.lowercased().contains(".mp4")

        var timestamp = Date().timeIntervalSince1970
        if let tsDict = item["timestampInSec"] as? [String: Any],
           let valStr = tsDict["value"] as? String,
           let valDouble = Double(valStr) {
            timestamp = valDouble
        } else if let tsDict = item["timestampInSec"] as? [String: Any],
                  let valNum = tsDict["value"] as? Double {
            timestamp = valNum
        }

        return StorySnapInfo(id: snapId, mediaUrl: mediaUrl, isVideo: isVideo, timestamp: timestamp)
    }

    // MARK: - إدارة الملفات والأستوديو الداخلي (مع مجلد جميع الحسابات)

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

    func fetchSavedUserFolders() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: baseVaultDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let allFolders = contents.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }.sorted()
        if hideEmptyFolders {
            return allFolders.filter { !fetchMediaItems(for: $0).isEmpty }
        }
        return allFolders
    }

    // جلب مقاطع حساب محدد
    func fetchMediaItems(for username: String) -> [MediaItem] {
        let folder = accountFolder(for: username)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [MediaItem] = []
        for file in files {
            let ext = file.pathExtension.lowercased()
            guard ["mp4", "mov", "jpg", "jpeg", "png"].contains(ext) else { continue }
            let isVideo = (ext == "mp4" || ext == "mov")
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            let cDate = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date) ?? Date()

            items.append(MediaItem(
                id: "\(username)_\(file.lastPathComponent)",
                url: file,
                isVideo: isVideo,
                creationDate: cDate,
                username: username
            ))
        }
        return items
    }

    // جلب جميع التحميلات من كل الحسابات في مجلد واحد (النقطة 4)
    func fetchAllAccountsMediaItems() -> [MediaItem] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: baseVaultDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let folders = contents.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
        var all: [MediaItem] = []
        for user in folders {
            all.append(contentsOf: fetchMediaItems(for: user))
        }
        return all
    }

    // حساب رقم السنابة من مجموع سنابات الحساب في نفس يوم المقطع (النقطة 2)
    func accountDailySnapRank(for item: MediaItem) -> (index: Int, total: Int) {
        let cal = Calendar.current
        let userItems = fetchMediaItems(for: item.username)
        let sameDayItems = userItems
            .filter { cal.isDate($0.creationDate, inSameDayAs: item.creationDate) }
            .sorted { $0.creationDate < $1.creationDate } // ترتيب زمني من أول سنابة نزلها الحساب في ذلك اليوم

        if let idx = sameDayItems.firstIndex(where: { $0.url.path == item.url.path }) {
            return (idx + 1, sameDayItems.count)
        }
        return (1, max(1, sameDayItems.count))
    }

    func deleteMediaItem(_ item: MediaItem) {
        try? FileManager.default.removeItem(at: item.url)
        mediaRefreshTrigger = UUID()
    }

    func performAutoCleanupIfNeeded() {
        guard autoCleanEnabled else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -autoCleanDays, to: Date()) ?? Date()
        for item in fetchAllAccountsMediaItems() {
            if item.creationDate < cutoff {
                try? FileManager.default.removeItem(at: item.url)
            }
        }
        mediaRefreshTrigger = UUID()
    }

    func totalVaultSizeString() -> String {
        var totalBytes: Int64 = 0
        for item in fetchAllAccountsMediaItems() {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path),
               let size = attrs[.size] as? Int64 {
                totalBytes += size
            }
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytes)
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

// MARK: - 6. الواجهة الرئيسية (ContentView)

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

// MARK: - 7. شاشة الحسابات والتحميل (الأقسام الـ 3 + تحديد الحسابات للتحميل + السحب + الأخطاء)

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

                    // شريط الخانات الـ 3
                    Picker("أقسام الحسابات", selection: $selectedCategory) {
                        Text("خانة 1 (\(vm.selectedAccounts(for: 0).count)/\(vm.accounts(for: 0).count))").tag(0)
                        Text("خانة 2 (\(vm.selectedAccounts(for: 1).count)/\(vm.accounts(for: 1).count))").tag(1)
                        Text("خانة 3 (\(vm.selectedAccounts(for: 2).count)/\(vm.accounts(for: 2).count))").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    // إضافة حساب جديد
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

                    // قائمة الحسابات مع تحديد من يريد المستخدم تحميله اليوم (النقطة 1)
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
                                        // زر التحديد (صح / بدون صح) لتحديد هل يحمل الحساب اليوم أم لا
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

                                        // نقل الحساب لخانة أخرى
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

                                        // تحميل هذا الحساب منفرداً فوراً
                                        Button {
                                            vm.startDownloadSingle(acc)
                                        } label: {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .foregroundColor(.blue)
                                                .font(.title3)
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(vm.isDownloading)

                                        // حذف الحساب
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

                    // أزرار التحميل (تحمل الحسابات المحددة بعلامة صح فقط)
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

                    // سجل العمليات
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

                    // خانة الحسابات المتعثرة تحت السجل
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

// MARK: - 8. شاشة المعرض والمجلدات (مع مجلد جميع الحسابات + مجلد كل حساب)

struct GalleryFoldersView: View {
    @ObservedObject var vm: VaultViewModel

    var folders: [String] {
        _ = vm.mediaRefreshTrigger
        return vm.fetchSavedUserFolders()
    }

    var allItems: [MediaItem] {
        _ = vm.mediaRefreshTrigger
        return vm.fetchAllAccountsMediaItems()
    }

    var body: some View {
        NavigationStack {
            List {
                // القسم الأول: مجلد جامع لكل التحميلات من جميع الحسابات (النقطة 4)
                Section(header: Text("المجلد الشامل")) {
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

                // القسم الثاني: مجلدات الحسابات كل حساب لحاله
                Section(header: Text("مجلدات الحسابات (\(folders.count))")) {
                    if folders.isEmpty {
                        Text("لا توجد مجلدات حسابات محفوظة بعد.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(folders, id: \.self) { username in
                            let items = vm.fetchMediaItems(for: username)
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
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .navigationTitle("خزنة المقاطع 📁")
        }
    }
}

struct AccountMediaDetailView: View {
    @ObservedObject var vm: VaultViewModel
    let username: String? // nil = جميع التحميلات من كل الحسابات

    @State private var newestFirst: Bool = true
    @State private var filterToday: Bool = false
    @State private var filterYesterday: Bool = false

    // جلسة المشغل المضمونة لمنع الشاشة السوداء (النقطة 3)
    @State private var activePlayerSession: PlayerSession? = nil
    @State private var statusAlertMessage: String? = nil

    var filteredAndSortedItems: [MediaItem] {
        _ = vm.mediaRefreshTrigger
        let baseItems = (username == nil) ? vm.fetchAllAccountsMediaItems() : vm.fetchMediaItems(for: username!)
        let cal = Calendar.current

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
            if a.creationDate == b.creationDate {
                return newestFirst ? (a.id > b.id) : (a.id < b.id)
            }
            return newestFirst ? (a.creationDate > b.creationDate) : (a.creationDate < b.creationDate)
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

            // شريط الفرز (الأحدث/الأقدم) وفلتر (اليوم / أمس)
            VStack(spacing: 8) {
                Picker("ترتيب العرض", selection: $newestFirst) {
                    Text("الأحدث أولاً ⬇️").tag(true)
                    Text("الأقدم أولاً ⬆️").tag(false)
                }
                .pickerStyle(.segmented)

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
            .padding(.horizontal, 10)
            .padding(.top, 4)

            // الشبكة المتراصة للصور والفيديوهات
            if items.isEmpty {
                Spacer()
                Text("لا توجد مقاطع مطابقة للفلتر المحدد")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 1.5) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            MediaThumbnailCell(
                                item: item,
                                showUsernameBadge: username == nil
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                activePlayerSession = PlayerSession(items: items, startIndex: index)
                            }
                            .contextMenu {
                                Button {
                                    saveToCameraRoll(item)
                                } label: {
                                    Label("حفظ في ألبوم الكاميرا", systemImage: "square.and.arrow.down")
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
        }
        .fullScreenCover(item: $activePlayerSession) { session in
            SwipeableMediaPlayerView(
                vm: vm,
                items: session.items,
                startIndex: session.startIndex,
                onClose: { activePlayerSession = nil }
            )
        }
        .alert(statusAlertMessage ?? "", isPresented: Binding(
            get: { statusAlertMessage != nil },
            set: { if !$0 { statusAlertMessage = nil } }
        )) {
            Button("حسناً", role: .cancel) {}
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
            .overlay(alignment: .topLeading) {
                if showUsernameBadge {
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
                // الشعار الصغير في الزاوية السفلية اليمنى
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

// MARK: - 9. مشغل الصور والفيديو المطور (سلس بدون شاشة سوداء + العدّاد المزدوج أسفل الشاشة)

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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !items.isEmpty {
                TabView(selection: $currentIndex) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        SingleMediaPageView(
                            item: item,
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
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .environment(\.layoutDirection, .leftToRight)
                .ignoresSafeArea()
            }

            // الأشرطة العلوية والسفلية (مع العدّادين المطلوبين في النقطة 2)
            VStack {
                // الشريط العلوي
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

                // الشريط السفلي: يحتوي على الرقمين (رقم المقطع من الكل + رقم السنابة من سنابات الحساب لليوم)
                if let item = currentItem {
                    let dailyRank = vm.accountDailySnapRank(for: item)

                    VStack(spacing: 6) {
                        HStack(spacing: 10) {
                            // الرقم الأول: من المجموع الكلي المعروض
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

                            // الرقم الثاني: رقم السنابة من مجموع سنابات الحساب في ذلك اليوم
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

    var body: some View {
        ZStack {
            Color.black

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
        .onAppear {
            if isCurrentPage {
                activateMedia()
            } else if !item.isVideo && loadedImage == nil {
                loadPhoto()
            }
        }
        .onChange(of: isCurrentPage) { active in
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

    private func loadPhoto() {
        if let data = try? Data(contentsOf: item.url),
           let img = UIImage(data: data) {
            loadedImage = img
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
            loadPhoto()
        }
    }

    private func deactivateVideo() {
        player?.pause()
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        player = nil
    }
}

// MARK: - 10. شاشة الإعدادات الموسعة (خيارات إضافية مفيدة + زر الحفظ الإلزامي)

struct SettingsScreenView: View {
    @ObservedObject var vm: VaultViewModel

    @State private var draftAutoDownload: Bool = false
    @State private var draftScheduleTime: Date = Date()
    @State private var draftTargetCategory: Int = -1
    @State private var draftUseFaceID: Bool = false
    @State private var draftAutoCleanEnabled: Bool = false
    @State private var draftAutoCleanDays: Int = 7

    // الخيارات الإضافية المفيدة (النقطة 5)
    @State private var draftWifiOnly: Bool = false
    @State private var draftKeepAwake: Bool = true
    @State private var draftAutoAdvance: Bool = true
    @State private var draftStartMuted: Bool = false
    @State private var draftHaptic: Bool = true
    @State private var draftHideEmpty: Bool = false

    @State private var showSavedConfirmation: Bool = false

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

                Section(header: Text("تنظيف الذاكرة والمساحة (\(vm.totalVaultSizeString()))")) {
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
                        showSavedConfirmation = true
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
            .alert("تم الحفظ ✅", isPresented: $showSavedConfirmation) {
                Button("ممتاز", role: .cancel) {}
            } message: {
                Text("تم حفظ واعتماد جميع إعداداتك بنجاح.")
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

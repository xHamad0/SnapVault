import SwiftUI
import Photos
import AVKit
import BackgroundTasks

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

struct LocalSavedFile: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let isVideo: Bool
    let accountName: String
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
    @Published var statusLog: [String] = []
    @Published var progress: Double = 0.0
    @Published var savedFiles: [LocalSavedFile] = []
    @Published var alertMessage: String? = nil

    private let accountsKey = "SavedSnapAccounts"

    init() {
        loadAccounts()
        loadSavedFiles()
    }

    func addAccount(_ username: String) {
        let clean = username
            .replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !clean.isEmpty, !accounts.contains(where: { $0.username == clean }) else { return }
        accounts.append(SnapAccount(username: clean))
    }

    func removeAccount(at offsets: IndexSet) {
        accounts.remove(atOffsets: offsets)
    }

    func selectAllAccounts(_ select: Bool) {
        for i in 0..<accounts.count {
            accounts[i].isSelected = select
        }
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

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        statusLog.insert("[\(formatter.string(from: Date()))] \(message)", at: 0)
    }

    // تحميل حساب واحد محدد بالذات
    func downloadSingleAccount(_ account: SnapAccount) async {
        guard !isDownloading else { return }
        isDownloading = true
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
                log("⬇️ جاري حفظ \(filteredItems.count) عنصر من @\(account.username)...")
                for (itemIndex, media) in filteredItems.enumerated() {
                    try await downloadToAppStorage(media: media, username: account.username, index: itemIndex + 1)
                }
                log("✅ تم حفظ ستوري @\(account.username) بنجاح!")
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
                    log("⬇️ حفظ \(filteredItems.count) عنصر من @\(account.username)...")
                    for (itemIndex, media) in filteredItems.enumerated() {
                        try await downloadToAppStorage(media: media, username: account.username, index: itemIndex + 1)
                    }
                    log("✅ انتهى حساب @\(account.username)")
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

    private func downloadToAppStorage(media: SnapMediaItem, username: String, index: Int) async throws {
        let (tempURL, _) = try await URLSession.shared.download(from: media.url)
        let ext = media.isVideo ? "mp4" : "jpg"
        let fileName = "\(username)_\(media.timestamp)_\(index).\(ext)"

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

        guard let enumerator = fileManager.enumerator(at: rootDir, includingPropertiesForKeys: nil) else { return }
        var loaded: [LocalSavedFile] = []
        var seenNames = Set<String>()

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "mp4" || ext == "jpg" {
                let name = fileURL.lastPathComponent
                if !seenNames.contains(name) {
                    seenNames.insert(name)
                    let accountName = name.components(separatedBy: "_").first ?? "غير معروف"
                    loaded.append(LocalSavedFile(
                        url: fileURL,
                        fileName: name,
                        isVideo: ext == "mp4",
                        accountName: accountName
                    ))
                }
            }
        }
        savedFiles = loaded.sorted { $0.fileName > $1.fileName }
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
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file.url)
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

    func deleteFile(_ file: LocalSavedFile) {
        try? FileManager.default.removeItem(at: file.url)
        loadSavedFiles()
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

// MARK: - 3. واجهة المستخدم (UI)

struct ContentView: View {
    @StateObject private var manager = SnapStoryManager()

    var body: some View {
        TabView {
            DownloaderHomeView(manager: manager)
                .tabItem {
                    Label("الحسابات والتحميل", systemImage: "arrow.down.circle.fill")
                }

            InternalGalleryView(manager: manager)
                .tabItem {
                    Label("محفوظات التطبيق (\(manager.savedFiles.count))", systemImage: "folder.fill")
                }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .alert(item: Binding(
            get: { manager.alertMessage.map { AlertItem(message: $0) } },
            set: { _ in manager.alertMessage = nil }
        )) { item in
            Alert(title: Text("تنبيه"), message: Text(item.message), dismissButton: .default(Text("حسناً")))
        }
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    let message: String
}

struct DownloaderHomeView: View {
    @ObservedObject var manager: SnapStoryManager
    @State private var usernameInput: String = ""

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
                        ForEach($manager.accounts) { $account in
                            HStack(spacing: 10) {
                                Button(action: { account.isSelected.toggle() }) {
                                    Image(systemName: account.isSelected ? "checkmark.square.fill" : "square")
                                        .foregroundColor(account.isSelected ? .blue : .gray)
                                        .font(.title3)
                                }
                                .buttonStyle(BorderlessButtonStyle())

                                Text("@\(account.username)")
                                    .bold()

                                Spacer()

                                Button(action: {
                                    Task { await manager.downloadSingleAccount(account) }
                                }) {
                                    Text("تحميل هذا لحاله")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.yellow.opacity(0.3))
                                        .foregroundColor(.primary)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .disabled(manager.isDownloading)
                            }
                        }
                        .onDelete(perform: manager.removeAccount)
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

                Section(header: Text("سجل العمليات المباشر")) {
                    ForEach(manager.statusLog, id: \.self) { log in
                        Text(log).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("محمل السناب")
        }
    }
}

struct InternalGalleryView: View {
    @ObservedObject var manager: SnapStoryManager
    @State private var selectedAccountFilter: String = "الكل"
    @State private var selectedTypeFilter: MediaFilter = .both

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
            VStack {
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

                if filteredFiles.isEmpty {
                    Spacer()
                    Text("لا توجد ملفات محفوظة بعد.").foregroundColor(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(filteredFiles) { file in
                                VStack(spacing: 8) {
                                    ZStack(alignment: .topLeading) {
                                        if file.isVideo {
                                            VideoPlayer(player: AVPlayer(url: file.url))
                                                .frame(height: 220)
                                                .cornerRadius(10)
                                        } else if let uiImage = UIImage(contentsOfFile: file.url.path) {
                                            Image(uiImage: uiImage)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(height: 220)
                                                .clipped()
                                                .cornerRadius(10)
                                        }

                                        Text("@\(file.accountName)")
                                            .font(.caption2.bold())
                                            .padding(5)
                                            .background(Color.black.opacity(0.6))
                                            .foregroundColor(.white)
                                            .cornerRadius(6)
                                            .padding(6)
                                    }

                                    HStack {
                                        Button(action: {
                                            manager.exportSingleFileToPhotos(file)
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "square.and.arrow.down.fill")
                                                Text("حفظ للاستوديو").font(.caption.bold())
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
        }
    }
}

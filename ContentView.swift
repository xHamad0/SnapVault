import SwiftUI
import AVKit
import AVFoundation
import Photos
import LocalAuthentication

// MARK: - نماذج البيانات
struct SnapAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var username: String
    var isSelected: Bool = true
}

struct SavedMediaItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let filename: String
    let username: String
    let dateString: String
    let isVideo: Bool
    let creationDate: Date
    let fileSize: Int64
}

enum MediaFilter: String, CaseIterable {
    case both = "الصور والفيديو"
    case videoOnly = "الفيديو فقط"
    case imageOnly = "الصور فقط"
}

enum FolderOrganization: String, CaseIterable {
    case both = "الاثنين معاً (خاص + عام)"
    case perAccount = "مجلد خاص لكل حساب"
    case unified = "مجلد عام موحد"
}

// MARK: - مشغل الفيديو الاحترافي بملء الشاشة
struct CustomVideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    let startMuted: Bool
    var onVideoEnded: (() -> Void)?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        player.isMuted = startMuted
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
            onVideoEnded?()
        }

        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if let currentAsset = (uiViewController.player?.currentItem?.asset as? AVURLAsset),
           currentAsset.url != url {
            let newItem = AVPlayerItem(url: url)
            uiViewController.player?.replaceCurrentItem(with: newItem)
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: newItem,
                queue: .main
            ) { _ in
                onVideoEnded?()
            }
            uiViewController.player?.play()
        }
    }
}

// MARK: - عارض الوسائط الكامل مع دعم وضع القصة المتتابع (Story Mode)
struct StoryMediaViewer: View {
    let items: [SavedMediaItem]
    @State var currentIndex: Int
    let storyModeEnabled: Bool
    let startMuted: Bool
    let imageStoryDuration: Double
    @Environment(\.dismiss) var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var toastMessage: String? = nil
    @State private var imageTimer: Timer? = nil

    var currentItem: SavedMediaItem {
        items[min(max(currentIndex, 0), items.count - 1)]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // عرض الفيديو أو الصورة مباشرة من ذاكرة التطبيق
            if currentItem.isVideo {
                CustomVideoPlayerView(
                    url: currentItem.url,
                    startMuted: startMuted,
                    onVideoEnded: {
                        if storyModeEnabled {
                            goToNextItem()
                        }
                    }
                )
                .id(currentItem.id)
                .ignoresSafeArea()
            } else {
                if let data = try? Data(contentsOf: currentItem.url),
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
                        .onAppear { startImageStoryTimerIfNeeded() }
                        .onChange(of: currentIndex) { _ in
                            scale = 1.0
                            startImageStoryTimerIfNeeded()
                        }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.yellow)
                        Text("تعذر قراءة ملف الصورة")
                            .foregroundColor(.white)
                    }
                }
            }

            // شريط التقدم العلوي وأزرار التحكم
            VStack(spacing: 8) {
                if storyModeEnabled && items.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(0..<min(items.count, 30), id: \.self) { idx in
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
                            .foregroundColor(.white.opacity(0.9))
                    }

                    Spacer()

                    VStack(spacing: 2) {
                        Text("@\(currentItem.username)")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(currentItem.filename)
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 14) {
                        Button(action: saveCurrentToCameraRoll) {
                            Image(systemName: "arrow.down.to.line.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                        }

                        ShareLink(item: currentItem.url) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.yellow)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.6))

                Spacer()

                // أزرار التنقل بين المقاطع (السابق / التالي)
                if items.count > 1 {
                    HStack {
                        Button(action: goToPreviousItem) {
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

                        Text("\(currentIndex + 1) / \(items.count)")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(.yellow)
                            .cornerRadius(14)

                        Spacer()

                        Button(action: goToNextItem) {
                            HStack(spacing: 4) {
                                Text("التالي")
                                Image(systemName: "chevron.left")
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(currentIndex < items.count - 1 ? .white : .gray)
                            .cornerRadius(20)
                        }
                        .disabled(currentIndex >= items.count - 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 35)
                }
            }

            if let toast = toastMessage {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.footnote.bold())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.yellow)
                        .foregroundColor(.black)
                        .cornerRadius(20)
                        .padding(.bottom, 90)
                }
            }
        }
        .onDisappear {
            imageTimer?.invalidate()
        }
    }

    private func startImageStoryTimerIfNeeded() {
        imageTimer?.invalidate()
        guard storyModeEnabled, !currentItem.isVideo else { return }
        imageTimer = Timer.scheduledTimer(withTimeInterval: imageStoryDuration, repeats: false) { _ in
            goToNextItem()
        }
    }

    private func goToNextItem() {
        imageTimer?.invalidate()
        if currentIndex < items.count - 1 {
            withAnimation { currentIndex += 1 }
        } else if storyModeEnabled {
            dismiss()
        }
    }

    private func goToPreviousItem() {
        imageTimer?.invalidate()
        if currentIndex > 0 {
            withAnimation { currentIndex -= 1 }
        }
    }

    private func saveCurrentToCameraRoll() {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                showToast("يرجى السماح بالوصول للصور من إعدادات الآيفون")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                if currentItem.isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: currentItem.url)
                } else if let data = try? Data(contentsOf: currentItem.url),
                          let image = UIImage(data: data) {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }) { success, _ in
                showToast(success ? "تم الحفظ في ألبوم الكاميرا بنجاح" : "تعذر الحفظ في الألبوم")
            }
        }
    }

    private func showToast(_ msg: String) {
        DispatchQueue.main.async {
            withAnimation { toastMessage = msg }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation { toastMessage = nil }
            }
        }
    }
}

// MARK: - الصورة المصغرة للفيديو
struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage? = nil

    var body: some View {
        ZStack {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(white: 0.18)
            }

            Image(systemName: "play.circle.fill")
                .font(.system(size: 38))
                .foregroundColor(.white.opacity(0.9))
                .shadow(radius: 4)
        }
        .onAppear { generateThumbnail() }
    }

    private func generateThumbnail() {
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.3, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                let uiImage = UIImage(cgImage: cgImage)
                DispatchQueue.main.async { self.thumbnail = uiImage }
            }
        }
    }
}

// MARK: - الواجهة الرئيسية للتطبيق
struct ContentView: View {
    // التبويب الحالي (0: التحميل، 1: المحفوظات، 2: الإعدادات)
    @State private var selectedTab: Int = 0

    // إعدادات الميزات القابلة للتشغيل والإيقاف (تُحفظ تلقائياً)
    @AppStorage("setting_deduplication") private var enableDeduplication: Bool = true
    @AppStorage("setting_storyMode") private var enableStoryMode: Bool = true
    @AppStorage("setting_enableMerger") private var enableVideoMerger: Bool = true
    @AppStorage("setting_biometricLock") private var enableBiometricLock: Bool = false
    @AppStorage("setting_lockVaultOnly") private var lockVaultOnly: Bool = true
    @AppStorage("setting_autoCleanup") private var enableAutoCleanup: Bool = false
    @AppStorage("setting_cleanupDays") private var cleanupDays: Int = 30

    // إعدادات عامة إضافية
    @AppStorage("setting_startMuted") private var startVideosMuted: Bool = false
    @AppStorage("setting_haptics") private var enableHaptics: Bool = true
    @AppStorage("setting_maxStoriesPerUser") private var maxStoriesPerUser: Int = 20
    @AppStorage("setting_imageStoryDuration") private var imageStoryDuration: Double = 4.0
    @AppStorage("setting_autoDownload") private var autoDownloadEnabled: Bool = false

    // متغيرات الحالة
    @State private var newUsername: String = ""
    @State private var accounts: [SnapAccount] = []
    @State private var mediaFilter: MediaFilter = .both
    @State private var folderOrg: FolderOrganization = .both
    @State private var downloadTime: Date = Date()
    @State private var logs: [String] = []
    @State private var isDownloading: Bool = false
    @State private var isMerging: Bool = false
    @State private var savedItems: [SavedMediaItem] = []
    @State private var selectedAccountFilter: String = "الكل"

    // متغيرات مشغل ملء الشاشة
    @State private var showFullScreenViewer: Bool = false
    @State private var selectedViewerIndex: Int = 0

    // متغيرات القفل بالبصمة
    @State private var isUnlocked: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            if enableBiometricLock && !lockVaultOnly && !isUnlocked {
                lockScreenOverlay
            } else {
                Group {
                    if selectedTab == 0 {
                        downloaderTabView
                    } else if selectedTab == 1 {
                        if enableBiometricLock && lockVaultOnly && !isUnlocked {
                            lockScreenOverlay
                        } else {
                            vaultGalleryTabView
                        }
                    } else {
                        settingsTabView
                    }
                }
            }

            customBottomBar
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear {
            loadAccounts()
            if enableAutoCleanup {
                performAutoCleanup()
            }
            loadSavedMedia()
            if !enableBiometricLock {
                isUnlocked = true
            }
        }
        .fullScreenCover(isPresented: $showFullScreenViewer) {
            StoryMediaViewer(
                items: filteredSavedItems,
                currentIndex: selectedViewerIndex,
                storyModeEnabled: enableStoryMode,
                startMuted: startVideosMuted,
                imageStoryDuration: imageStoryDuration
            )
        }
    }

    // MARK: - شاشة القفل (FaceID)
    var lockScreenOverlay: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "faceid")
                .font(.system(size: 64))
                .foregroundColor(.yellow)

            Text("المحتوى محمي ببصمة الوجه")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("اضغط بالأسفل للتحقق من هويتك وفتح المحفوظات")
                .font(.footnote)
                .foregroundColor(.gray)

            Button(action: authenticateUser) {
                HStack {
                    Image(systemName: "lock.open.fill")
                    Text("فتح القفل الآن")
                        .fontWeight(.bold)
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(Color.yellow)
                .foregroundColor(.black)
                .cornerRadius(16)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { authenticateUser() }
    }

    // MARK: - 1. تبويب الحسابات والتحميل
    var downloaderTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("محمل السناب")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                    Spacer()
                    if enableDeduplication {
                        Label("منع التكرار مفعل", systemImage: "shield.checkered")
                            .font(.caption2.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(12)
                    }
                }
                .padding(.top, 10)

                // إدارة الحسابات
                VStack(alignment: .leading, spacing: 10) {
                    Text("إدارة الحسابات (\(accounts.count) حساب)")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    VStack(spacing: 0) {
                        HStack {
                            TextField("اكتب اليوزر (مثال: snapchat)", text: $newUsername)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundColor(.white)

                            Button(action: addAccount) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.yellow)
                            }
                        }
                        .padding()

                        Divider().background(Color.gray.opacity(0.3))

                        if accounts.isEmpty {
                            Text("لم تقم بإضافة حسابات بعد.")
                                .font(.footnote)
                                .foregroundColor(.gray)
                                .padding()
                        } else {
                            ForEach($accounts) { $account in
                                HStack {
                                    Button(action: {
                                        account.isSelected.toggle()
                                        triggerHaptic()
                                        saveAccounts()
                                    }) {
                                        Image(systemName: account.isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(account.isSelected ? .yellow : .gray)
                                    }

                                    Text(account.username)
                                        .foregroundColor(.white)
                                        .font(.body)

                                    Spacer()

                                    Button(action: { deleteAccount(account) }) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.8))
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 10)
                            }
                        }
                    }
                    .background(Color(white: 0.11))
                    .cornerRadius(16)
                }

                // إعدادات التخزين والفلترة
                VStack(alignment: .leading, spacing: 10) {
                    Text("إعدادات التخزين والفلترة")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    VStack(spacing: 0) {
                        HStack {
                            Text("نوع الوسائط")
                                .foregroundColor(.white)
                            Spacer()
                            Picker("نوع الوسائط", selection: $mediaFilter) {
                                ForEach(MediaFilter.allCases, id: \.self) { filter in
                                    Text(filter.rawValue).tag(filter)
                                }
                            }
                            .tint(.gray)
                        }
                        .padding()

                        Divider().background(Color.gray.opacity(0.3))

                        HStack {
                            Text("طريقة تنظيم المجلدات")
                                .foregroundColor(.white)
                            Spacer()
                            Picker("التنظيم", selection: $folderOrg) {
                                ForEach(FolderOrganization.allCases, id: \.self) { org in
                                    Text(org.rawValue).tag(org)
                                }
                            }
                            .tint(.gray)
                        }
                        .padding()
                    }
                    .background(Color(white: 0.11))
                    .cornerRadius(16)
                }

                // الجدولة التلقائية
                VStack(alignment: .leading, spacing: 10) {
                    Text("الجدولة التلقائية")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    VStack(spacing: 0) {
                        Toggle("تفعيل التحميل التلقائي اليومي", isOn: $autoDownloadEnabled)
                            .foregroundColor(.white)
                            .padding()

                        if autoDownloadEnabled {
                            Divider().background(Color.gray.opacity(0.3))
                            DatePicker("وقت التحميل اليومي", selection: $downloadTime, displayedComponents: .hourAndMinute)
                                .foregroundColor(.white)
                                .padding()
                        }
                    }
                    .background(Color(white: 0.11))
                    .cornerRadius(16)
                }

                // زر التحميل اليدوي
                Button(action: startSequentialDownload) {
                    HStack {
                        Image(systemName: "arrow.down.doc.fill")
                        Text(isDownloading ? "جاري التحميل بالترتيب..." : "تحميل الحسابات المحددة يدوياً بالترتيب")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(accounts.filter({ $0.isSelected }).isEmpty || isDownloading ? Color(white: 0.15) : Color.yellow)
                    .foregroundColor(accounts.filter({ $0.isSelected }).isEmpty || isDownloading ? .gray : .black)
                    .cornerRadius(16)
                }
                .disabled(accounts.filter({ $0.isSelected }).isEmpty || isDownloading)

                // سجل العمليات المباشر
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("سجل العمليات المباشر")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        Spacer()
                        if !logs.isEmpty {
                            Button("مسح السجل") { logs.removeAll() }
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        if logs.isEmpty {
                            Text("جاهز للعمل...")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(logs, id: \.self) { log in
                                Text(log)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(white: 0.08))
                    .cornerRadius(12)
                }

                Spacer(minLength: 95)
            }
            .padding()
        }
    }

    // MARK: - 2. تبويب محفوظات التطبيق
    var vaultGalleryTabView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("محفوظات التطبيق")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                    Text("المساحة المستخدمة: \(formattedTotalVaultSize()) • \(savedItems.count) ملف")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()

                if enableStoryMode && !filteredSavedItems.isEmpty {
                    Button(action: {
                        selectedViewerIndex = 0
                        showFullScreenViewer = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("عرض كقصة")
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.yellow)
                        .foregroundColor(.black)
                        .cornerRadius(16)
                    }
                }

                Button(action: loadSavedMedia) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2)
                        .foregroundColor(.yellow)
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)

            // شريط فلترة الحسابات + زر دمج المقاطع
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["الكل"] + Array(Set(savedItems.map { $0.username })).sorted(), id: \.self) { user in
                        Button(action: { selectedAccountFilter = user }) {
                            Text(user)
                                .font(.caption.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(selectedAccountFilter == user ? Color.yellow : Color(white: 0.15))
                                .foregroundColor(selectedAccountFilter == user ? .black : .white)
                                .cornerRadius(20)
                        }
                    }
                }
                .padding(.horizontal)
            }

            // زر دمج الفيديوهات في مقطع واحد
            if enableVideoMerger && filteredSavedItems.filter({ $0.isVideo }).count >= 2 {
                Button(action: mergeFilteredVideos) {
                    HStack {
                        Image(systemName: isMerging ? "hourglass" : "film.stack.fill")
                        Text(isMerging ? "جاري دمج المقاطع في فيديو واحد..." : "دمج فيديوهات (\(selectedAccountFilter)) في فيديو واحد (\(filteredSavedItems.filter({ $0.isVideo }).count) مقاطع)")
                            .font(.caption.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.25))
                    .foregroundColor(.blue)
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
                .disabled(isMerging)
            }

            if filteredSavedItems.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("لا توجد وسائط محفوظة في هذا القسم")
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                        ForEach(Array(filteredSavedItems.enumerated()), id: \.element.id) { index, item in
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .topLeading) {
                                    if item.isVideo {
                                        VideoThumbnailView(url: item.url)
                                            .frame(height: 195)
                                            .clipped()
                                            .cornerRadius(12)
                                    } else {
                                        if let data = try? Data(contentsOf: item.url),
                                           let uiImage = UIImage(data: data) {
                                            Image(uiImage: uiImage)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(height: 195)
                                                .clipped()
                                                .cornerRadius(12)
                                        } else {
                                            Color(white: 0.2)
                                                .frame(height: 195)
                                                .cornerRadius(12)
                                        }
                                    }

                                    HStack {
                                        Button(action: { deleteMediaItem(item) }) {
                                            Image(systemName: "trash.circle.fill")
                                                .font(.title3)
                                                .foregroundColor(.red)
                                                .background(Circle().fill(Color.black.opacity(0.6)))
                                        }
                                        Spacer()
                                        Text(item.isVideo ? "فيديو" : "صورة")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.black.opacity(0.65))
                                            .foregroundColor(.white)
                                            .cornerRadius(6)
                                    }
                                    .padding(6)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    triggerHaptic()
                                    selectedViewerIndex = index
                                    showFullScreenViewer = true
                                }

                                // اسم الملف (اسم الحساب + التاريخ)
                                Text(item.filename)
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .lineLimit(1)

                                Text("@\(item.username) • \(item.dateString)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            .padding(8)
                            .background(Color(white: 0.11))
                            .cornerRadius(14)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 95)
                }
            }
        }
    }

    // MARK: - 3. تبويب الإعدادات الشاملة والعامة
    var settingsTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("الإعدادات والتحكم")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                    .padding(.top, 10)

                // قسم تشغيل وإيقاف الميزات الذكية
                VStack(alignment: .leading, spacing: 10) {
                    Text("التحكم بالميزات المضافة")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    VStack(spacing: 0) {
                        Toggle(isOn: $enableDeduplication) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("منع تكرار التحميل الذكي")
                                    .foregroundColor(.white)
                                Text("تخطي السنابات التي تم تحميلها مسبقاً")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding()

                        Divider().background(Color.gray.opacity(0.3))

                        Toggle(isOn: $enableStoryMode) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("وضع القصة المتتابع (Story Mode)")
                                    .foregroundColor(.white)
                                Text("تشغيل المقاطع والصور تلقائياً وراء بعض")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding()

                        Divider().background(Color.gray.opacity(0.3))

                        Toggle(isOn: $enableVideoMerger) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("إظهار أداة دمج الفيديوهات")
                                    .foregroundColor(.white)
                                Text("زر لجمع مقاطع الحساب في فيديو واحد طويل")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding()
                    }
                    .background(Color(white: 0.11))
                    .cornerRadius(16)
                }

                // قسم الحماية والخصوصية (FaceID)
                VStack(alignment: .leading, spacing: 10) {
                    Text("الأمان والخصوصية")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    VStack(spacing: 0) {
                        Toggle("قفل التطبيق ببصمة الوجه (FaceID)", isOn: $enableBiometricLock)
                            .foregroundColor(.white)
                            .padding()

                        if enableBiometricLock {
                            Divider().background(Color.gray.opacity(0.3))
                            Toggle("قفل تبويب المحفوظات فقط", isOn: $lockVaultOnly)
                                .foregroundColor(.white)
                                .padding()
                        }
                    }
                    .background(Color(white: 0.11))
                    .cornerRadius(16)
                }

                // قسم إعدادات المشغل والعرض العام
                VStack(alignment: .leading, spacing: 10) {
                    Text("إعدادات المشغل والعرض العامة")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    VStack(spacing: 0) {
                        Toggle("بدء تشغيل الفيديو بدون صوت (Mute)", isOn: $startVideosMuted)
                            .foregroundColor(.white)
                            .padding()

                        Divider().background(Color.gray.opacity(0.3))

                        Toggle("تفعيل الاهتزاز التفاعلي (Haptics)", isOn: $enableHaptics)
                            .foregroundColor(.white)
                            .padding()

                        Divider().background(Color.gray.opacity(0.3))

                        HStack {
                            Text("مدة عرض الصورة في وضع القصة")
                                .foregroundColor(.white)
                            Spacer()
                            Stepper("\(Int(imageStoryDuration)) ثواني", value: $imageStoryDuration, in: 2...15, step: 1)
                                .foregroundColor(.yellow)
                        }
                        .padding()

                        Divider().background(Color.gray.opacity(0.3))

                        HStack {
                            Text("الحد الأقصى للسنابات في كل فحص")
                                .foregroundColor(.white)
                            Spacer()
                            Picker("الحد", selection: $maxStoriesPerUser) {
                                Text("10").tag(10)
                                Text("20").tag(20)
                                Text("50").tag(50)
                                Text("100").tag(100)
                            }
                            .tint(.yellow)
                        }
                        .padding()
                    }
                    .background(Color(white: 0.11))
                    .cornerRadius(16)
                }

                // قسم إدارة المساحة والتنظيف التلقائي
                VStack(alignment: .leading, spacing: 10) {
                    Text("إدارة المساحة والتنظيف التلقائي")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    VStack(spacing: 0) {
                        HStack {
                            Text("المساحة المستهلكة حالياً")
                                .foregroundColor(.white)
                            Spacer()
                            Text(formattedTotalVaultSize())
                                .font(.headline)
                                .foregroundColor(.yellow)
                        }
                        .padding()

                        Divider().background(Color.gray.opacity(0.3))

                        Toggle("حذف المقاطع القديمة تلقائياً", isOn: $enableAutoCleanup)
                            .foregroundColor(.white)
                            .padding()

                        if enableAutoCleanup {
                            Divider().background(Color.gray.opacity(0.3))
                            HStack {
                                Text("حذف المقاطع الأقدم من")
                                    .foregroundColor(.white)
                                Spacer()
                                Picker("الأيام", selection: $cleanupDays) {
                                    Text("7 أيام").tag(7)
                                    Text("14 يوماً").tag(14)
                                    Text("30 يوماً").tag(30)
                                    Text("60 يوماً").tag(60)
                                }
                                .tint(.yellow)
                            }
                            .padding()
                        }

                        Divider().background(Color.gray.opacity(0.3))

                        Button(action: clearDeduplicationHistory) {
                            HStack {
                                Image(systemName: "arrow.counterclockwise")
                                Text("تصفير سجل منع التكرار (لإعادة تحميل الكل)")
                            }
                            .foregroundColor(.orange)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Divider().background(Color.gray.opacity(0.3))

                        Button(action: deleteAllMedia) {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text("حذف جميع الوسائط المحفوظة نهائياً")
                            }
                            .foregroundColor(.red)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(Color(white: 0.11))
                    .cornerRadius(16)
                }

                Spacer(minLength: 95)
            }
            .padding()
        }
    }

    // MARK: - شريط التبويبات السفلي (3 تبويبات)
    var customBottomBar: some View {
        HStack(spacing: 0) {
            Button(action: {
                triggerHaptic()
                selectedTab = 0
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                    Text("التحميل")
                        .font(.caption2.bold())
                }
                .foregroundColor(selectedTab == 0 ? .blue : .gray)
                .frame(maxWidth: .infinity)
            }

            Button(action: {
                triggerHaptic()
                loadSavedMedia()
                selectedTab = 1
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.title3)
                    Text("المحفوظات (\(savedItems.count))")
                        .font(.caption2.bold())
                }
                .foregroundColor(selectedTab == 1 ? .yellow : .gray)
                .frame(maxWidth: .infinity)
            }

            Button(action: {
                triggerHaptic()
                selectedTab = 2
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                    Text("الإعدادات")
                        .font(.caption2.bold())
                }
                .foregroundColor(selectedTab == 2 ? .green : .gray)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(white: 0.12))
        .clipShape(Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    var filteredSavedItems: [SavedMediaItem] {
        if selectedAccountFilter == "الكل" {
            return savedItems
        }
        return savedItems.filter { $0.username == selectedAccountFilter }
    }

    // MARK: - الدوال البرمجية للميزات المضافة

    func triggerHaptic() {
        guard enableHaptics else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    func authenticateUser() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "فتح قفل محفوظات SnapVault") { success, _ in
                DispatchQueue.main.async {
                    self.isUnlocked = success
                }
            }
        } else {
            isUnlocked = true
        }
    }

    func addAccount() {
        let trimmed = newUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        if !accounts.contains(where: { $0.username == trimmed }) {
            accounts.append(SnapAccount(username: trimmed))
            saveAccounts()
            triggerHaptic()
            addLog("تمت إضافة الحساب: \(trimmed)")
        }
        newUsername = ""
    }

    func deleteAccount(_ account: SnapAccount) {
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
    }

    func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: "snapvault_accounts")
        }
    }

    func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: "snapvault_accounts"),
           let decoded = try? JSONDecoder().decode([SnapAccount].self, from: data) {
            accounts = decoded
        }
    }

    func addLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        DispatchQueue.main.async {
            logs.insert("[\(timestamp)] \(text)", at: 0)
        }
    }

    func getVaultDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let vault = docs.appendingPathComponent("SnapVaultMedia", isDirectory: true)
        if !FileManager.default.fileExists(atPath: vault.path) {
            try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        }
        return vault
    }

    // توليد اسم الملف: username_YYYY-MM-DD_HH-mm-ss_index
    func generateFileName(for username: String, isVideo: Bool, index: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateStr = formatter.string(from: Date())
        let ext = isVideo ? "mp4" : "jpg"
        return "\(username)_\(dateStr)_\(index).\(ext)"
    }

    // إدارة سجل منع التكرار
    func isURLAlreadyDownloaded(_ urlString: String) -> Bool {
        let cleanKey = urlString.components(separatedBy: "?").first ?? urlString
        let history = UserDefaults.standard.stringArray(forKey: "snapvault_downloaded_urls") ?? []
        return history.contains(cleanKey)
    }

    func markURLAsDownloaded(_ urlString: String) {
        let cleanKey = urlString.components(separatedBy: "?").first ?? urlString
        var history = UserDefaults.standard.stringArray(forKey: "snapvault_downloaded_urls") ?? []
        if !history.contains(cleanKey) {
            history.append(cleanKey)
            UserDefaults.standard.set(history, forKey: "snapvault_downloaded_urls")
        }
    }

    func clearDeduplicationHistory() {
        UserDefaults.standard.removeObject(forKey: "snapvault_downloaded_urls")
        triggerHaptic()
        addLog("تم تصفير سجل منع التكرار بنجاح.")
    }

    func startSequentialDownload() {
        let selected = accounts.filter { $0.isSelected }
        guard !selected.isEmpty else { return }
        isDownloading = true
        triggerHaptic()
        addLog("بدء التحميل المتسلسل لـ \(selected.count) حساب...")

        Task {
            for account in selected {
                addLog("جاري فحص الحساب: @\(account.username)...")
                await fetchAndSavePublicStories(for: account.username)
            }
            await MainActor.run {
                isDownloading = false
                loadSavedMedia()
                addLog("اكتملت عملية التحميل لجميع الحسابات.")
            }
        }
    }

    func fetchAndSavePublicStories(for username: String) async {
        guard let profileURL = URL(string: "https://www.snapchat.com/add/\(username)") else { return }
        var request = URLRequest(url: profileURL)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return }

            let pattern = #"https://[^\s"<>]+?(?:sc-cdn\.net|snapchat\.com)[^\s"<>]+?"#
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let matches = regex.matches(in: html, options: [], range: NSRange(html.startIndex..., in: html))

            var mediaURLs: [String] = []
            for match in matches {
                if let range = Range(match.range, in: html) {
                    let urlStr = String(html[range])
                    if (urlStr.contains(".mp4") || urlStr.contains(".jpg") || urlStr.contains("story")) && !mediaURLs.contains(urlStr) {
                        mediaURLs.append(urlStr)
                    }
                }
            }

            if mediaURLs.isEmpty {
                addLog("لا توجد قصص عامة متاحة حالياً لـ @\(username)")
                return
            }

            var counter = 1
            for urlString in mediaURLs.prefix(maxStoriesPerUser) {
                if enableDeduplication && isURLAlreadyDownloaded(urlString) {
                    addLog("تخطي مقطع مكرر لـ @\(username)")
                    continue
                }

                guard let mediaURL = URL(string: urlString) else { continue }
                let (mediaData, response) = try await URLSession.shared.data(from: mediaURL)
                let mimeType = response.mimeType ?? ""
                let isVideo = mimeType.contains("video") || urlString.contains(".mp4")

                if mediaFilter == .videoOnly && !isVideo { continue }
                if mediaFilter == .imageOnly && isVideo { continue }

                let fileName = generateFileName(for: username, isVideo: isVideo, index: counter)
                let fileURL = getVaultDirectory().appendingPathComponent(fileName)

                try mediaData.write(to: fileURL)
                markURLAsDownloaded(urlString)
                addLog("تم حفظ: \(fileName)")
                counter += 1
            }
        } catch {
            addLog("خطأ أثناء جلب @\(username): \(error.localizedDescription)")
        }
    }

    // دالة دمج الفيديوهات في ملف واحد طويل
    func mergeFilteredVideos() {
        let videosToMerge = filteredSavedItems.filter { $0.isVideo }.sorted { $0.creationDate < $1.creationDate }
        guard videosToMerge.count >= 2 else { return }

        isMerging = true
        triggerHaptic()
        let targetUser = selectedAccountFilter == "الكل" ? "merged" : selectedAccountFilter

        Task {
            let composition = AVMutableComposition()
            guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                await MainActor.run { isMerging = false }
                return
            }

            var currentTime = CMTime.zero

            for item in videosToMerge {
                let asset = AVURLAsset(url: item.url)
                let duration = (try? await asset.load(.duration)) ?? .zero
                guard duration > .zero else { continue }

                if let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first {
                    try? compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: currentTime)
                    if let transform = try? await videoTrack.load(.preferredTransform) {
                        compVideoTrack.preferredTransform = transform
                    }
                }
                if let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first {
                    try? compAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: currentTime)
                }
                currentTime = CMTimeAdd(currentTime, duration)
            }

            let mergedFileName = generateFileName(for: "\(targetUser)-مدمج", isVideo: true, index: videosToMerge.count)
            let outputURL = getVaultDirectory().appendingPathComponent(mergedFileName)

            if let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) {
                exportSession.outputURL = outputURL
                exportSession.outputFileType = .mp4
                await exportSession.export()
            }

            await MainActor.run {
                isMerging = false
                loadSavedMedia()
                addLog("تم دمج \(videosToMerge.count) مقاطع في: \(mergedFileName)")
            }
        }
    }

    func loadSavedMedia() {
        let vault = getVaultDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: vault,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        var items: [SavedMediaItem] = []
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy/MM/dd hh:mm a"

        for fileURL in files {
            let filename = fileURL.lastPathComponent
            let isVideo = filename.lowercased().hasSuffix(".mp4") || filename.lowercased().hasSuffix(".mov")
            let parts = filename.components(separatedBy: "_")
            let username = parts.first ?? "غير معروف"
            let resourceValues = try? fileURL.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            let creationDate = resourceValues?.creationDate ?? Date()
            let fileSize = Int64(resourceValues?.fileSize ?? 0)
            let dateString = displayFormatter.string(from: creationDate)

            items.append(SavedMediaItem(
                url: fileURL,
                filename: filename,
                username: username,
                dateString: dateString,
                isVideo: isVideo,
                creationDate: creationDate,
                fileSize: fileSize
            ))
        }

        savedItems = items.sorted(by: { $0.creationDate > $1.creationDate })
    }

    func formattedTotalVaultSize() -> String {
        let totalBytes = savedItems.reduce(Int64(0)) { $0 + $1.fileSize }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytes)
    }

    func performAutoCleanup() {
        let vault = getVaultDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) else { return }
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -cleanupDays, to: Date()) ?? Date()

        for fileURL in files {
            if let creationDate = (try? fileURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
               creationDate < cutoffDate {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func deleteMediaItem(_ item: SavedMediaItem) {
        try? FileManager.default.removeItem(at: item.url)
        triggerHaptic()
        loadSavedMedia()
    }

    func deleteAllMedia() {
        let vault = getVaultDirectory()
        if let files = try? FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        triggerHaptic()
        loadSavedMedia()
    }
}

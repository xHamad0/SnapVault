- name: Generate Xcode Project via XcodeGen
      run: |
        cat << 'EOF' > project.yml
        name: SnapVault
        options:
          bundleIdPrefix: com.xhamad0
        targets:
          SnapVault:
            type: application
            platform: iOS
            deploymentTarget: "16.0"
            sources:
              - Sources
            info:
              path: Sources/Info.plist
              properties:
                CFBundleDisplayName: SnapVault
                UILaunchScreen: {}
                UISupportedInterfaceOrientations:
                  - UIInterfaceOrientationPortrait
                NSFaceIDUsageDescription: "لحماية المحفوظات ببصمة الوجه"
                NSPhotoLibraryAddUsageDescription: "لحفظ المقاطع المختارة في ألبوم الصور"
                UIBackgroundModes:
                  - audio
                  - fetch
                  - processing
            settings:
              PRODUCT_BUNDLE_IDENTIFIER: com.xhamad0.snapvault
              ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
              CODE_SIGN_IDENTITY: ""
              CODE_SIGNING_REQUIRED: NO
              CODE_SIGNING_ALLOWED: NO
        EOF
        brew install xcodegen
        xcodegen generate

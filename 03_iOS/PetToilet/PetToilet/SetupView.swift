import SwiftUI

/// App 對外的連結。
///
/// 隱私權政策連結是**必要的** —— 審核指南 5.1.1(i) 要求 App Store Connect 的欄位
/// 「以及 App 內」都必須有一個容易找到的連結，缺一不可。
///
/// ⚠️ 部署 GitHub Pages 後要把下面的網址換成實際位址，並確認：
///    - 公開可存取、不需登入
///    - 只要 App 還在架上就必須持續可用
enum AppLinks {
    static let privacyPolicy = URL(string: "https://agwillfu.github.io/PetToilet/privacy.html")!
    static let adafruitIO    = URL(string: "https://io.adafruit.com")!
}

/// Adafruit IO 帳號設定。
///
/// 憑證由使用者自己輸入而不是寫死在程式裡：寫死的話每個安裝這個 App 的人都會
/// 連到同一台裝置，而且 App Store 審查員也無法用自己的帳號測試。
struct SetupView: View {
    let current: Credentials
    let onSave: (Credentials) -> Void
    let onUseDemo: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("使用者名稱", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("AIO Key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Adafruit IO 帳號")
                } footer: {
                    Text("在 io.adafruit.com 登入後，進入任一個 Dashboard 頁面，"
                         + "點右上角黃色鑰匙圖示的「My Key」就能看到這兩個值。")
                }

                Section {
                    Button("儲存並連線") {
                        onSave(Credentials(username: username.trimmingCharacters(in: .whitespaces),
                                           key: key.trimmingCharacters(in: .whitespaces)))
                        dismiss()
                    }
                    .disabled(!Credentials(username: username, key: key).isComplete)

                    Button("改用 Demo 模式") {
                        onUseDemo()
                        dismiss()
                    }
                } footer: {
                    Text("Demo 模式使用內建的模擬裝置，不會連上任何伺服器，"
                         + "可以在沒有硬體的情況下體驗完整功能。")
                }

                Section {
                    Text("AIO Key 等同於帳號密碼 —— 持有它就能控制你的裝置，包含啟動水泵。"
                         + "本 App 將它存放在系統 Keychain，不會同步到 iCloud，也不會傳送到"
                         + "Adafruit IO 以外的任何伺服器。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("關於") {
                    Link(destination: AppLinks.privacyPolicy) {
                        Label("隱私權政策", systemImage: "hand.raised")
                    }
                    Link(destination: AppLinks.adafruitIO) {
                        Label("Adafruit IO 網站", systemImage: "globe")
                    }
                    LabeledContent("版本") {
                        Text(Bundle.main.appVersionDescription).monospacedDigit()
                    }
                }
            }
            .navigationTitle("連線設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onAppear {
            username = current.username
            key = current.key
        }
    }
}

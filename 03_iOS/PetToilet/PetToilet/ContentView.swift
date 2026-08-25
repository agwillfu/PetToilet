import SwiftUI

struct ContentView: View {
    @State private var controller = ToiletController()
    @State private var showDiagnostics = false
    @State private var showSetup = false
    @State private var showClearConfirm = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if controller.diagnostics.needsAppUpdate { updateBanner }
                statusSection
                controlSection
                settingsSection
                scheduleSection
                if showDiagnostics { diagnosticsSection }
                activitySection
            }
            .navigationTitle("白白的廁所")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSetup = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("連線設定")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { showDiagnostics.toggle() }
                    } label: {
                        Image(systemName: showDiagnostics ? "wrench.and.screwdriver.fill"
                                                          : "wrench.and.screwdriver")
                    }
                    .accessibilityLabel("診斷資訊")
                }
            }
            .refreshable {
                await controller.loadHistory()
            }
        }
        .sheet(isPresented: $showSetup) {
            SetupView(
                current: controller.credentials,
                onSave: { c in Task { await controller.saveCredentials(c) } },
                onUseDemo: { Task { await controller.start(mode: .demo) } })
        }
        .task {
            await controller.start(mode: controller.preferredMode)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await controller.resumeIfNeeded() }
        }
    }

    // MARK: - 版本提示

    /// 刻意只提示、不封鎖畫面。
    ///
    /// 就算格式對不上，手動沖水這類基本操作通常還是能用 —— 直接擋住整個 App
    /// 會讓家人在需要沖水的時候什麼都做不了，比顯示錯誤的數值更糟。
    private var updateBanner: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("App 需要更新")
                        .font(.subheadline.bold())
                    Text("裝置韌體使用較新的通訊格式（第 "
                         + "\(controller.diagnostics.protocolVersion) 版，本 App 支援到第 "
                         + "\(DeviceProtocol.supported) 版）。部分數值可能顯示不正確。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 狀態

    private var statusSection: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: controller.state.symbol)
                    .font(.system(size: 52))
                    .foregroundStyle(controller.state.tint)
                    .symbolEffect(.pulse, isActive: controller.state == .flushing)
                    .contentTransition(.symbolEffect(.replace))

                Text(controller.state.displayName)
                    .font(.title2.bold())

                if let last = controller.lastFlush {
                    // 顯示的是絕對時間依手機時區換算的結果，不是裝置端的牆上時間
                    Text("上次沖水 \(last.date.shortDateTime24)"
                         + (last.flushReason.map { "（\($0)）" } ?? ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                connectionBadge
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.connection.isConnected ? .green : .orange)
                .frame(width: 7, height: 7)
            Text(controller.connection.displayName)
            if controller.mode == .demo {
                Text("· \(controller.mode.displayName)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - 控制

    private var controlSection: some View {
        Section {
            Button {
                controller.flushNow()
            } label: {
                Label("立即沖水", systemImage: "drop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.state.acceptsManualFlush || !controller.connection.isConnected)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } footer: {
            if !controller.state.acceptsManualFlush && controller.connection.isConnected {
                Text("只有在「等待中」狀態才能手動沖水，避免打斷正在進行的流程。")
            }
        }
    }

    // MARK: - 設定

    private var settingsSection: some View {
        Section("參數") {
            secondsSlider(
                title: "站上判斷",
                help: "持續偵測到震動多久，才認定狗狗真的站上去了",
                value: controller.settings.entryThreshold,
                range: SettingRange.entry,
                onChange: controller.previewEntryThreshold,
                onCommit: controller.commitEntryThreshold)

            secondsSlider(
                title: "離開判斷",
                help: "沒有震動多久，才認定狗狗已經離開",
                value: controller.settings.exitThreshold,
                range: SettingRange.exit,
                onChange: controller.previewExitThreshold,
                onCommit: controller.commitExitThreshold)

            secondsSlider(
                title: "沖水時間",
                help: "狗狗用完後，水泵運轉的持續時間",
                value: controller.settings.flushDuration,
                range: SettingRange.duration,
                step: 5,
                onChange: controller.previewFlushDuration,
                onCommit: controller.commitFlushDuration)
        }
        .disabled(!controller.connection.isConnected)
    }

    /// 秒數的顯示格式。超過一分鐘時「90 秒」不如「1 分 30 秒」好讀。
    static func formatSeconds(_ s: Int) -> String {
        guard s >= 60 else { return "\(s) 秒" }
        let m = s / 60, r = s % 60
        return r == 0 ? "\(m) 分鐘" : "\(m) 分 \(r) 秒"
    }

    private func secondsSlider(
        title: String,
        help: String,
        value: Int,
        range: ClosedRange<Int>,
        step: Double = 1,
        onChange: @escaping (Int) -> Void,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(Self.formatSeconds(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Int(($0 / step).rounded() * step)) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: step,
                onEditingChanged: { editing in
                    // 只在放開滑桿時送出，拖曳過程不發指令
                    if !editing { onCommit() }
                })
            Text(help)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 定時清洗

    private var scheduleSection: some View {
        Section {
            Toggle("啟用定時清洗", isOn: Binding(
                get: { controller.schedule.enabled },
                set: { controller.setScheduleEnabled($0) }))

            if controller.schedule.enabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("每次清洗時間")
                        Spacer()
                        Text(controller.schedule.durationDescription)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    let lo = Double(FlushSchedule.durationRange.lowerBound)
                    let hi = Double(FlushSchedule.durationRange.upperBound)
                    Slider(
                        value: Binding(
                            get: { Double(controller.schedule.durationSeconds) },
                            set: { controller.setScheduleDuration(Int($0.rounded() / 10) * 10) }),
                        in: lo...hi,
                        step: 10,
                        onEditingChanged: { editing in
                            if !editing { controller.pushSchedule() }
                        })
                    Text("與上方「沖水時間」是分開的設定，改這裡不會影響狗狗用完後的自動沖水。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)

                ForEach(controller.schedule.times) { time in
                    DatePicker(
                        "清洗時間",
                        selection: Binding(
                            get: { time.asDate },
                            set: { newDate in
                                let (h, m) = ScheduledTime.from(date: newDate)
                                controller.updateScheduleTime(id: time.id, hour: h, minute: m)
                                controller.pushScheduleDebounced()
                            }),
                        displayedComponents: .hourAndMinute)
                    // DatePicker 的時間格式跟著環境的 locale 走，覆寫成強制 24 小時制
                    .environment(\.locale, .hour24)
                }
                .onDelete { controller.removeScheduleTimes(at: $0) }

                if controller.schedule.times.count < FlushSchedule.maxEntries {
                    Button {
                        controller.addScheduleTime()
                    } label: {
                        Label("新增時間", systemImage: "plus.circle")
                    }
                }
            }
        } header: {
            Text("定時清洗")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.schedule.summary)
                if controller.schedule.enabled {
                    Text("排程由裝置本身執行，手機關機或不在身邊也會照常清洗。清洗時間到但白白正在使用時會自動延後，最多等 20 分鐘。")
                }
            }
        }
        .disabled(!controller.connection.isConnected)
    }

    // MARK: - 診斷

    private var diagnosticsSection: some View {
        Section("裝置診斷") {
            let d = controller.diagnostics
            row("韌體版本", d.firmwareVersion)
            row("通訊協定", "第 \(d.protocolVersion) 版"
                + (d.protocolVersion == DeviceProtocol.supported
                   ? "" : "（App 支援第 \(DeviceProtocol.supported) 版）"))
            row("IP 位址", d.ipAddress)
            row("WiFi 訊號", d.signalDescription)
            row("運行時間", d.uptimeDescription)
            row("可用記憶體", d.freeHeap.map { "\($0) bytes" })
            row("最大連續區塊", d.maxFreeBlock.map { "\($0) bytes" })
            row("記憶體碎片化", d.fragmentation.map { "\($0)%" })
            row("TLS MFLN", d.mflnActive.map { $0 ? "已啟用" : "未啟用" })

            Button(role: .destructive) {
                controller.triggerOTA()
            } label: {
                Label("進入韌體更新模式", systemImage: "arrow.down.circle")
            }

            if !controller.notices.isEmpty {
                DisclosureGroup("最近訊息") {
                    ForEach(Array(controller.notices.enumerated()), id: \.offset) { _, m in
                        Text(m)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label) {
                Text(value).monospacedDigit()
            }
        }
    }

    // MARK: - 紀錄

    private var activitySection: some View {
        Section {
            if controller.activity.entries.isEmpty {
                Text(controller.isLoadingHistory ? "載入中…" : "尚無紀錄")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.activity.entries.prefix(200)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        // 一律 24 小時制（見 Locale.hour24），並依手機時區換算
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(entry.date.shortDate)
                            Text(entry.date.time24)
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 44, alignment: .trailing)

                        Text(entry.message)
                            .font(.callout)
                    }
                }

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清除紀錄", systemImage: "trash")
                }
            }
        } header: {
            HStack {
                Text("活動紀錄")
                if controller.isLoadingHistory {
                    ProgressView().controlSize(.mini)
                }
            }
        } footer: {
            Text("保留最近兩週。裝置的完整紀錄存在 Adafruit IO，"
                 + "App 開啟時會自動同步，下拉可手動更新。")
        }
        .confirmationDialog("清除活動紀錄？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清除", role: .destructive) { controller.clearActivity() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會清除這支手機上顯示的紀錄，裝置在 Adafruit IO 上的原始資料不受影響。")
        }
    }
}

#Preview {
    ContentView()
}

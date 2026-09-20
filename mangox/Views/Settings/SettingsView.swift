//
//  SettingsView.swift
//  P4.0.4 最小设置页 (主区切换视图): 并发回合上限。
//  通知开关随 P4.1 加入; 版式统一为 macOS 系统设置范式 (左标题+说明 / 右控件)。
//  P7-M3: 模型区改版 — 自管模型 (预设库 + 测试连接 + 勾选), 真源 models 表物化给 pi。
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject private var notifier = CompletionNotifier.shared

    // P7-M3 添加表单状态
    @State private var selectedPresetId: String?      // nil = 自定义
    @State private var customProvider = ""
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var apiType = "openai-completions"
    @State private var candidates: [CandidateModel] = []
    @State private var checked: Set<String> = []
    @State private var verified = false
    @State private var testState: TestState = .idle
    @State private var formError: String?
    @State private var showMorePresets = false
    @State private var recording = false          // P8-T27: 热键录制中
    @State private var keyMonitor: Any?           // P8-T27: 录制用 keyDown 监听

    enum TestState: Equatable { case idle, testing, done }

    /// 勾选行条目 (seed 元数据 或 /models 拉回的 id + 保守默认)。
    struct CandidateModel: Identifiable, Hashable {
        let id: String
        var name: String
        var reasoning: Bool
        var input: [String]
        var contextWindow: Int
        var maxTokens: Int
        var cost: ModelCost?
        var thinkingLevelMap: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(CodexTheme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modelSection
                    concurrencySection
                    notificationSection
                    captureSection
                    MailboxAccountsSection(store: store)
                    backupSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(CodexTheme.bgChat)
        .onDisappear {
            // P9-#4: 录制 monitor 必须随视图销毁清理 — 否则录制中切走后 monitor 永久存活,
            // 吞掉全 App 修饰键且再次录制因 guard no-op 假死
            stopHotkeyRecording()
        }
        .alert("备份失败",   // P9-#11: 后台备份失败细节弹窗 (主线程不再被拷贝阻塞)
               isPresented: Binding(get: { store.backupFailureMessage != nil },
                                    set: { if !$0 { store.backupFailureMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.backupFailureMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("SETTINGS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(CodexTheme.textMuted)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - 统一行范式: 左标题+说明, 右控件

    private func settingRow<Control: View>(title: String, detail: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }

    // MARK: - 模型 (P7-M3 自管真源)

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("模型")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                Text("模型由 MangoX 自管, spawn 时物化到 ~/.mangox/pi-config 供 pi 消费 (不碰 ~/.pi/agent)")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.managedModels.isEmpty {
                Divider().overlay(CodexTheme.divider)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.managedModels) { m in
                        managedRow(m)
                    }
                }
            }

            Divider().overlay(CodexTheme.divider)
            addModelForm
        }
        .settingsCard()
    }

    /// 预设芯片行: 主推 4 家 + "其他"展开余下 + 自定义 (预设数据仍是全量 8 家)。
    private var presetChips: some View {
        let primary = ["deepseek", "minimax", "zhipu", "kimi"]
        let others = ProviderPresets.all.filter { !primary.contains($0.id) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ProviderPresets.all.filter { primary.contains($0.id) }) { p in
                    chip(p.displayName, selected: selectedPresetId == p.id) {
                        loadPreset(p)
                    }
                }
                chip("其他…", selected: showMorePresets || others.contains { $0.id == selectedPresetId }) {
                    showMorePresets.toggle()
                }
                if showMorePresets {
                    ForEach(others) { p in
                        chip(p.displayName, selected: selectedPresetId == p.id) {
                            loadPreset(p)
                        }
                    }
                }
                chip("自定义…", selected: selectedPresetId == nil && !baseURL.isEmpty) {
                    selectedPresetId = nil
                    baseURL = ""; apiType = "openai-completions"
                    candidates = []; checked = []; verified = false
                    testState = .idle; formError = nil
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? CodexTheme.accent : CodexTheme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(selected ? CodexTheme.accent.opacity(0.1) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(selected ? CodexTheme.accent : CodexTheme.border, lineWidth: 1)
                )
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    /// 添加面板: 选预设 → 填 key → 测试连接 → 勾选 → 保存。
    private var addModelForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            presetChips

            if selectedPresetId == nil {
                TextField("provider (自定义)", text: $customProvider)
                    .textFieldStyle(.roundedBorder)
                    .font(CodexTheme.fontSmall)
            }

            HStack(spacing: 8) {
                if needsKey {
                    SecureField("API Key (存入 Keychain)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(CodexTheme.fontSmall)
                }
                TextField("Base URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(CodexTheme.fontSmall)
                    .frame(minWidth: 200)
                Menu {
                    ForEach(["openai-completions", "openai-responses",
                             "anthropic-messages", "google-generative-ai"], id: \.self) { t in
                        Button(t) { apiType = t }
                    }
                } label: {
                    Text(apiType)
                        .font(CodexTheme.fontMonoXs)
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(spacing: 8) {
                Button(testState == .testing ? "测试中…" : "测试连接") { testConnection() }
                    .fixedSize()
                    .disabled(testState == .testing || baseURL.isEmpty)
                Button("保存并启用") { saveModels() }
                    .fixedSize()
                    .disabled(!canSave)
                Text(formHint)
                    .font(.system(size: 11))
                    .foregroundStyle(formError != nil ? CodexTheme.toolError
                                     : verified ? CodexTheme.toolDone : CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !candidates.isEmpty {
                candidateList
            }
        }
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(candidates) { c in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { checked.contains(c.id) },
                        set: { on in
                            if on { checked.insert(c.id) } else { checked.remove(c.id) }
                        }
                    )) { Text("") }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).font(.system(size: 12)).foregroundStyle(CodexTheme.textPrimary)
                        Text(c.id).font(CodexTheme.fontMonoXs).foregroundStyle(CodexTheme.textMuted)
                    }
                    Spacer()
                    if c.input.contains("image") {
                        Text("image").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CodexTheme.toolRunning)
                    }
                    if c.reasoning {
                        Text("think").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CodexTheme.toolDone)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxHeight: 180, alignment: .top)
    }

    /// 自管条目行: 名称 + 来源徽章 + provider/id + key 点 + 启停/选中/删除。
    private func managedRow(_ m: ManagedModel) -> some View {
        let isCurrent = store.currentProvider == m.provider && store.currentModelId == m.modelId
        let hasKey = m.keyRef == nil || store.providerKey(provider: m.keyRef!) != nil
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { m.enabled },
                set: { store.setManagedModelEnabled(m.id, $0) }
            )) { Text("") }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.displayNameOrId).font(.system(size: 13)).foregroundStyle(CodexTheme.textPrimary)
                    Text(sourceBadge(m.source))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CodexTheme.textMuted)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(CodexTheme.bgSidebar)
                        .cornerRadius(3)
                    if m.keyRef != nil {
                        Circle()
                            .fill(hasKey ? CodexTheme.toolDone : CodexTheme.toolError)
                            .frame(width: 6, height: 6)
                            .help(hasKey ? "Key 已存" : "Key 缺失 (物化后不可用)")
                    }
                }
                Text("\(m.provider) / \(m.modelId)")
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer()
            Button {
                store.selectManagedModel(m)
            } label: {
                Text(isCurrent ? "当前" : "启用")
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? CodexTheme.toolDone : CodexTheme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(isCurrent ? CodexTheme.toolDone.opacity(0.12) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isCurrent ? Color.clear : CodexTheme.border, lineWidth: 1)
                    )
                    .cornerRadius(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCurrent)

            Button {
                store.deleteManagedModel(m)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.vertical, 6)
    }

    private func sourceBadge(_ s: ManagedModelSource) -> String {
        switch s {
        case .preset: "预设"
        case .custom: "自定义"
        case .legacy: "迁移"
        }
    }

    private var selectedPreset: ProviderPreset? {
        selectedPresetId.flatMap { ProviderPresets.preset(id: $0) }
    }

    private var needsKey: Bool { selectedPreset?.needsKey ?? true }

    private var canSave: Bool {
        if selectedPresetId == nil {
            return !customProvider.trimmingCharacters(in: .whitespaces).isEmpty && !checked.isEmpty
        }
        return !checked.isEmpty
    }

    private var formHint: String {
        if let formError { return formError }
        if testState == .done && !verified { return "未验证 — 拉取失败, 使用预设清单兜底" }
        if verified { return "✓ 连通, 勾选后保存" }
        if selectedPresetId == nil { return "自定义 provider: 填 Base URL, 可选测试" }
        return "选择预设, 填 Key 后测试连接"
    }

    private func loadPreset(_ p: ProviderPreset) {
        selectedPresetId = p.id
        baseURL = p.baseURL
        apiType = p.apiType
        apiKey = ""
        candidates = mergeCatalog(provider: p.id, seeds: p.seedModels)
        checked = Set(p.seedModels.map(\.id))
        verified = false
        testState = .idle
        formError = nil
        Task { @MainActor in
            // 目录新鲜度后台巡检 (静默); 完成后如果还在当前预设, 重新展开补全
            if await ModelCatalogStore.shared.refreshIfStale(), selectedPresetId == p.id {
                candidates = mergeCatalog(provider: p.id, seeds: p.seedModels)
                checked.formUnion(p.seedModels.map(\.id))
            }
        }
    }

    /// seed 全保留, 目录中 seed 之外的模型追加展开 (seed 元数据优先, 不漂移)。
    private func mergeCatalog(provider: String, seeds: [ProviderPreset.SeedModel]) -> [CandidateModel] {
        var list = seeds.map { s in
            CandidateModel(id: s.id, name: s.name, reasoning: s.reasoning,
                           input: s.input, contextWindow: s.contextWindow,
                           maxTokens: s.maxTokens, cost: s.cost,
                           thinkingLevelMap: s.thinkingLevelMap)
        }
        let seedIds = Set(seeds.map(\.id))
        for (id, e) in ModelCatalogStore.shared.entries(provider: provider).sorted(by: { $0.key < $1.key })
        where !seedIds.contains(id) {
            list.append(CandidateModel(id: id, name: e.name.isEmpty ? id : e.name,
                                       reasoning: e.reasoning, input: e.input,
                                       contextWindow: e.contextWindow ?? 128_000,
                                       maxTokens: e.maxTokens ?? 16_384,
                                       cost: e.cost, thinkingLevelMap: nil))
        }
        return list
    }

    private func testConnection() {
        testState = .testing
        formError = nil
        Task { @MainActor in
            let result = await ModelCatalogFetcher.fetch(
                baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                apiKey: apiKey.isEmpty ? nil : apiKey,
                apiType: apiType,
                ollamaStyle: selectedPreset?.ollamaStyle ?? false)
            testState = .done
            if result.verified {
                verified = true
                let provider = selectedPresetId ?? customProvider.trimmingCharacters(in: .whitespaces)
                let seeds = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
                candidates = result.modelIds.map { id in
                    // 元数据优先级: seed (不漂移) > models.dev 目录 > 裸默认
                    if let seed = seeds[id] { return seed }
                    if let e = ModelCatalogStore.shared.entry(provider: provider, modelId: id) {
                        return CandidateModel(id: id, name: e.name.isEmpty ? id : e.name,
                                              reasoning: e.reasoning, input: e.input,
                                              contextWindow: e.contextWindow ?? 128_000,
                                              maxTokens: e.maxTokens ?? 16_384,
                                              cost: e.cost, thinkingLevelMap: nil)
                    }
                    return CandidateModel(id: id, name: id, reasoning: false,
                                          input: ["text"], contextWindow: 128_000,
                                          maxTokens: 16_384, cost: nil, thinkingLevelMap: nil)
                }
                checked = Set(result.modelIds.filter { seeds[$0] != nil })   // 种子预勾, 其余不勾
            } else {
                verified = false
                formError = "拉取失败 (\(result.error ?? "未知")), 已回落预设清单"
            }
        }
    }

    private func saveModels() {
        let provider = selectedPresetId ?? customProvider.trimmingCharacters(in: .whitespaces)
        guard !provider.isEmpty, !checked.isEmpty else { return }
        let source: ManagedModelSource = selectedPresetId != nil ? .preset : .custom
        if needsKey && !apiKey.isEmpty {
            store.setProviderKey(apiKey, provider: provider)
        }
        if needsKey && apiKey.isEmpty && store.providerKey(provider: provider) == nil {
            formError = "该预设需要 API Key"
            return
        }
        let keyRef: String? = (selectedPreset?.needsKey ?? true) ? provider : nil
        let now = Date()
        for (i, id) in checked.sorted().enumerated() {
            guard let c = candidates.first(where: { $0.id == id }) else { continue }
            store.upsertManagedModel(ManagedModel(
                provider: provider, modelId: c.id, displayName: c.name,
                apiType: apiType, reasoning: c.reasoning,
                baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                keyRef: keyRef, contextWindow: c.contextWindow, maxTokens: c.maxTokens,
                inputModalities: c.input, cost: c.cost,
                thinkingLevelMapJSON: c.thinkingLevelMap,
                enabled: true, source: source,
                createdAt: now.addingTimeInterval(Double(-i))))
        }
        apiKey = ""
        checked = []
        candidates = []
        verified = false
        testState = .idle
        formError = nil
    }

    // MARK: - 并发上限

    private var concurrencySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "并发回合上限",
                       detail: "每个在途任务是一个独立 pi 进程 (约 50MB), 请按机器负载设置") {
                Stepper(value: Binding(
                    get: { store.maxConcurrentTurns },
                    set: { store.maxConcurrentTurns = $0 }
                ), in: 1...20) {
                    HStack(spacing: 6) {
                        Text("\(store.maxConcurrentTurns)")
                            .font(CodexFonts.monoFont(14, weight: .semibold))
                            .foregroundStyle(CodexTheme.accent)
                            .frame(width: 24)
                        Text("个任务")
                            .font(.system(size: 12))
                            .foregroundStyle(CodexTheme.textSecondary)
                    }
                }
                .fixedSize()
            }
            Divider().overlay(CodexTheme.divider)
            Text("超过上限时: 会话发送被拒绝并提示; 定时任务到点会跳过并在日志会话记录原因。")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsCard()
    }

    // MARK: - 回合完成通知 (P4.1)

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "回合完成通知",
                       detail: "App 在后台时, 回合结束弹出系统通知; 前台使用时不弹, 点击通知跳回对应会话") {
                Toggle(isOn: Binding(
                    get: { store.completionNotificationsEnabled },
                    set: { on in
                        store.completionNotificationsEnabled = on
                        if on {
                            Task { await CompletionNotifier.shared.ensureAuthorization() }
                        }
                    }
                )) {
                    Text("回合完成通知")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
            }
            statusHint
        }
        .settingsCard()
    }

    @ViewBuilder
    private var statusHint: some View {
        let hint: String? = {
            switch notifier.authorizationStatus {
            case .denied:
                return "⚠️ 系统通知未授权 —— 请到 系统设置 → 通知 → MangoX 开启"
            case .notDetermined:
                return "尚未请求通知授权, 打开开关后首次完成时会请求"
            default:
                return nil
            }
        }()
        if let hint {
            Divider().overlay(CodexTheme.divider)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
        }
    }

    // MARK: - P8-T27 快速捕获热键

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "快速捕获热键",
                       detail: "全局唤起捕获输入条: 输入后回车即以无人值守模式开跑 (关审批 + Minimal 档); Esc 或点击外部关闭") {
                HStack(spacing: 8) {
                    if recording {
                        Text("按下新组合键…")
                            .font(.system(size: 12))
                            .foregroundStyle(CodexTheme.accent)
                    } else {
                        Button(store.captureHotkey.display) { startHotkeyRecording() }
                            .font(CodexFonts.monoFont(12, weight: .medium))
                            .fixedSize()
                    }
                    if recording {
                        Button("取消") { stopHotkeyRecording() }
                            .fixedSize()
                    }
                }
            }
            if store.captureHotkey != QuickCaptureController.shared.registeredHotkey {
                Divider().overlay(CodexTheme.divider)
                Text("⚠️ 当前热键被其他 App 占用 (注册失败), 请换一个组合键")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.toolError)
            }
        }
        .settingsCard()
    }

    /// 录制: App 内 keyDown 监听 (设置页打开时 App 必在前台, 不需全局监听)。
    /// 无修饰键的按键忽略 (防误吞普通输入); 录到即存 KV + 重注册 + 退出录制态。
    private func startHotkeyRecording() {
        guard keyMonitor == nil else { return }
        recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            var m: UInt32 = 0
            let f = ev.modifierFlags
            if f.contains(.command) { m |= CaptureHotkey.command }
            if f.contains(.shift)   { m |= CaptureHotkey.shift }
            if f.contains(.option)  { m |= CaptureHotkey.option }
            if f.contains(.control) { m |= CaptureHotkey.control }
            let hk = CaptureHotkey(keyCode: UInt32(ev.keyCode), modifiers: m)
            guard hk.hasModifier else { return ev }   // 忽略无修饰键按键 (继续录制)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.store.setCaptureHotkey(hk)
                    QuickCaptureController.shared.register(hk)
                    self.stopHotkeyRecording()
                }
            }
            return nil   // 吞键
        }
    }

    private func stopHotkeyRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = false
    }

    // MARK: - P8-T28 手动备份

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "手动备份",
                       detail: "把会话数据库 (含知识库) 与图片附件、会话记录完整拷贝到目标目录的 mangox-backup-<时间戳>/ 子目录, 供人工保管") {
                HStack(spacing: 8) {
                    Button(store.backupRunning ? "备份中…" : "立即备份") { runBackup() }
                        .fixedSize()
                        .disabled(store.backupRunning || store.backupDirectory == nil)
                    Button("选择目录…") { pickBackupDir() }
                        .fixedSize()
                }
            }
            Divider().overlay(CodexTheme.divider)
            HStack {
                Text(store.backupDirectory ?? "未选择备份目录")
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(store.lastBackupSummary ?? "尚未备份")
                    .font(.system(size: 11))
                    .foregroundStyle(store.lastBackupSummary?.hasPrefix("✓") == true
                                     ? CodexTheme.toolDone : CodexTheme.toolError)
            }
        }
        .settingsCard()
    }

    private func pickBackupDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            store.setBackupDirectory(url.path)
        }
    }

    private func runBackup() {
        guard let root = store.backupDirectory else { return }
        // P9-#11: 后台执行 (原同步版大附件库会冻结 UI); 失败经 backupFailureMessage 弹窗
        store.performManualBackupInBackground(destRoot: root)
    }
}

// MARK: - 设置卡片容器 (等宽 + 统一边框/圆角)

extension View {
    func settingsCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CodexTheme.bgElevated)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(CodexTheme.divider, lineWidth: 1)
            )
    }
}

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
    @ObservedObject private var appearance = AppearanceModel.shared   // P10.7: 主题外观三态
    @ObservedObject private var language = LanguageModel.shared        // P10.7: 语言三态

    /// 左侧当前选中的分类。**不落库**：下次开设置从「通用」开始 —— 一个设置页记住用户
    /// 上次翻到哪一栏，收益远小于"新开窗时的那一屏是乱的"这个代价。
    @State private var category: SettingsCategory = .general

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
    @State private var missingMetaNote: String?    // P13: 硬准入挡掉的模型 (点名提示)
    @State private var catalogBusy = false         // P13: 手动更新 models.dev 目录中
    @State private var catalogNote: String?        // P13: 目录更新结果 (一行)
    @State private var lastFetchedIds: [String] = []  // P13: /models 最后拉回的 id 全集
    @State private var recording = false          // P8-T27: 热键录制中
    @State private var keyMonitor: Any?           // P8-T27: 录制用 keyDown 监听

    // P10.1b 联网搜索 (博查)
    @State private var bochaKeyInput = ""

    // P18 computer use: 开关与作用域 (单例 —— 与 `AppearanceModel.shared` 同款,
    // spawn 那一侧读的是同一份, 所以改完下一轮就生效, 不需要再往 ChatStore 上补一次)
    @ObservedObject private var computer = ComputerSettings.shared
    /// 应用列表的搜索词（已安装的 App 有几百个，没有搜索翻不动）。
    @State private var computerQuery = ""

    enum TestState: Equatable { case idle, testing, done }

    /// 勾选行条目 (seed 元数据 或 /models 拉回的 id + 保守默认 / 目录元数据)。
    struct CandidateModel: Identifiable, Hashable {
        let id: String
        var name: String
        var reasoning: Bool
        var input: [String]
        var contextWindow: Int
        var maxTokens: Int
        var cost: ModelCost?
        var thinkingLevelMap: String?
        /// true = 不在 vendor 的 `/models` 清单里 (订阅制 / 隐藏模型, 只靠种子存在)。
        /// ⚠️ 只有在点过「测试连接」之后才判定得出来 ⇒ 未拉取时恒 false (不猜)。
        var vendorUnlisted: Bool = false
    }

    var body: some View {
        // 左列分类 + 右栏内容（2026-10-26）。原来是一整列 9 段卡片竖着堆,
        // 想改「备份」得先滚过 8 段別的东西 —— 版式没有骨架, boss 的原话是「排版太混乱」。
        // 分组口径按**用户要干什么**分, 不按代码里 section 的先后:
        //   通用 = 长啥样 + 一次任务怎么跑（外观 / 语言 / 锁屏运行 / 并发 / 通知 / 捕获热键）
        //   模型 = 唯一一件会影响每次请求的东西
        //   集成 = 需要第三方账号/Key 才能用的（联网搜索 / 邮箱）
        //   数据 = 落到磁盘、会被拷走的东西（备份）
        // ⚠️ 2026-10-27 把「运行」并进了「通用」(boss: "不然看上去太空旷了") ——
        //    两类各自只有 2~3 段, 单独立一页右栏大半是空白。
        SettingsShell(selection: $category) {
            VStack(alignment: .leading, spacing: 16) {
                switch category {
                case .general:
                    appearanceSection
                    languageSection
                    lockScreenSection
                    concurrencySection
                    notificationSection
                    captureSection
                case .model:
                    modelSection
                case .integration:
                    webSearchSection
                    MailboxAccountsSection(store: store)
                    computerSection
                case .data:
                    backupSection
                }
            }
        }
        .onAppear { consumePendingCategory() }
        // 窗口是**复用**的 (`isReleasedWhenClosed = false`) ⇒ 第二次从入口点进来时视图不会
        // 重建、`onAppear` 也不再触发; 那一次要靠 `onChange` 接住。
        .onChange(of: store.pendingSettingsCategory) { _, _ in consumePendingCategory() }
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

    /// 取走"请切到某一栏"的请求（输入框那行的 computer pill 会放进来）。
    ///
    /// ⚠️ 清空必须**延到下一轮 runloop**: 正在视图更新里改 `@Published` 会报
    ///    "Publishing changes from within view updates", 而且那个警告只在控制台里, 界面上
    ///    什么都看不出来 —— 典型的"零信号"问题。
    private func consumePendingCategory() {
        guard let raw = store.pendingSettingsCategory,
              let target = SettingsCategory(rawValue: raw) else { return }
        category = target
        DispatchQueue.main.async { store.pendingSettingsCategory = nil }
    }

    // MARK: - 统一行范式: 左标题+说明, 右控件

    private func settingRow<Control: View>(title: LocalizedStringKey, detail: LocalizedStringKey,
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

    // MARK: - 外观 (P10.7: 原侧栏品牌行的 dark/light 按钮移到这里, 并升为三态)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "外观",
                       detail: "跟随系统 = 由 macOS 的浅色/深色设置决定; 切换立即生效, 影响全 App (含迷你台)") {
                Picker("", selection: Binding(
                    get: { appearance.current },
                    set: { appearance.current = $0 }
                )) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .settingsCard()
    }

    // MARK: - 语言 (P10.7: 中文串即 key, 表内缺项自动回落中文原文)

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "语言 (Language)",
                       detail: "跟随系统 = 由 macOS 的语言设置决定; 切换立即生效, 影响全 App (含迷你台与快速捕获)。系统级文案 (菜单栏 / 系统弹窗) 仍随系统语言, 重启后完全一致。") {
                Picker("", selection: Binding(
                    get: { language.current },
                    set: { language.current = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .settingsCard()
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

    /// 预设芯片行: 主推列表平铺 + "其他"展开余下 + 自定义。
    /// P13 起预设库只有 4 家且全部在主推里 ⇒ 「其他…」不再出现在界面上, 但**机制保留**:
    /// 以后往 ProviderPresets.all 加一条, 它会自动落到「其他…」, 不挤占主推位置。
    private var presetChips: some View {
        let primary = ["deepseek", "kimi", "minimax", "zhipu"]
        let others = ProviderPresets.all.filter { !primary.contains($0.id) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ProviderPresets.all.filter { primary.contains($0.id) }) { p in
                    chip(LK(p.displayName), selected: selectedPresetId == p.id) {
                        loadPreset(p)
                    }
                }
                if !others.isEmpty {
                    chip("其他…", selected: showMorePresets || others.contains { $0.id == selectedPresetId }) {
                        showMorePresets.toggle()
                    }
                    if showMorePresets {
                        ForEach(others) { p in
                            chip(LK(p.displayName), selected: selectedPresetId == p.id) {
                                loadPreset(p)
                            }
                        }
                    }
                }
                chip("自定义…", selected: selectedPresetId == nil && !baseURL.isEmpty) {
                    selectedPresetId = nil
                    baseURL = ""; apiType = "openai-completions"
                    candidates = []; checked = []; verified = false
                    testState = .idle; formError = nil
                    lastFetchedIds = []
                }
            }
        }
    }

    private func chip(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
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

            // 模型目录 (models.dev) 与 /models 各管一半: 前者管「这个模型是什么」(窗口/价格/模态),
            // 后者管「现在有哪些模型」。目录 7 天自动刷新一次, 这里给一条手动强制刷新的路。
            HStack(spacing: 8) {
                Button(LK(catalogBusy ? "刷新中…" : "更新模型目录")) { refreshCatalog() }
                    .fixedSize()
                    .disabled(catalogBusy)
                Text(catalogStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(catalogNote != nil ? CodexTheme.toolDone : CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }

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
                TextField("接口地址", text: $baseURL)
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
                Button(LK(testState == .testing ? "测试中…" : "测试连接")) { testConnection() }
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

            // P13 硬准入: 官方 /models 报了 id 但既无种子也无目录元数据的, 不进候选 —— 这里如实报数,
            // 否则用户只看到"少了几个模型", 无从判断是拉取失败还是被挡。
            if let missingMetaNote {
                Text(missingMetaNote)
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 候选清单。
    /// ⚠️ 外层 ScrollView 不只是为了能滚 —— `frame(maxHeight:)` **不裁剪**, 少了它, 超出 180pt 的行
    /// 会直接画到框外、压住下面的提示 (GLM 组 18 条必然触发; 只有框下有元素时才看得见)。
    private var candidateList: some View {
        ScrollView {
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
                        // ⚠️ 纯字符串 key, 别加 title:/非字符串参数 —— 本地化不透明 (深坑)。
                        if c.vendorUnlisted {
                            Text("本地").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(CodexTheme.textSecondary)
                        }
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
        }
        .frame(maxHeight: 180)
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
                            .help(LK(hasKey ? "Key 已存" : "Key 缺失 (物化后不可用)"))
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
                Text(LK(isCurrent ? "当前" : "启用"))
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
        case .preset: L("预设")
        case .custom: L("自定义")
        case .legacy: L("迁移")
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
        if testState == .done && !verified { return L("未验证 — 拉取失败, 使用预设清单兜底") }
        if verified { return L("✓ 连通, 勾选后保存") }
        if selectedPresetId == nil { return L("自定义 provider: 填 Base URL, 可选测试") }
        return L("选择预设, 填 Key 后测试连接")
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
        missingMetaNote = nil
        lastFetchedIds = []
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
        // ⚠️ 按发布日期倒序 (不是 id 字母序) —— 18 条的 GLM 组里最新那条曾被字母序压到最底,
        //    看起来就像「目录全是老模型」。
        for (id, e) in ModelCatalogStore.shared.entriesNewestFirst(provider: provider)
        where !seedIds.contains(id) {
            list.append(CandidateModel(id: id, name: e.name.isEmpty ? id : e.name,
                                       reasoning: e.reasoning, input: e.input,
                                       contextWindow: e.contextWindow ?? 128_000,
                                       maxTokens: e.maxTokens ?? 16_384,
                                       cost: e.cost, thinkingLevelMap: nil))
        }
        return list
    }

    /// 当前预设的种子表 (硬准入的第一优先级)。刻意不从 candidates 取 —— 那里混着目录条目,
    /// 目录刷新后需要能按新元数据重算。
    private var seedMap: [String: ProviderPreset.SeedModel] {
        Dictionary(uniqueKeysWithValues: (selectedPreset?.seedModels ?? []).map { ($0.id, $0) })
    }

    /// 候选 id = **vendor `/models` 返回集 ∪ 未被列出的种子**（不是纯 `/models`）。
    ///
    /// ⚠️ 纯替换会删掉唯一的补丁：订阅制 / 隐藏模型（`MiniMax-M3.1-Flash-Preview`）**永远不会**出现在
    /// 官方清单里，而种子正是为它们维护的 ⇒ 实测「点测试连接后 M3.1 消失」就是这么来的。
    /// 返回 (候选 id 序列, 「本地补充」的 id 集合 —— 给行上打标用)。
    /// 顺序 = 官方原序在前、本地补充在后（保留 vendor 的排序语义, 补丁不插队）。
    private func unionWithUnlistedSeeds(fetched: [String]) -> ([String], Set<String>) {
        let extra = ProviderPresets.vendorUnlisted(returned: fetched, seedIds: seedMap.keys.sorted())
        return (fetched + extra, Set(extra))
    }

    /// 硬准入: 候选 id 逐个定元数据 —— 种子 (不漂移) > models.dev 目录 > 挡掉。
    /// 返回 (候选, 被挡掉的 id)。挡掉的理由: 裸默认 (128k/16k) 会一路物化进 pi, 让引擎按错的窗口
    /// 提前压缩, 而 UI 上完全看不出来 —— 宁可少列, 不可错列。
    /// `vendorUnlisted` = 属于「本地补充」的 id (不在 vendor `/models` 清单里), 打标用。
    private func admit(ids: [String], provider: String,
                       seeds: [String: ProviderPreset.SeedModel],
                       vendorUnlisted: Set<String> = []) -> ([CandidateModel], [String]) {
        var admitted: [CandidateModel] = []
        var missing: [String] = []
        for id in ids {
            if let s = seeds[id] {
                admitted.append(CandidateModel(id: s.id, name: s.name, reasoning: s.reasoning,
                                               input: s.input, contextWindow: s.contextWindow,
                                               maxTokens: s.maxTokens, cost: s.cost,
                                               thinkingLevelMap: s.thinkingLevelMap,
                                               vendorUnlisted: vendorUnlisted.contains(id)))
                continue
            }
            if let e = ModelCatalogStore.shared.entry(provider: provider, modelId: id) {
                admitted.append(CandidateModel(id: id, name: e.name.isEmpty ? id : e.name,
                                               reasoning: e.reasoning, input: e.input,
                                               contextWindow: e.contextWindow ?? 128_000,
                                               maxTokens: e.maxTokens ?? 16_384,
                                               cost: e.cost, thinkingLevelMap: nil,
                                               vendorUnlisted: vendorUnlisted.contains(id)))
                continue
            }
            missing.append(id)
        }
        return (admitted, missing)
    }

    /// 「被挡掉」的提示文案。**必须点名** —— 只报个数字的话用户不知道是哪个, 会当 bug 追
    /// (实测: 挡掉的往往是「官方有、目录没有」的那一两个, 说出来才能判断该不该补种子)。
    private func missingNote(_ missing: [String]) -> String? {
        guard !missing.isEmpty else { return nil }
        let head = missing.prefix(3).joined(separator: ", ") + (missing.count > 3 ? "…" : "")
        return String(format: L("%lld 个模型因缺元数据未列出: %@"), missing.count, head)
    }

    private func testConnection() {
        testState = .testing
        formError = nil
        missingMetaNote = nil
        Task { @MainActor in
            // 表单 key 为空时回落 Keychain 已存 key —— 与 saveModels 对称。
            // ⚠️ 缺此回落 ⇒ 点预设芯片会清空表单 (:419), 紧接着点测试连接就必不带 Authorization
            //    ⇒ 强制鉴权的 provider (MiniMax / DeepSeek / ...) 一律 401 "login fail"。
            let provider = selectedPresetId ?? customProvider.trimmingCharacters(in: .whitespaces)
            let effectiveKey = apiKey.isEmpty ? store.providerKey(provider: provider) : apiKey
            let result = await ModelCatalogFetcher.fetch(
                baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                apiKey: effectiveKey,
                apiType: apiType,
                ollamaStyle: selectedPreset?.ollamaStyle ?? false)
            testState = .done
            if result.verified {
                verified = true
                let seeds = seedMap
                // 候选 = /models ∪ 未列出的种子 (vendor 清单结构性列不出订阅制模型, 见 unionWithUnlistedSeeds)。
                let (ids, unlisted) = unionWithUnlistedSeeds(fetched: result.modelIds)
                let (admitted, missing) = admit(ids: ids, provider: provider,
                                                seeds: seeds, vendorUnlisted: unlisted)
                lastFetchedIds = result.modelIds
                candidates = admitted
                missingMetaNote = missingNote(missing)
                checked = Set(ids.filter { seeds[$0] != nil })   // 种子预勾, 其余不勾
            } else {
                verified = false
                lastFetchedIds = []
                missingMetaNote = nil
                formError = String(format: L("拉取失败 (%@), 已回落预设清单"), result.error ?? L("未知"))
            }
        }
    }

    /// 手动强制刷新 models.dev 目录 (跳过 7 天 TTL); 成功后按新元数据重算候选。
    private func refreshCatalog() {
        catalogBusy = true
        catalogNote = nil
        Task { @MainActor in
            let ok = await ModelCatalogStore.shared.refreshRemote()
            catalogBusy = false
            guard ok else {
                catalogNote = L("更新失败, 保留原目录")
                return
            }
            let catalog = ModelCatalogStore.shared
            let models = catalog.providers.values.reduce(0) { $0 + $1.count }
            catalogNote = String(format: L("已更新: %lld 家 / %lld 条"), catalog.providers.count, models)
            // 元数据就是候选的输入 ⇒ 目录变了要把候选重算一遍 (不重拉 /models)
            let provider = selectedPresetId ?? customProvider.trimmingCharacters(in: .whitespaces)
            if !lastFetchedIds.isEmpty {
                // 重算走与 testConnection 同一条式子 (并集 + 标记), 否则标记会与候选来源不一致。
                let (ids, unlisted) = unionWithUnlistedSeeds(fetched: lastFetchedIds)
                let (admitted, missing) = admit(ids: ids, provider: provider,
                                                seeds: seedMap, vendorUnlisted: unlisted)
                candidates = admitted
                checked = checked.intersection(Set(admitted.map(\.id)))
                missingMetaNote = missingNote(missing)
            } else if let p = selectedPreset {
                candidates = mergeCatalog(provider: p.id, seeds: p.seedModels)
                checked.formUnion(p.seedModels.map(\.id))
            }
        }
    }

    private var catalogStatusText: String {
        if let catalogNote { return catalogNote }
        let catalog = ModelCatalogStore.shared
        guard !catalog.isEmpty else { return L("目录为空, 点「更新模型目录」拉取") }
        let models = catalog.providers.values.reduce(0) { $0 + $1.count }
        return catalog.isStale
            ? String(format: L("目录: %lld 家 / %lld 条, 已过期"), catalog.providers.count, models)
            : String(format: L("目录: %lld 家 / %lld 条"), catalog.providers.count, models)
    }

    private func saveModels() {
        let provider = selectedPresetId ?? customProvider.trimmingCharacters(in: .whitespaces)
        guard !provider.isEmpty, !checked.isEmpty else { return }
        let source: ManagedModelSource = selectedPresetId != nil ? .preset : .custom
        if needsKey && !apiKey.isEmpty {
            store.setProviderKey(apiKey, provider: provider)
        }
        if needsKey && apiKey.isEmpty && store.providerKey(provider: provider) == nil {
            formError = L("该预设需要 API Key")
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
        missingMetaNote = nil
        lastFetchedIds = []
    }

    // MARK: - P10.1b 联网搜索 (博查 API Key)

    /// 博查 key 是**内置搜索扩展的挂载条件** —— 没它还把扩展挂上, 只会让模型每次调用都收到
    /// "未配置"。所以这一栏不是"可选项", 而是插件面板里那一行的**电源**。
    private var webSearchSection: some View {
        let hasKey = store.bochaKey != nil
        return VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "联网搜索 (博查 API Key)",
                       detail: "配好 Key 才会挂上内置搜索扩展 (工具 bocha_web_search); Key 存 Keychain, 只在 spawn 时以环境变量注入 pi 进程, 不落盘") {
                HStack(spacing: 8) {
                    SecureField("博查 API Key", text: $bochaKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(CodexTheme.fontSmall)
                        .frame(minWidth: 220)
                    Button("保存") { saveBochaKey() }
                        .fixedSize()
                        .disabled(bochaKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey {
                        Button("清除") { store.setBochaKey(nil) }
                            .fixedSize()
                    }
                }
            }
            Divider().overlay(CodexTheme.divider)
            // ⚠️ 两个分支**各写一个字面量** —— 压成 `LK(三目)` 会让英文界面恒中文 (verbatim 渲染)。
            if hasKey {
                Text("已保存 (重新输入可覆盖)")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.toolDone)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("未配置 —— 联网搜索不可用")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsCard()
    }

    private func saveBochaKey() {
        store.setBochaKey(bochaKeyInput)
        bochaKeyInput = ""
    }

    // MARK: - P18 computer use (批 1 读 / 批 2b 动作)

    private var computerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "电脑操作",
                       detail: "全局开关: 开 = 常规与完整模式的会话都能读你勾过的应用的界面, 不是只对当前会话生效 (极简与 codemode 档看不到这些工具)。再给某个 App 勾上「可操作」它才能按按钮/填输入框 —— 勾上就是允许, 不再逐次问你; 没勾的一律只读。让助手打开一个 App 只需要「可读」(那等于替你点一下图标)") {
                Toggle("", isOn: $computer.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
            }
            Divider().overlay(CodexTheme.divider)
            // ⚠️ 2026-10-29 实测更正: 系统**不会**弹窗(helper 用 `AXIsProcessTrustedWithOptions(nil)`
            //    只查不索要), 所以它也不会作为条目出现在列表里 —— 一直用的是 MangoX 自己的授权
            //    (helper 是 MangoX 的子进程, TCC 按 responsible process 记账)。
            //    原文案「勾的是 mangox-compute 这一条」是**错的**, 会让人在列表里白找。
            Text("读界面要用「辅助功能」权限: 到 系统设置 › 隐私与安全性 › 辅助功能 里勾上 MangoX —— 列表里不会有 mangox-compute 这个名字, 它跟着 MangoX 的身份走。没勾就读不到界面, 工具会把原因直接说出来")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(CodexTheme.divider)
            HStack(spacing: 8) {
                Text("读与操作哪些应用")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CodexTheme.textPrimary)
                Spacer(minLength: 0)
                Button("刷新") { computer.refresh() }
                    .fixedSize()
            }
            computerAppList
            computerStatusLine
        }
        .settingsCard()
        .onAppear { computer.refresh() }
    }

    /// 列表 = **已安装 ∪ 运行中**（合并逻辑在 `ComputerSettings.merge`，纯函数，冒烟守着）。
    ///
    /// ⚠️ 只列"正在运行"的话，没打开的 App 就永远勾不到 —— 2026-10-28 boss 拿着截图问
    ///    「浏览器怎么都没有」就是这个：Safari 没开，所以它不在列表里。
    @ViewBuilder
    private var computerAppList: some View {
        let q = computerQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = q.isEmpty ? computer.options : computer.options.filter {
            $0.name.lowercased().contains(q) || $0.bundle.lowercased().contains(q)
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                TextField("搜索应用…", text: $computerQuery)
                    .textFieldStyle(.plain)
                    .font(CodexTheme.fontSmall)
                if !computerQuery.isEmpty {
                    Button("清除") { computerQuery = "" }
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(CodexTheme.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: CodexTheme.radiusSm))

            if rows.isEmpty {
                Text(computer.options.isEmpty ? "正在列出应用…" : "没有匹配的应用")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // ⚠️ 必须**限高**: 已安装的 App 有几百个，不限高会把设置页撑成无限长，
                //    下面的状态说明与其它段全被推出屏幕。
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { app in computerRow(app) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private func computerRow(_ app: ComputerSettings.Option) -> some View {
        let readable = computer.selected.contains(app.bundle)
        let actable = computer.actSelected.contains(app.bundle)
        let mayAct = ComputerSettings.canAct(app.bundle)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: app.name)
                        .font(.system(size: 12))
                        .foregroundStyle(CodexTheme.textPrimary)
                    // ⚠️ 只标"在跑"的: 几百行都写"未运行"是噪音，而"现在就能读"才是要突出的。
                    if app.running {
                        Text("运行中")
                            .font(.system(size: 9))
                            .foregroundStyle(CodexTheme.toolDone)
                    }
                }
                Text(verbatim: app.bundle)
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
            }
            Spacer(minLength: 0)
            // 两档权限**正交但有序**: 操作面必须在读面之下 —— 没勾读时"可操作"整格灰掉，
            // 而不是"勾了之后悄悄帮你把读也勾上"(那会让人以为自己只开了一档)。
            Toggle(L("可读"), isOn: Binding(get: { readable },
                                           set: { _ in computer.toggle(app.bundle) }))
                .toggleStyle(.checkbox)
            if mayAct {
                Toggle(L("可操作"), isOn: Binding(get: { actable },
                                                set: { computer.setAct(app.bundle, $0) }))
                    .toggleStyle(.checkbox)
                    .disabled(!readable)
            } else {
                // ⚠️ 口令/系统类应用占**同一个位置**的禁用态，而不是干脆不显示:
                //    不显示的话用户会以为"这批功能不支持这个 App"，于是去别处找开关。
                Text(L("不可操作"))
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                    .help(L("口令 / 系统设置类应用: 只读, 永远不给操作权限"))
            }
        }
        // ⚠️ 总开关关着时勾不了: 否则会出现"勾了但这一轮并没开放"，而界面上没有任何地方
        //    说为什么（停用态必须看得出来，不能只是点了没反应）。
        .disabled(!computer.enabled)
    }

    @ViewBuilder
    private var computerStatusLine: some View {
        if !computer.enabled {
            Text("已关闭 —— 这个工具不会挂上, 模型看不到它")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else if computer.selected.isEmpty {
            Text("开了但一个都没勾 ⇒ 所有会话都用不了 (空 = 不开放, 不是全都行)")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.toolRunning)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("可读")
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.toolDone)
                    Text(verbatim: "\(computer.activeBundles.count) 个")
                        .font(.system(size: 11))
                        .foregroundStyle(CodexTheme.toolDone)
                    // 操作面单独报一个数 —— 它与读面是两档权限, 只报一个数会让人以为
                    // 「开放了」就等于「能动」。
                    Text("可操作")
                        .font(.system(size: 11))
                        .padding(.leading, 6)
                        .foregroundStyle(computer.activeActBundles.isEmpty
                                         ? CodexTheme.textMuted : CodexTheme.toolDone)
                    Text(verbatim: "\(computer.activeActBundles.count) 个")
                        .font(.system(size: 11))
                        .foregroundStyle(computer.activeActBundles.isEmpty
                                         ? CodexTheme.textMuted : CodexTheme.toolDone)
                }
                // ⚠️ 这一行是 boss 2026-10-29 那条的落点: 名单存在全局 settings 表里,
                //    不是某个会话的私有凭证 —— 所以这里必须说破"全局 + 改完何时生效",
                //    否则人会以为勾选是"只对眼前这场对话生效"。
                Text("常规与完整模式的会话都能用 (不是只对当前会话); 改完勾选, 下一次对话才生效")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                // 列表是**数据**不是文案 ⇒ verbatim, 不进词表。
                Text(verbatim: computer.activeBundles.joined(separator: "\n"))
                    .font(.system(size: 10))
                    .foregroundStyle(CodexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 并发上限

    // MARK: - 锁屏运行 (2026-10-27: 有回合在途时别让机器睡过去)

    private var lockScreenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(title: "允许锁屏运行",
                       detail: "有任务在跑时不让电脑休眠，跑完自动恢复；没任务时照常休眠") {
                CodexPillMenu {
                    ForEach(LockScreenMode.allCases) { mode in
                        // ⚠️ `Menu` 里只能放 Button/Toggle/Picker/Link —— 照 Picker 抄成
                        //    `Text(x).tag(x)` 会让整列变**灰色禁用项**且点不中 (零编译信号)。
                        Button {
                            store.lockScreenMode = mode
                        } label: {
                            Text(mode == store.lockScreenMode ? "✓ " + mode.label : mode.label)
                        }
                    }
                } label: {
                    // ⚠️ 图标写在**前面**：macOS 的 `Menu` 会把 label 里的图标提到最左
                    //    （实测：写成"文字+图标"也渲染成"图标+文字"）。按渲染结果写，
                    //    免得下次有人照源码以为顺序反了又"修"一遍。
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(CodexTheme.textMuted)
                    Text(store.lockScreenMode.label)
                }
                // ⚠️ 必须 fixedSize：`Menu` 在 HStack 里会**撑满剩余宽度**，胶囊会变成一条
                //   横贯整行的长条（本行其余控件也都带这一句，我第一版漏了）。
                .fixedSize()
                .help("选择锁屏后是否让电脑保持唤醒")
            }
            Divider().overlay(CodexTheme.divider)
            // ⚠️ 这两句是**给人看的**, 不许出现"断言 / 子进程 / 调度"这类词 ——
            //    boss 2026-10-27 原话: "『断言』『pi子进程』等描述过于专业, 使用更加易懂的描述"。
            Text("熄屏后保持唤醒 = 屏幕可以熄灭，电脑不睡；保持屏幕常亮 = 连屏幕也不熄灭（更费电）。")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text("只保证 MangoX 自己不被休眠打断。任务实际是在后台进程里跑的，系统会不会让它变慢，这条设置影响不到。")
                .font(.system(size: 11))
                .foregroundStyle(CodexTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsCard()
    }

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
                return L("⚠️ 系统通知未授权 —— 请到 系统设置 → 通知 → MangoX 开启")
            case .notDetermined:
                return L("尚未请求通知授权, 打开开关后首次完成时会请求")
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
                    Button(LK(store.backupRunning ? "备份中…" : "立即备份")) { runBackup() }
                        .fixedSize()
                        .disabled(store.backupRunning || store.backupDirectory == nil)
                    Button("选择目录…") { pickBackupDir() }
                        .fixedSize()
                }
            }
            Divider().overlay(CodexTheme.divider)
            HStack {
                Text(LK(store.backupDirectory ?? "未选择备份目录"))
                    .font(CodexTheme.fontMonoXs)
                    .foregroundStyle(CodexTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(LK(store.lastBackupSummary ?? "尚未备份"))
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
        panel.prompt = L("选择")
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

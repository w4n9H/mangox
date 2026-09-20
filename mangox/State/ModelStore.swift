//
//  ModelStore.swift
//  P9.1c: 模型域自 ChatStore 抽离 (P3.5 能力状态/P5.1 自定义/P7-M3 自管物化/模型菜单)。
//  拆分不动行为: ChatStore 保留同名 facade 转发 (冒烟/视图零改动);
//  能力上报归并 (didUpdateModelState/didReportModels) 留 ChatStore 核心, 经 facade 写回状态;
//  物化产物对 transport 池的下发经 store.pushPIConfig 回调。
//

import Foundation
import Combine

@MainActor
final class ModelStore: ObservableObject {

    // P3.5: 对端能力上报
    /// 可用模型清单 (pi get_available_models; 空 = 尚未上报, 菜单只显示当前模型)。
    @Published var availableModels: [AgentModelInfo] = []
    /// P5.1: 自定义模型条目 (菜单自主 — 与 pi 目录展示名解耦; 同名时覆盖 pi 条目)。
    @Published var customModels: [CustomModel] = []
    /// P7-M3: 自管模型条目 (settings 页管理, 物化给 pi; 真源 models 表)。
    @Published var managedModels: [ManagedModel] = []
    /// 当前模型 (provider/id 分量), composer 模型菜单的数据源。
    @Published var currentProvider: String = ""
    @Published var currentModelId: String = ""
    /// 当前思考级别 (pi 状态)。
    @Published var thinkingLevel: ThinkingLevel = .high
    /// 用户是否已在 UI 选过模型/级别 (选过 = 期望值钉死, 探测上报不再回写)。
    @Published var userThinkingLevelPinned: Bool = false
    /// P7-M3: 物化产物快照 (spawn 期下发; 缺失 = 会话 spawn 读 ~/.pi/agent)。
    private(set) var currentPIConfig: ModelMaterializer.Output?

    private weak var store: ChatStore?
    func attach(_ store: ChatStore) { self.store = store }

    // MARK: - 投影 (composer/状态栏)

    /// P7-M6b: 当前选中模型是否支持图片输入 (managed 有 inputModalities; 无法判定 → 不拦)。
    var currentModelSupportsImages: Bool {
        guard let store,
              let m = managedModels.first(where: {
                  $0.provider == store.currentProvider && $0.modelId == store.currentModelId
              })
        else { return true }
        return m.inputModalities.contains("image")
    }

    // MARK: - 模型菜单 (P3.5/P5.1/P7-M3)

    /// 菜单条目 = 每个模型 × 其支持的思考级别 (无级别的模型单条)。
    /// 条目 id 含级别分量, 笛卡尔积下同模型多条不会 ForEach 撞 id。
    var modelMenuEntries: [ModelMenuEntry] {
        menuEntries(for: menuModels)
    }

    /// 自定义条目对应的 AgentModelInfo (全级别)。
    var customModelInfos: [AgentModelInfo] {
        customModels.map(\.asAgentModelInfo)
    }

    /// pi 目录条目 (排除被自定义条目覆盖者 —— P5.1 拍板: 同名 provider/id 时 custom 覆盖)。
    var catalogModels: [AgentModelInfo] {
        let overridden = Set(customModels.map(\.id))
        return availableModels.filter { !overridden.contains("\($0.provider)/\($0.id)") }
    }

    /// 菜单全集 (P7-M3 拍板: 有自管模型时只显示 enabled 自管条目, pi 上报目录退出菜单;
    /// 一个都没配时回落 pi 目录 + P5.1 自定义, 保证可用性)。
    var menuModels: [AgentModelInfo] {
        let managed = managedModels.filter(\.enabled).map(\.asAgentModelInfo)
        if !managed.isEmpty { return managed }
        return customModelInfos + catalogModels
    }

    /// 指定模型集的菜单条目展开 (模型 × 级别)。
    func menuEntries(for models: [AgentModelInfo]) -> [ModelMenuEntry] {
        models.flatMap { m in
            let levels: [ThinkingLevel?] = m.supportedLevels.isEmpty ? [nil] : m.supportedLevels
            return levels.map { ModelMenuEntry(id: "\(m.provider)/\(m.id)#\($0?.rawValue ?? "-")",
                                               model: m, level: $0) }
        }
    }

    /// 菜单条目是否为当前选中组合。
    func isCurrent(_ entry: ModelMenuEntry) -> Bool {
        guard let store else { return false }
        return entry.model.provider == store.currentProvider && entry.model.id == store.currentModelId &&
            (entry.level == nil || entry.level == store.thinkingLevel)
    }

    // MARK: - P5.1 自定义模型 (菜单自主, 运行时借壳)

    /// pi 目录中存在的 provider 集合 (从能力上报推导)。
    var validProviders: Set<String> {
        Set(availableModels.map(\.provider))
    }

    /// provider 校验: 上报未到达时不做拦截 (无法判定), 否则必须命中目录。
    func isValidProvider(_ provider: String) -> Bool {
        let p = provider.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return false }
        return availableModels.isEmpty || validProviders.contains(p)
    }

    /// 自定义条目显示名 (药丸优先显示自定义 label; 设计 §3.3 拍板)。
    func customLabel(provider: String, modelId: String) -> String? {
        if let m = managedModels.first(where: { $0.provider == provider && $0.modelId == modelId }) {
            return m.displayNameOrId   // P7-M3: 自管条目优先 (含 legacy 迁移)
        }
        return customModels.first { $0.provider == provider && $0.modelId == modelId }?.displayName
    }

    /// 当前选中模型的显示名: 自定义 label 优先, 回落 id 末段。
    var currentModelDisplayName: String {
        guard let store else { return "model" }
        if let label = customLabel(provider: store.currentProvider, modelId: store.currentModelId) {
            return label
        }
        if !store.currentModelId.isEmpty {
            return store.currentModelId.components(separatedBy: "/").last ?? store.currentModelId
        }
        return "model"
    }

    /// 新增/覆盖自定义模型 (落库 + 刷菜单)。返回 false = provider 不在 pi 目录中。
    @discardableResult
    func addCustomModel(provider: String, modelId: String, label: String = "") -> Bool {
        let p = provider.trimmingCharacters(in: .whitespaces)
        let m = modelId.trimmingCharacters(in: .whitespaces)
        guard isValidProvider(p), !m.isEmpty else { return false }
        let item = CustomModel(provider: p, modelId: m,
                               label: label.trimmingCharacters(in: .whitespaces))
        try? store?.persistence?.upsertCustomModel(item)
        if let idx = customModels.firstIndex(where: { $0.id == item.id }) {
            customModels[idx] = item          // 覆盖: label 更新
        } else {
            customModels.insert(item, at: 0)
        }
        return true
    }

    /// 删除自定义模型 (落库 + 刷菜单; 当前选中项不强制切回, 仅不再出现在菜单)。
    func removeCustomModel(_ model: CustomModel) {
        try? store?.persistence?.deleteCustomModel(provider: model.provider, modelId: model.modelId)
        customModels.removeAll { $0.id == model.id }
    }

    // MARK: - P7-M3 模型自管 (settings 页真源 + 物化推送)

    /// 物化产物下发 (探测实例 + 注入实例 + 全部会话实例; 模型变更/启动时调用)。
    func refreshPIConfig() {
        let output: ModelMaterializer.Output? = managedModels.isEmpty ? nil :
            ModelMaterializer.materialize(managedModels, keyProvider: { [weak self] account in
                self?.store?.modelKeyStore.key(account: account)
            })
        currentPIConfig = output
        store?.pushPIConfig(output)
    }

    /// 新增/更新自管模型 (落库 + 刷物化)。
    func upsertManagedModel(_ m: ManagedModel) {
        try? store?.persistence?.upsertManagedModel(m)
        if let idx = managedModels.firstIndex(where: { $0.id == m.id }) {
            managedModels[idx] = m
        } else {
            managedModels.insert(m, at: 0)
        }
        refreshPIConfig()
    }

    /// 删除自管模型 (落库 + 刷物化)。
    func deleteManagedModel(_ m: ManagedModel) {
        try? store?.persistence?.deleteManagedModel(provider: m.provider, modelId: m.modelId)
        managedModels.removeAll { $0.id == m.id }
        refreshPIConfig()
    }

    /// 启停开关 (enabled 决定进不进物化清单)。
    func setManagedModelEnabled(_ id: String, _ enabled: Bool) {
        guard var m = managedModels.first(where: { $0.id == id }) else { return }
        m.enabled = enabled
        upsertManagedModel(m)
    }

    /// provider 级 key 存取 (Keychain; account = provider, 物化进 auth.json)。
    func setProviderKey(_ key: String, provider: String) {
        try? store?.modelKeyStore.setKey(key, account: provider)
        refreshPIConfig()
    }

    func providerKey(provider: String) -> String? {
        store?.modelKeyStore.key(account: provider)
    }

    /// 选中自管模型 (settings 行"启用"; thinking 级别放开全级别, pi 侧 clamp 收敛)。
    func selectManagedModel(_ m: ManagedModel) {
        selectModel(m.asAgentModelInfo, level: nil)
    }

    /// 选中组合: 全局期望更新 (新实例由 transportFor 补发) + 选中会话实例即时下发
    /// (pi 侧各自动回读 get_state 同步 UI; P4.0.2 spawn 期参数随该会话下回合生效)。
    func selectModel(_ model: AgentModelInfo, level: ThinkingLevel?) {
        guard let store else { return }
        store.currentProvider = model.provider
        store.currentModelId = model.id
        store.userThinkingLevelPinned = true   // 期望钉死: 探测上报不再回写级别
        if let level { store.thinkingLevel = level }
        guard let sid = store.selectedConversationId else { return }
        let t = store.transportFor(sid)
        t.setModel(provider: model.provider, modelId: model.id)
        if let level { t.setThinkingLevel(level.rawValue) }
        store.stampSessionConfig()   // P10.3: 写穿选中会话配置
    }
}

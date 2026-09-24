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

    // MARK: - 模型菜单 (P7-M3)

    /// pi 上报目录 (裸态回落的唯一来源; 由 capabilityProbe 的 get_available_models 写入)。
    var catalogModels: [AgentModelInfo] { availableModels }

    /// 菜单全集 (P7-M3 拍板: 有自管模型时只显示 enabled 自管条目, pi 上报目录退出菜单;
    /// 一个都没配时回落 pi 目录, 保证可用性)。
    /// (2026-09-23: "模型 × 级别"笛卡尔积展开已删 —— 级别改由 `ModelPicker` 滑轨选,
    ///  菜单回归**纯模型列表**; 展开只为 `ForEach` 唯 id 而存在, 控件换 popover 后不再需要。)
    var menuModels: [AgentModelInfo] {
        let managed = managedModels.filter(\.enabled).map(\.asAgentModelInfo)
        return managed.isEmpty ? catalogModels : managed
    }

    /// 当前选中组合 (composer 药丸的初值; 视图不必逐个读三个字段)。
    var currentChoice: ModelChoice {
        ModelChoice(provider: currentProvider, modelId: currentModelId, level: thinkingLevel)
    }

    // (P5.1 自定义模型层已于 2026-09-23 删除: 生产 UI 零入口 —— Settings 页只走自管模型,
    //  且启动时 migrateLegacyCustomModels 已把 custom_models 行搬进 models 表。
    //  custom_models 表保留, 用于兼容旧版本写的库。)

    /// 条目显示名 (自管条目优先; 含 legacy 迁移条目)。
    func customLabel(provider: String, modelId: String) -> String? {
        managedModels.first { $0.provider == provider && $0.modelId == modelId }?.displayNameOrId
    }

    /// 当前选中模型的显示名: 自管 label 优先, 回落 id 末段。
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

    /// 选中自管模型 (settings 行"启用")。级别收敛到该模型支持的档位 —— 旧实现传 `nil`
    /// (级别不变, 靠 pi 侧 clamp), 于是有"胶囊显示 xhigh、实际跑 off"的割裂 (P8 实测)。
    func selectManagedModel(_ m: ManagedModel) {
        let info = m.asAgentModelInfo
        selectModel(ModelChoice(provider: info.provider, modelId: info.id,
                                level: clampLevel(thinkingLevel, to: info)))
    }

    /// 选中组合 (**整体写入**, 级别已是合法停靠点 —— 收敛在 `ModelPicker` / `clampLevel` 一处完成):
    /// 全局期望更新 (新实例由 transportFor 补发) + 选中会话实例即时下发
    /// (pi 侧各自动回读 get_state 同步 UI; P4.0.2 spawn 期参数随该会话下回合生效)。
    func selectModel(_ pick: ModelChoice) {
        guard let store else { return }
        store.currentProvider = pick.provider
        store.currentModelId = pick.modelId
        store.userThinkingLevelPinned = true   // 期望钉死: 探测上报不再回写级别
        store.thinkingLevel = pick.level
        guard let sid = store.selectedConversationId else { return }
        let t = store.transportFor(sid)
        t.setModel(provider: pick.provider, modelId: pick.modelId)
        t.setThinkingLevel(pick.level.rawValue)
        store.stampSessionConfig()   // P10.3: 写穿选中会话配置
    }
}

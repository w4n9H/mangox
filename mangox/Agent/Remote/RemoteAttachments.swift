//
//  RemoteAttachments.swift
//  P19.2 S15c —— 「助理把文件发到飞书」的**投递侧**。
//
//  ── 分工（这条线只有一个方向）──────────────────────────────────────────────
//  模型调 `feishu_attach(path)` → 扩展往 spool 追加一行（**不碰网络、不知道 chat_id**）
//  → 回合落定时 App 读 spool、**在这里校验** → 交给桥去上传并发送。
//
//  ⚠️ 为什么工具只写 spool、不当场发: 工具跑在 pi 子进程里，它没有任何途径拿到
//     "这一轮是哪个 chat_id"。而"谁有权发"这件事必须由 App 定 —— `remoteTurns`
//     只在**飞书私聊真的来了话**那一刻写入（`RemoteChannelService.deliver`），
//     定时巡检 / fire / pushFinding 拿不到 chatId，想发也发不出。这条结构性围栏
//     是现成的，别为了"让工具能发"去削弱它。
//
//  ── 校验为什么在 App 而不在扩展里 ──────────────────────────────────────────
//  同 `note_proposal` 那条: 根表、重定向、凭据判据全在 Swift 侧（`Redline` / 测试用的
//  `spoolRootOverride`）。复制一份到 TS 里就是第二真源，而且它看不见这些重定向。
//
//  ── 2026-11-19 实测（决定了下面几个常量）────────────────────────────────────
//  · 文件上限 **30 MB**: 22.0 MB 通, 33.0 MB 回 `http=400 code=234006`。
//  · 图片走另一个接口（`im/v1/images`），`image_type` 只能用 `message`
//    （`avatar` 也回 200，但 key 前缀是 `v3_`，拿去发消息会失败）。
//  · 上传素材要 `im:resource:upload`（或 `im:resource`），缺了回 `99991672`。
//
//  ⚠️ 大小在这里先拦一道的理由不是省流量，是**说得清**: 桥会把 `234006` 翻成
//     "超过 30MB"，但那时整个文件已经进了内存、也已经开始上传了。
//

import Foundation

/// 一件要发出去的附件。**不含"是图片还是文件"** —— 那个判断只在桥里做一次
/// （它才是调接口的那个）。两个地方各判一遍必然会漂，而漂了的表现是
/// "App 日志说发了图片、对方收到的是一坨文件"。
struct RemoteAttachment: Equatable {
    /// 规整过的绝对路径（符号链接已解）。
    let path: String
    /// 对方看到的文件名。
    let name: String
}

enum AttachDecision: Equatable {
    case ok(RemoteAttachment)
    /// 拒的理由**要对人可以说** —— 它会原样回到模型手里，也会进日志。
    case rejected(String)
}

enum RemoteAttachments {

    // MARK: - 落点

    /// spool 目录。**固定的**（不是每次 spawn 新目录）—— 理由同 `dream-spool`:
    /// 路径是 env 里下发的契约，App 崩溃后残留的这一份还能被同 `sid` 的下一轮看见。
    static var spoolRootOverride: String?

    static func spoolDir() -> String {
        spoolRootOverride ?? (NSHomeDirectory() + "/.mangox/feishu-attach")
    }

    /// 一轮一个文件，**文件名 = 会话 id**。用完即删（见 `drain`）。
    static func spoolPath(sid: UUID) -> String {
        spoolDir() + "/\(sid.uuidString).jsonl"
    }

    // MARK: - 判据（数字都来自实测，见文件头）

    /// 飞书文件上限。**30 MB** 是实测出来的边界（22.0 通 / 33.0 拒、code 234006）。
    static let maxBytes = 30 * 1024 * 1024

    /// 一轮最多几件。与 `note_proposal` 同口径（≤3）—— 那是"一批别塞太多"的经验值，
    /// 不是飞书的限制（限流是 50 次/秒，够用）。
    static let maxPerTurn = 3

    /// 白名单：**只有这两个目录**（2026-11-19 boss 定）。
    ///
    /// ⚠️ 用 `resolvingSymlinksInPath` 规整 —— iCloud 的「文稿」在有些机器上是软链,
    ///    不解析会把正常文件判成"不在白名单里"（假红比漏放更糟: 用户会觉得功能坏了）。
    static func allowedRoots() -> [String] {
        if let override = rootsOverride { return override.map(canonical) }
        return [NSHomeDirectory() + "/Documents", NSHomeDirectory() + "/Downloads"]
            .map { canonical($0) }
    }

    /// **进程级**重定向（冒烟）—— 与 `spoolRootOverride` 同一个理由: 生产调用点
    /// (`deliverAttachments`) 不传参数, 而真去读用户的 `~/Documents` 既不可写也不该依赖。
    /// ⚠️ 漏一次的后果是"夹具文件永远被拒", 表现是附件那几格恒红或恒绿。
    static var rootsOverride: [String]?

    /// 把路径规整成可比较的样子：展开 `~`、去 `..`、解软链。
    ///
    /// ⚠️ **解软链是安全判据的一半**: `~/Downloads/x` 指向 `~/.ssh/id_rsa` 时，
    ///    只看字面路径就放行了 —— 而发出去的是私钥。
    static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 纯字符串判据：`path` 是否**真的在**某个根里面。
    ///
    /// ⚠️ 必须比 `root + "/"`，不能只比 `root` —— 否则 `~/Documents_backup/x` 会命中
    ///    `~/Documents`。这个前缀坑与"临时目录前缀"是同一族。
    static func isInside(_ path: String, roots: [String]) -> Bool {
        roots.contains { path.hasPrefix($0 + "/") }
    }

    // MARK: - 判定

    /// 单个候选文件过不过。**顺序有讲究**：先规整再判白名单，最后才 stat。
    ///
    /// 为什么最后才 stat: `stat` 在受保护目录上可能直接 `EPERM`，那时"没权限"会盖住
    /// "本来就不在白名单里"这个更准确的原因 —— 而后者是模型能自己改的（换路径），
    /// 前者只能等人去系统设置点一下。
    static func decide(path rawPath: String, name rawName: String, roots: [String],
                       maxBytes: Int = RemoteAttachments.maxBytes) -> AttachDecision {
        // ⚠️ 根表也走同一个 `canonical` —— 否则 `/var/folders/…`（临时目录的原样字符串）
        //    与文件规整后的 `/private/var/…` 前缀对不上，测试里全都判成"不在白名单"，
        //    而生产环境看不出这个问题（`~/Downloads` 本来就不是软链）。
        let roots = roots.map(canonical)
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(L("路径是空的")) }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .rejected(String(format: L("要给绝对路径（收到的是「%@」）"), trimmed))
        }
        let path = canonical(expanded)
        guard isInside(path, roots: roots) else {
            return .rejected(String(format: L("只能发 Documents 或 Downloads 里的文件（这个不在: %@）"), path))
        }
        // 凭据是第二道锁：白名单里也可能躺着 `Downloads/.ssh/id_rsa` 这种被拷进来的东西。
        if Redline.isCredentialPath(path) {
            return .rejected(String(format: L("这看着是凭据文件，不发（%@）"), path))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return .rejected(String(format: L("文件不存在: %@"), path))
        }
        if isDir.boolValue { return .rejected(String(format: L("这是个目录，不是文件: %@"), path)) }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        guard let bytes = size else {
            return .rejected(String(format: L("读不到它的大小（没有权限？）: %@"), path))
        }
        guard bytes > 0 else {
            return .rejected(String(format: L("是空文件（飞书不收空文件）: %@"), path))
        }
        guard bytes <= maxBytes else {
            return .rejected(String(format: L("太大了（%ld MB，上限 %ld MB）: %@"),
                                   bytes / 1024 / 1024, maxBytes / 1024 / 1024, path))
        }
        let rawBase = (rawName as NSString).lastPathComponent
        let base = rawBase.isEmpty || rawBase == "." ? (path as NSString).lastPathComponent : rawBase
        return .ok(RemoteAttachment(path: path, name: base))
    }

    // MARK: - spool

    /// 读走这一轮的附件，**读完即删**。
    ///
    /// ⚠️ 为什么读即删、而不是"发成功再删": 这条队列没有"重试"这回事 —— 留着它就等于
    ///    让**下一轮**把它发出去（而那一轮可能是几天后、人在问别的事）。丢一件附件，
    ///    用户会再要一次；凭空多一个旧文件，用户会怀疑助理在乱发东西。**丢比误发可见。**
    ///
    /// 返回 `(files, notes)`：`notes` 是给人看的一句话（被拒的、超额的），进日志与回执。
    static func drain(sid: UUID, roots: [String] = RemoteAttachments.allowedRoots())
        -> (files: [RemoteAttachment], notes: [String]) {
        let path = spoolPath(sid: sid)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ([], [])
        }
        try? FileManager.default.removeItem(atPath: path)

        var files: [RemoteAttachment] = []
        var notes: [String] = []
        var seen = Set<String>()
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let p = obj["path"] as? String else { continue }
            let name = obj["name"] as? String ?? ""
            switch decide(path: p, name: name, roots: roots) {
            case .rejected(let why):
                notes.append(why)
            case .ok(let file):
                guard !seen.contains(file.path) else { continue }
                seen.insert(file.path)
                guard files.count < maxPerTurn else {
                    notes.append(String(format: L("一轮最多发 %ld 件，多的没发（%@）"),
                                        maxPerTurn, file.name))
                    continue
                }
                files.append(file)
            }
        }
        return (files, notes)
    }
}

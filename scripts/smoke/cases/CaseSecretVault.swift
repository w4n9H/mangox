//
//  CaseSecretVault.swift
//  凭据保险库（2026-11-25）—— "装一个新版本要连输四五次密码"那个问题的代码半边。
//
//  ── 为什么要合并成一个条目 ────────────────────────────────────────────────────
//  macOS 的钥匙串授权粒度是**每个条目一次**（不是每次读一次）。原来三类凭据散在三个 service、
//  一条一个条目：启动读 bocha + 物化 auth.json 时那几条 provider key（四次授权框），
//  点「集成」再读一次飞书 secret（第五次）。合成一个条目 ⇒ 一个进程最多一次。
//
//  ── 这个文件判什么 ───────────────────────────────────────────────────────────
//  合并之后**多出两种新的失败模式**，两种都静默（不崩、不报错，只是"东西不见了"）:
//    ① **整条重写会抹掉别人的键** —— 保险库是一个字典，写 A 时若把整条覆盖成 {A}，
//       B 和 C 就没了，而 `value()` 读不到只会返回 nil（界面表现为"没配过"）。
//    ② **迁移映射错了** —— 老位置是 service + account，新位置是带命名空间的逻辑键。
//       映射错 = 用户的 key 一次也搬不过来，同样是 nil。
//    ③ **迁移只搬得动第一个键** —— 写与读共用一个"还要不要读老位置"的标志，第一条写成功就把
//       闸门关死 ⇒ 后面几个老键永远读 nil。这条最阴：**当时的假实现是空的**，压根翻转不了状态，
//       所以判据恒绿；假实现也得守合同，否则它保护的是自己想象出来的实现。
//  后两条判语义边界：④ 删除（空串 = 删；删一个不动别的）—— 老实现与它同口径，守"别改着改着变了"；
//  ⑤ 重启后不再回读老位置 —— 老条目我们从不删，闸门一松，删掉的键就被它**复活**。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseSecretVault() async {
        print("== T-VAULT 凭据保险库: 一个条目 / 不互相抹 / 迁移映射反解 ==")

        // 夹具: 冒烟里 `SecretVault` 是内存实现（`-D SMOKE` 下不编 Security 那一段），
        // 所以这里**不会**碰用户真实钥匙串 —— 与 `KeychainModelKeyStore.smokeShared` 同一条纪律。
        SecretVault.resetForSmoke()
        let account = UUID()
        let bot = UUID()

        try? SecretVault.set("sk-bocha-1", SecretVault.modelKey("bocha"))
        try? SecretVault.set("auth-163", SecretVault.mailboxAccountKey(account))
        try? SecretVault.set("feishu-secret", SecretVault.remoteBotKey(bot))
        // 再写**第一个**键: 整条重写最容易在这一步把后两个抹掉。
        try? SecretVault.set("sk-bocha-2", SecretVault.modelKey("bocha"))

        let afterWrite = [
            SecretVault.value(SecretVault.modelKey("bocha")),
            SecretVault.value(SecretVault.mailboxAccountKey(account)),
            SecretVault.value(SecretVault.remoteBotKey(bot))
        ]
        check(afterWrite == ["sk-bocha-2", "auth-163", "feishu-secret"],
              "T-VAULT ㊶三类凭据共用一个条目, 且**写一个不抹别人** (实测 \(afterWrite.map { $0 ?? "nil" }))")

        // 迁移映射: 逻辑键 → 老位置（service + account）。三条各自反解回老版本的写法，
        // 而老版本的写法是**已经发出去的库里的东西**，改不了 ⇒ 这条就是迁移契约。
        let legacyModel = SecretVault.legacyLocation(SecretVault.modelKey("bocha"))
        let legacyMail = SecretVault.legacyLocation(SecretVault.mailboxAccountKey(account))
        let legacyBot = SecretVault.legacyLocation(SecretVault.remoteBotKey(bot))
        check(legacyModel?.service == "com.mangox.model-key" && legacyModel?.account == "bocha"
              // 邮箱的 account 与逻辑键**一字不差**（不设第二张对照表，就没有对不上的可能）
              && legacyMail?.service == "com.mangox.mailbox"
              && legacyMail?.account == "mailbox.acct.\(account.uuidString).auth"
              // 飞书的 account 是**去掉 `remote.` 前缀**之后的那一段
              && legacyBot?.service == "com.mangox.remote"
              && legacyBot?.account == "feishu.bot.\(bot.uuidString).secret"
              // 前缀之外的键没有老位置（回 nil，别拿一个瞎猜的 service 去读）
              && SecretVault.legacyLocation("unknown.key") == nil,
              "T-VAULT ㊷迁移映射: 三个命名空间各自反解回老 service 与老 account"
              + " (实测 \(legacyModel?.service ?? "nil")/\(legacyModel?.account ?? "nil") · "
              + "\(legacyBot?.account ?? "nil"))")

        // 删除语义: nil 与空串都算删（老实现 `guard let value, !value.isEmpty` 同口径），
        // 而且**只删那一个**。删漏了 = 界面上删掉的 key 下次启动还在用（更坏：它还在生效）。
        try? SecretVault.set(nil, SecretVault.mailboxAccountKey(account))
        try? SecretVault.set("", SecretVault.remoteBotKey(bot))
        let afterDelete = [
            SecretVault.value(SecretVault.mailboxAccountKey(account)),
            SecretVault.value(SecretVault.remoteBotKey(bot)),
            SecretVault.value(SecretVault.modelKey("bocha"))
        ]
        check(afterDelete == [nil, nil, "sk-bocha-2"],
              "T-VAULT ㊸删除: nil 与空串都按删处理, 且只删那一个 (实测 \(afterDelete.map { $0 ?? "nil" }))")

        // ㊹ 迁移: **老版本升上来那一次必须全部搬完**，不是只搬第一个。
        //    第一版 `persist` 在第一条写成功之后就把"还要不要读老位置"那个标志置成了 true
        //    （写与读共用一个字段）⇒ 第二个键起永远读 nil。表现是邮箱密码、飞书 secret
        //    静默消失，界面只说"没配过" —— 而且它在冒烟里复现不了，因为那时 SMOKE 的
        //    `persist` 是空实现、根本不翻转任何状态。所以假实现也得守合同（见 SecretVault 注释）。
        SecretVault.resetForSmoke()
        let mAccount = UUID()
        let mBot = UUID()
        let modelK = SecretVault.modelKey("bocha")
        let mailK = SecretVault.mailboxAccountKey(mAccount)
        let botK = SecretVault.remoteBotKey(mBot)
        let oldOnes: [(String, String)] = [(modelK, "sk-old"), (mailK, "mail-old"), (botK, "bot-old")]
        var stub: [String: String] = [:]
        for (k, v) in oldOnes {
            guard let loc = SecretVault.legacyLocation(k) else { continue }
            stub["\(loc.service)/\(loc.account)"] = v
        }
        SecretVault.legacyStub = stub
        let migratedValues = [SecretVault.value(modelK), SecretVault.value(mailK), SecretVault.value(botK)]
        check(migratedValues == ["sk-old", "mail-old", "bot-old"],
              "T-VAULT ㊹迁移: 老版本的三个条目一次全部搬过来, 不是只搬第一个"
              + " (实测 \(migratedValues.map { $0 ?? "nil" }))")

        // ㊺ 重启之后**不再问老位置** —— 老条目我们从不删（清的判据要和"谁真持有"同源），
        //    所以只要闸门松一点，用户删掉的 key 就会被老条目**复活**：界面上删了，下次启动还在用。
        try? SecretVault.set(nil, mailK)
        SecretVault.legacyStub = stub.mapValues { _ in "resurrected" }
        SecretVault.reloadForSmoke()          // 模拟重装/重启: 内存丢掉, 钥匙串那条留着
        let afterRestart = [SecretVault.value(mailK), SecretVault.value(modelK)]
        check(afterRestart == [nil, "sk-old"],
              "T-VAULT ㊺重启: 条目已在就不再读老位置, 删掉的键不会被老条目复活"
              + " (实测 \(afterRestart.map { $0 ?? "nil" }))")

        // 自清理: 别把状态留给后面的用例（保险库是进程级单例）。
        SecretVault.resetForSmoke()
    }
}

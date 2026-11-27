//
//  CaseBoot.swift
//  启动页（P20）—— 判的是**"这一屏凭什么敢打勾"**那一半。
//
//  视图本身没有门（版式只归眼睛，亮/暗各看一次），所以这一段判两件事：
//    · **`BootTrace` 的四条状态规则** —— 幂等 / skip 不许盖 done / begin 不许盖 done /
//      `settled` 认 skipped 而 `doneCount` 不认。它们错的方式都很安静：
//      滚动拍每帧都会调一次 `finish`，一个不幂等的 `finish` 只会让读数悄悄变成"最后那次的数"。
//    · **接线真的接上了** —— 建一个真 `ChatStore`，断言 init 里那四行**真的**写了。
//
//  ⚠️ **本段证明不了的那一半（点名在这儿，别以为它绿了就没事）**：
//    判据②「pi 没答话就不许有勾」在冒烟里**看不见** —— `MockTransport.refreshCapabilities()`
//    是**同步**答话的，于是"在 delegate 回调里打勾"和"在 init 里打勾"这两种写法在下面
//    给出**逐字相同**的结果。那半边只能看真机那两张图（`boot-nopi-*`：引擎那行留着
//    `·` + 「pi 未安装」，进度条停在 4/5）。
//    为此专门造一个 25 个空方法的 `SilentTransport` 只为这一条断言，代价大于收益。
//
//  反例:
//    · **实测过**: `BootTrace.finish` 去掉 `phase != .done` 守卫 ⇒ **1 红**（只有 ①，
//      读数被第二次调用覆盖成 99）。还原后按规矩不重跑正例。
//    · **没逐条跑**: ②③④⑤ 各自那道守卫与 ① 同形（同一个 `guard` 里换个相位），
//      本次只验了 ①。谁要动那三道守卫，先按上面同样的办法造一次红再动手。
//

import Foundation

extension SmokeMain {
    @MainActor
    static func caseBoot() async {
        print("== T-BOOT 启动页: BootTrace 四条状态规则 + 接线 ==")

        // ① finish 幂等（读数与相位一起判：只判读数会漏掉"相位被写回 running"那种写法）
        let t = BootTrace()
        t.finish(.workspace, n: 7)
        t.finish(.workspace, n: 99)
        check(t.number(.workspace) == 7 && t.phase(.workspace) == .done,
              "T-BOOT ① finish 幂等: 第二次调用既不许改读数、也不许改相位")

        // ② skip 不许盖掉 done —— 否则"做完之后才发现没装 pi"会把真的做成写成没发生
        t.skip(.workspace)
        check(t.phase(.workspace) == .done, "T-BOOT ② skip 不许把已完成的退回 skipped")

        // ③ begin 不许盖掉 done —— `sessions` 的 begin 写在 init 尾巴上，与上面那条同族
        t.begin(.workspace)
        check(t.phase(.workspace) == .done, "T-BOOT ③ begin 不许把已完成的退回 running")

        // ④ doneCount 只数 done（没装 pi 那一行不算"做成"）；还没到齐 ⇒ 不许收场
        let u = BootTrace()
        u.finish(.model, n: 1)
        u.skip(.engine)
        check(u.doneCount == 1 && !u.settled,
              "T-BOOT ④ 进度条只数 done，且还有 pending 就不算到齐（实测 1 / 未 settled）")

        // ⑤ settled 认 skipped（否则没装 pi 的机器这一屏永远等不到收场，只能等 4 秒上限）
        for s in BootTrace.Step.allCases where s != .engine && s != .model { u.finish(s, n: 0) }
        check(u.settled && u.doneCount == 4,
              "T-BOOT ⑤ 五行的结论都到齐（含 skipped）⇒ 收场；而 skipped 仍不算进分母")

        // ⑥ 真接线：init 里那四行真的写了
        let dir = fixtureDir("p20boot")
        let store = ChatStore(transport: MockTransport(), dbPath: dir + "/boot.db",
                              managedExtensionsDir: dir + "/ext")
        store.scheduler.stopScheduler()

        let wired = [BootTrace.Step.workspace, .model, .assistants, .sessions]
            .filter { store.boot.phase($0) == .done }
        check(wired.count == 4,
              "T-BOOT ⑥ init 里那四行真的写了（工作区 / 凭据 / 助理 / 会话，实测 \(wired.count)/4）")
        check(store.boot.phase(.engine) == .done,
              "T-BOOT ⑥ 引擎进程: 探测实例答了话就打勾（Mock 在 refreshCapabilities 里同步答）")
        check(store.boot.number(.workspace) == store.projects.count,
              "T-BOOT ⑥ 读数是量出来的: 工作区那格 = 真的项目数")
    }
}

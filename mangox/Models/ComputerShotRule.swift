//
//  ComputerShotRule.swift
//  MangoX (P18 批 3c): 图像面的**判据**, 与"真去拍一张"分开住。
//
//  ⚠️ 为什么不分在 `mangox-compute/ComputerShot.swift` 里: 本仓的冒烟只编译 `mangox/` 下的
//     源码(`run.sh` 的 `SRC=$(find mangox …)`), helper 目录进不去 ⇒ 判据若住在那里,
//     **一条都断言不了**。而同目录下的 `ComputerAct` / `ComputerTakeover` 早就为此搬过来了,
//     形态一致: 判据在 `mangox/Models/`, IO 在 helper 壳里。
//
//  ⚠️ **图像不涂黑**(2026-10-30 boss 定, 推翻了本批最初设计)。理由两条:
//     ① 密码框本来就渲染成圆点 ⇒ 像素里没有明文, 黑块只多遮了"密码长度", 收益近乎为零;
//     ② 黑块一旦**遮错**(判据放宽、几何两套坐标系不同源、一个受保护容器框住整片),
//        代价是整张图**直接失去价值** —— 而遮错的东西长得和遮对的一模一样, 零报错。
//     结论: 遮蔽只留在**文本层**(`ComputerRedline.maskedValue`), 那里是"整格换成 `••••`",
//     粒度是元素而不是像素, 遮错最多丢一个值、丢不掉整张图。
//
//  ⚠️ 残余风险(明确记在这里, 不假装不存在): **用户自己把秘密显示在屏幕上**(终端里的 token、
//     笔记里的验证码、助记词、卡号)在图里就是明明白白。这条谁也遮不住 —— 判据认不出"这段
//     文字是不是秘密"。唯一的防线是"图像面默认关、按 App 逐个勾"(见 `allowed`)。
//

import Foundation

enum ComputerShotRule {

    /// 允许截图的 App 名单。⚠️ 与 App 侧 `ComputerHost.imageBundlesEnvKey` **必须是同一个
    /// 字符串**(跨 target 契约, `run.sh` ③t 扫着)。
    ///
    /// **空串 / 缺键 = 一张都不拍** —— 与 `MANGOX_COMPUTE_TAKEOVER` 的"要就写 1"不同:
    /// 这里键**恒设**, 只是值可能为空。区别在于缺键会让 helper 以为"这一版 App 根本没有
    /// 图像功能", 于是把用户明确关掉的事说成"不支持"。
    static let envKey = "MANGOX_COMPUTE_IMAGE_BUNDLES"

    /// 截图失败的原因 —— **人话**, 由调用方原样回给模型。
    ///
    /// ⚠️ 单独一个类型而不是直接 `Result<_, String>`: `Result` 的 Failure 必须符合 `Error`,
    ///    而 `String` 不是。两个 `init` 都是为了让调用点少写样板 —— 注意 `ExpressibleByStringLiteral`
    ///    **只对裸字面量生效**, `"a" + "b"` 这种拼接结果仍然是 `String`(实测: 不转换)。
    struct ShotFailure: Error, ExpressibleByStringLiteral {
        let message: String
        init(stringLiteral value: String) { message = value }
        init(_ message: String) { self.message = message }
    }

    /// 这个 App 在不在名单里。**不做任何模糊匹配**: 只认完整 bundle id。
    static func allowed(bundle: String, raw: String?) -> Bool {
        guard let raw, !raw.isEmpty else { return false }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains(bundle)
    }

    /// 把窗口逻辑尺寸算成截图尺寸。
    ///
    /// **1 倍**而不是 2 倍: 图是"看一眼长什么样"的兜底, 不是给人看的成品; 2 倍会让 PNG
    /// 体积翻四倍, 而这些字节要作为 `ImageContent` 进模型的上下文 —— 省下来的额度更有用。
    ///
    /// ⚠️ **再叠一道长边上限**(2026-11-11 补): 1 倍只是去掉"Retina 那 4 倍", 窗口本身多大
    ///    它还是多大 —— 6K 上满窗就是 3008×1692, 一个贴满缩略图的窗口编出来能顶到模型侧
    ///    的单图上限。上限卡在**交给 SCK 的 `config.width/height`** 上, 不在拿到图之后重绘:
    ///    少一次全画布拷贝, 也少一处"画布建不出来"的失败分支(`encode` 至今只编码)。
    static func captureSize(window: AXRect) -> (width: Int, height: Int) {
        fit(width: max(1, window.w), height: max(1, window.h))
    }

    /// 交给模型的图,**长边硬上限**(像素)。
    ///
    /// ⚠️ 与 App 侧 `ImagePipeline.maxSendSide` **是同一个数**: 用户发的图和截图最后进的是
    ///    同一个上下文, 上限不该有两份。但两个 target 编不到一起去(`mangox-compute` 里没有
    ///    `ImagePipeline`), 只能靠 `run.sh` 的源码事实锁住"这两处写的是同一个数"。
    static let maxEdge = 1536

    /// 等比缩进一个 `maxEdge` 的正方形框。**只缩不放** —— 装得下就原样返回。
    ///
    /// 长边取**正好** `maxEdge`(不是四舍五入的结果), 短边按同一比例算: 四边各自取整会让
    /// 宽高比飘一点点, 而 SCK 是按比例把画面塞进这个尺寸的 —— 飘了就是**非等比拉伸**
    /// (`capture` 上面那段注释记着这个坑)。
    static func fit(width: Int, height: Int,
                    maxEdge: Int = ComputerShotRule.maxEdge) -> (width: Int, height: Int) {
        let w = max(1, width), h = max(1, height)
        guard maxEdge > 0, max(w, h) > maxEdge else { return (w, h) }
        if w >= h {
            let nh = Int((Double(h) * Double(maxEdge) / Double(w)).rounded())
            return (maxEdge, max(1, nh))
        }
        let nw = Int((Double(w) * Double(maxEdge) / Double(h)).rounded())
        return (max(1, nw), maxEdge)
    }
}

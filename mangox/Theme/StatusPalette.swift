//
//  StatusPalette.swift
//  Centralized status → color mapping.
//

import SwiftUI

enum ToolPhase: Hashable, Codable {
    case queued
    case running
    case done
    case awaitingApproval   // waiting for the user to allow / deny
    case error(String)

    var color: Color {
        switch self {
        case .queued:          return CodexTheme.toolQueued
        case .running:         return CodexTheme.toolRunning
        case .done:            return CodexTheme.toolDone
        case .awaitingApproval: return CodexTheme.toolError
        case .error:           return CodexTheme.toolError
        }
    }

    var label: String {
        switch self {
        case .queued:           return L("等待")
        case .running:          return L("运行中")
        case .done:             return L("完成")
        case .awaitingApproval: return L("待审批")
        case .error:            return L("错误")
        }
    }
}

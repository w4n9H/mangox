//
//  PlanQuestion.swift
//

import Foundation

struct PlanOption: Identifiable, Hashable, Codable {
    let id: UUID
    let label: String
    let detail: String?
    let isRecommended: Bool

    init(id: UUID = UUID(), label: String, detail: String? = nil, isRecommended: Bool = false) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isRecommended = isRecommended
    }
}

struct PlanQuestion: Identifiable, Hashable, Codable {
    let id: UUID
    let title: String
    let body: String?
    let options: [PlanOption]
    let allowsCustom: Bool

    init(id: UUID = UUID(),
         title: String,
         body: String? = nil,
         options: [PlanOption],
         allowsCustom: Bool = true) {
        self.id = id
        self.title = title
        self.body = body
        self.options = options
        self.allowsCustom = allowsCustom
    }
}

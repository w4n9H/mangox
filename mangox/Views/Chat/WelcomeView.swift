//
//  WelcomeView.swift
//  Empty-conversation state: single mark + one question (Codex minimalism).
//

import SwiftUI

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: Tune.welcomeStackSpacing) {
            Text(Copy.welcomeMark)
                .font(.system(size: Tune.welcomeMarkSize, weight: .regular))
                .foregroundStyle(CodexTheme.textTertiary)
            Text(Copy.welcomeQuestion)
                .font(.system(size: Tune.welcomeQuestionSize, weight: .medium))
                .foregroundStyle(CodexTheme.textPrimary)
        }
    }
}

//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import SwiftUI

/// Reusable stat display box showing a label, value, and optional unit
struct StatBox: View {
    let label: String
    let value: String
    var unit: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.bold))
                if let unit = unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

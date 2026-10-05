import SwiftUI

/// Time-of-day aware hero greeting with recovery ring and live context.
struct TimeOfDayHero: View {
    let recoveryScore: Double
    let recoveryLabel: String
    let bodyBattery: Double
    let cognitiveLabel: String
    let timeSegment: TimeSegment

    enum TimeSegment {
        case morning, midday, evening, windDown

        var greeting: String {
            switch self {
            case .morning:   return "Guten Morgen, Fabi"
            case .midday:    return "Guten Mittag, Fabi"
            case .evening:   return "Guten Abend, Fabi"
            case .windDown:  return "Abend, Fabi"
            }
        }

        var icon: String {
            switch self {
            case .morning:   return "sunrise.fill"
            case .midday:    return "sun.max.fill"
            case .evening:   return "sunset.fill"
            case .windDown:  return "moon.stars.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .morning:   return DS.Colors.amber
            case .midday:    return DS.Colors.secondaryLabel
            case .evening:   return DS.Colors.pink.opacity(0.8)
            case .windDown:  return DS.Colors.violet.opacity(0.8)
            }
        }

        static func current() -> TimeSegment {
            let h = Calendar.current.component(.hour, from: Date())
            switch h {
            case 5..<12:  return .morning
            case 12..<17: return .midday
            case 17..<21: return .evening
            default:      return .windDown
            }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.lg) {
            // Ring left
            VStack(spacing: DS.Spacing.xs) {
                RecoveryRingHero(
                    score: recoveryScore,
                    label: recoveryLabel,
                    size: 110,
                    lineWidth: 11
                )

                // Body battery pill under ring
                if bodyBattery > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(DS.Colors.bodyBatteryColor(bodyBattery))
                        Text("\(Int(bodyBattery))")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.Colors.bodyBatteryColor(bodyBattery))
                            .monospacedDigit()
                        Text("BB")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(DS.Colors.textFaint)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DS.Colors.surfaceElevated))
                }
            }

            // Right side: greeting + context
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Label(timeSegment.greeting, systemImage: timeSegment.icon)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .labelStyle(.titleAndIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(timeSegment.iconColor, DS.Colors.textPrimary)

                if cognitiveLabel != "—" && !cognitiveLabel.isEmpty {
                    Label(cognitiveLabel, systemImage: "brain")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.violet)
                }

                let readinessText = recoveryScore > 66 ? "Bereit zum Pushen"
                    : recoveryScore > 33 ? "Moderat belasten"
                    : recoveryScore > 0  ? "Erholung priorisieren"
                    : "Warte auf Daten"
                Text(readinessText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.lg)
        .heroCard()
    }
}

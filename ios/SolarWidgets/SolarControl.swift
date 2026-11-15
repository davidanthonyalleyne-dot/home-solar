import WidgetKit
import SwiftUI
import AppIntents

// The Control Center control (iOS 18 and later): the sun and the live kW; in the larger sizes,
// today's total too. Tapping it opens Solar. It can also go on the Lock Screen or the Action button.

@available(iOS 18.0, *)
struct SolarControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ca.davidalleyne.solar.control", provider: Provider()) { v in
            ControlWidgetButton(action: OpenSolarIntent()) {
                Label {
                    Text(v.now)
                    Text(v.today)
                } icon: {
                    Image(systemName: "sun.max.fill")
                }
            }
            .tint(SK.sunColor)
        }
        .displayName("Solar")
        .description("What the panels are making now. Opens Solar.")
    }

    struct Value { var now: String; var today: String }

    struct Provider: ControlValueProvider {
        var previewValue: Value { Value(now: "1.8 kW", today: "9.6 kWh today") }
        func currentValue() async throws -> Value {
            guard let s = await Snapshot.build() ?? Snapshot.cached() else { return Value(now: "Solar", today: "Open to unlock") }
            s.cache()
            return Value(now: "\(String(format: "%.1f", s.nowKw)) kW", today: "\(SK.kwh(s.todayKwh)) kWh today")
        }
    }
}

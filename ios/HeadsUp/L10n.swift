import Foundation
import SwiftUI

/// Lightweight in-app localization. The user picks 中文 / English in Settings;
/// the choice is stored in @AppStorage and views observe it via @Environment.
enum AppLanguage: String, CaseIterable {
    case zh, en

    var label: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

final class Localizer: ObservableObject {
    static let shared = Localizer()
    @Published var lang: AppLanguage

    private init() {
        let saved = UserDefaults.standard.string(forKey: "headsup.language")
        if let saved, let l = AppLanguage(rawValue: saved) {
            self.lang = l
        } else {
            // Default to system language if it starts with zh, else en
            let pref = Locale.preferredLanguages.first?.lowercased() ?? "en"
            self.lang = pref.hasPrefix("zh") ? .zh : .en
        }
    }

    func set(_ lang: AppLanguage) {
        self.lang = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "headsup.language")
    }

    func t(_ zh: String, _ en: String) -> String {
        lang == .zh ? zh : en
    }
}

/// String lookup helper. Usage: T("中文", "English")
func T(_ zh: String, _ en: String) -> String {
    Localizer.shared.t(zh, en)
}

/// SwiftUI-friendly: localized text that re-renders on language change.
struct LText: View {
    @ObservedObject private var loc = Localizer.shared
    let zh: String
    let en: String
    init(_ zh: String, _ en: String) { self.zh = zh; self.en = en }
    var body: some View {
        Text(loc.lang == .zh ? zh : en)
    }
}

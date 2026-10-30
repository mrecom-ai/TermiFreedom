import Foundation

enum RunMode {
    static var uiPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-smoke-test") || Bundle.main.object(forInfoDictionaryKey: "TermiFreedomPreviewMode") as? Bool == true
    }
}

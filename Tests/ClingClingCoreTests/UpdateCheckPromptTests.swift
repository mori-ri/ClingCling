import Foundation
import Testing
@testable import ClingClingCore

struct UpdateCheckPromptTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "UpdateCheckPromptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func asksOnceOnTheSecondLaunch() {
        withDefaults { defaults in
            let prompt = UpdateCheckPrompt(defaults: defaults)
            #expect(!prompt.registerLaunch())
            #expect(prompt.registerLaunch())
            #expect(prompt.hasAsked)
            #expect(!prompt.registerLaunch())
            #expect(!prompt.registerLaunch())
        }
    }

    @Test func choosingInSettingsFirstMeansNoQuestion() {
        withDefaults { defaults in
            let prompt = UpdateCheckPrompt(defaults: defaults)
            #expect(!prompt.registerLaunch())
            prompt.markAsked()
            #expect(!prompt.registerLaunch())
        }
    }
}

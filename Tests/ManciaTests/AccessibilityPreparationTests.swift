import Testing
@testable import Mancia

@Suite("Explicit capture Accessibility preparation")
@MainActor
struct AccessibilityPreparationTests {
    @Test("Explicit capture initializes delayed assistive access without automatic monitoring")
    func delayedPreparation() async throws {
        var preparations = 0
        var validations = 0
        var waits = 0
        let failure = try await SelectionCapture.waitForAccessibilityPreparation(
            prepare: {
                preparations += 1
                return preparations == 11
            },
            validate: {
                validations += 1
                return nil
            },
            wait: { waits += 1 })
        #expect(failure == nil)
        #expect(preparations == 11)
        #expect(validations == 11)
        #expect(waits == 10)
    }

    @Test("Ready or native applications do not wait")
    func readyApplication() async throws {
        var waits = 0
        let failure = try await SelectionCapture.waitForAccessibilityPreparation(
            prepare: { true }, validate: { nil }, wait: { waits += 1 })
        #expect(failure == nil)
        #expect(waits == 0)
    }

    @Test("Changed applications and revoked permissions abort before another preparation",
          arguments: [
              SelectionCaptureFailure.targetNotFrontmost,
              .targetTerminated,
              .accessibilityPermissionRevoked,
          ])
    func changedTarget(expected: SelectionCaptureFailure) async throws {
        var preparations = 0
        var targetFailure: SelectionCaptureFailure?
        let failure = try await SelectionCapture.waitForAccessibilityPreparation(
            prepare: { preparations += 1; return false },
            validate: { targetFailure },
            wait: { targetFailure = expected })
        #expect(failure == expected)
        #expect(preparations == 1)
    }

    @Test("Initialization cannot wait indefinitely or pretend to be ready")
    func boundedPreparation() async throws {
        var preparations = 0
        var waits = 0
        let failure = try await SelectionCapture.waitForAccessibilityPreparation(
            prepare: { preparations += 1; return false },
            validate: { nil },
            wait: { waits += 1 })
        #expect(failure == .accessibilityNotReady)
        #expect(preparations == 12)
        #expect(waits == 11)
    }

    @Test("Cancellation stops initialization before copying")
    func cancelledPreparation() async {
        var preparations = 0
        do {
            _ = try await SelectionCapture.waitForAccessibilityPreparation(
                prepare: { preparations += 1; return false },
                validate: { nil },
                wait: { throw CancellationError() })
            Issue.record("Cancelled initialization must throw")
        } catch is CancellationError {
            #expect(preparations == 1)
        } catch {
            Issue.record("Unexpected initialization error: \(error)")
        }
    }
}

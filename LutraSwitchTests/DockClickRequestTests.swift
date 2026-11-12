import Dispatch
import Testing

struct DockClickRequestTests {
    @Test func expiredRequestCannotPrepareOrApply() {
        let request = DockClickRequest(deadline: .now())

        #expect(!request.canPrepare)
        #expect(!request.beginApplying())
        #expect(request.claimFallback())
        #expect(!request.claimFallback(afterCompletion: true))
    }

    @Test func forwardingPreventsLateWindowChanges() {
        let request = DockClickRequest(deadline: .distantFuture)

        #expect(request.canPrepare)
        #expect(request.claimFallback())
        #expect(!request.canPrepare)
        #expect(!request.beginApplying())
        #expect(!request.claimFallback(afterCompletion: true))
    }

    @Test func applyingCanOnlyForwardAfterAnUnsuccessfulCompletion() {
        let request = DockClickRequest(deadline: .distantFuture)

        #expect(request.beginApplying())
        #expect(!request.claimFallback())
        #expect(request.claimFallback(afterCompletion: true))
        #expect(!request.claimFallback(afterCompletion: true))
    }
}

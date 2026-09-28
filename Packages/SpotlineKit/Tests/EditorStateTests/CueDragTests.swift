import SubtitleCore
import Testing
@testable import EditorUI

struct CueDragTests {
    let rate = FrameRate.fps25
    func f(_ n: Int64) -> MediaTime { MediaTime(frame: n, rate: rate) }
    var noSnap: MediaTime { .zero }

    @Test func trimsInWholeFrames() {
        let drag = CueDrag(part: .inPoint, start: f(10), end: f(20), rate: rate)
        #expect(drag.timing(movedBy: 3, snapTargets: [], tolerance: noSnap) == (f(13), f(20)))
        #expect(drag.timing(movedBy: -30, snapTargets: [], tolerance: noSnap) == (.zero, f(20)))
        // At least one frame long.
        #expect(drag.timing(movedBy: 50, snapTargets: [], tolerance: noSnap) == (f(19), f(20)))
    }

    @Test func trimsOut() {
        let drag = CueDrag(part: .outPoint, start: f(10), end: f(20), rate: rate)
        #expect(drag.timing(movedBy: 5, snapTargets: [], tolerance: noSnap) == (f(10), f(25)))
        #expect(drag.timing(movedBy: -50, snapTargets: [], tolerance: noSnap) == (f(10), f(11)))
    }

    @Test func movesKeepingDuration() {
        let drag = CueDrag(part: .body, start: f(10), end: f(20), rate: rate)
        #expect(drag.timing(movedBy: 7, snapTargets: [], tolerance: noSnap) == (f(17), f(27)))
        #expect(drag.timing(movedBy: -40, snapTargets: [], tolerance: noSnap) == (.zero, f(10)))
    }

    @Test func snapsToTheNearestTargetInRange() {
        let drag = CueDrag(part: .inPoint, start: f(10), end: f(40), rate: rate)
        let targets = [f(15), f(18)]
        #expect(drag.timing(movedBy: 6, snapTargets: targets, tolerance: f(2)) == (f(15), f(40)))
        #expect(drag.timing(movedBy: 7, snapTargets: targets, tolerance: f(2)) == (f(18), f(40)))
        #expect(drag.timing(movedBy: 2, snapTargets: targets, tolerance: f(2)) == (f(12), f(40)))
    }

    @Test func snapsExactlyToOffFrameCueEdges() {
        // Another cue ends at 1.01 s, between frames 25 and 26.
        let edge = MediaTime(value: 101, timescale: 100)
        let drag = CueDrag(part: .inPoint, start: f(10), end: f(40), rate: rate)
        #expect(drag.timing(movedBy: 15, snapTargets: [edge], tolerance: f(2)).start == edge)
    }

    @Test func movingSnapsEitherEdge() {
        let drag = CueDrag(part: .body, start: f(10), end: f(20), rate: rate)
        // End lands at 31, one frame from the target at 30.
        #expect(drag.timing(movedBy: 11, snapTargets: [f(30)], tolerance: f(2)) == (f(20), f(30)))
        // Start lands at 19, one frame from the target at 20.
        #expect(drag.timing(movedBy: 9, snapTargets: [f(20)], tolerance: f(2)) == (f(20), f(30)))
    }
}

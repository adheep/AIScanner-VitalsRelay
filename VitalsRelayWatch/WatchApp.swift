import Combine
import HealthKit
import SwiftUI

@main
struct VitalsRelayWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(model)
        }
    }
}

/// Ties the workout session to the phone link.
///
/// The session can be started from either end: the phone sends "start" when you
/// tap Start there, and the button here does the same thing locally for when
/// the phone is not to hand.
@MainActor
final class WatchModel: ObservableObject {
    let workout = WorkoutSessionManager()
    let link = WatchLink()

    @Published private(set) var isRunning = false
    private var bag = Set<AnyCancellable>()

    init() {
        // A nested ObservableObject does not notify its parent's observers, and
        // the view reads heart rate straight off `workout`. Without these the
        // number on screen never changes.
        workout.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        link.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)

        workout.onSample = { [weak self] samples in
            self?.link.enqueue(samples)
        }
        link.onCommand = { [weak self] command in
            Task { @MainActor in
                switch command {
                case "start": await self?.start()
                case "stop":  await self?.stop()
                default:      break
                }
            }
        }
        link.activate()
    }

    func start() async {
        await workout.start()
        isRunning = workout.isRunning
    }

    func stop() async {
        await workout.stop()
        isRunning = false
    }

    func toggle() async {
        isRunning ? await stop() : await start()
    }
}

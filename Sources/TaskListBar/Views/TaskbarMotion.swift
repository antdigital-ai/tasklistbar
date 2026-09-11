import AppKit
import QuartzCore
import SwiftUI

enum TaskbarMotion {
    static let panelSpring = fluid(0.36)
    static let panelAppear = fluid(0.34)
    static let calendarExpand = Animation.timingCurve(0.16, 1.0, 0.28, 1.0, duration: 0.44)
    static let calendarPage = Animation.timingCurve(0.22, 0.92, 0.18, 1.0, duration: 0.36)
    static let calendarDay = Animation.spring(response: 0.34, dampingFraction: 0.78)
    static let calendarAgenda = Animation.timingCurve(0.18, 1.0, 0.28, 1.0, duration: 0.36)
    static let contentPush = fluid(0.32)
    static let contentPop = fluid(0.28)
    static let hover = fluid(0.12)
    static let press = fluid(0.08)
    static let indicator = fluid(0.16)
    static let list = fluid(0.22)
    static let sizeChange = fluid(0.28)

    private static func fluid(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.22, 1.0, 0.36, 1.0, duration: duration)
    }

    static func pushTransition(forward: Bool) -> AnyTransition {
        calendarPageTransition(forward: forward)
    }

    static func calendarPageTransition(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
            removal: .offset(x: forward ? -28 : 28).combined(with: .opacity)
        )
    }

    static func calendarAgendaTransition() -> AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 22))
                .combined(with: .scale(scale: 0.96, anchor: .bottom)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
        )
    }

    static func staggerDelay(index: Int, step: Double = 0.022, cap: Double = 0.22) -> Double {
        min(Double(index) * step, cap)
    }

    enum Panel {
        static let showDuration: TimeInterval = 0.14
        static let startMenuShowDuration: TimeInterval = 0.16
        static let startMenuHideDuration: TimeInterval = 0.12
        static let startMenuFadeBegin: Double = 0.2
        static let hideDuration: TimeInterval = 0.10
        static let resizeDuration: TimeInterval = 0.44
        static let calendarShowDuration: TimeInterval = 0.22
        static let calendarHideDuration: TimeInterval = 0.14
        static let calendarFromScale: CGFloat = 0.96
        static let startMenuRise: CGFloat = 12
        static let startMenuFromScale: CGFloat = 0.94
        static let flyoutRise: CGFloat = 12

        static var showTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.20, 0.70, 0.15, 1.0)
        }

        static var startMenuTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(name: .easeInEaseOut)
        }

        static var startMenuHideTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
        }

        static var startMenuFadeTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.55, 0.0, 1.0, 1.0)
        }

        /// Reverse of `showTiming` so close is the same fade played backwards.
        static var hideTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.85, 0.0, 0.80, 0.30)
        }

        static var resizeTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
        }
    }
}

struct PressableScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        let _ = pressedScale
        Group {
            if #available(macOS 15.0, *) {
                configuration.label
                    .opacity(configuration.isPressed ? 0.78 : 1)
                    .animation(TaskbarMotion.press, value: configuration.isPressed)
                    .pointerStyle(.default)
            } else {
                configuration.label
                    .opacity(configuration.isPressed ? 0.78 : 1)
                    .animation(TaskbarMotion.press, value: configuration.isPressed)
            }
        }
    }
}

struct AppearStagger: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                withAnimation(TaskbarMotion.panelSpring.delay(TaskbarMotion.staggerDelay(index: index))) {
                    shown = true
                }
            }
    }
}

extension View {
    func appearStaggered(_ index: Int) -> some View {
        modifier(AppearStagger(index: index))
    }
}

struct TaskbarPointerLock: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.default)
        } else {
            content
        }
    }
}

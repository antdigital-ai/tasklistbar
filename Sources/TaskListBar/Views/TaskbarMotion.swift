import AppKit
import QuartzCore
import SwiftUI

enum TaskbarMotion {
    static let panelSpring = fluid(0.36)
    static let panelAppear = fluid(0.34)
    static let calendarExpand = fluid(0.38)
    static let calendarAgenda = fluid(0.32)
    static let contentPush = fluid(0.32)
    static let contentPop = fluid(0.28)
    static let hover = fluid(0.18)
    static let press = fluid(0.12)
    static let indicator = fluid(0.22)
    static let list = fluid(0.30)

    private static func fluid(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.22, 1.0, 0.36, 1.0, duration: duration)
    }

    static func pushTransition(forward: Bool) -> AnyTransition {
        let incoming: CGFloat = forward ? 22 : -22
        let outgoing: CGFloat = forward ? -16 : 16
        return .asymmetric(
            insertion: .offset(x: incoming).combined(with: .opacity),
            removal: .offset(x: outgoing).combined(with: .opacity)
        )
    }

    static func staggerDelay(index: Int, step: Double = 0.022, cap: Double = 0.22) -> Double {
        min(Double(index) * step, cap)
    }

    enum Panel {
        static let showDuration: TimeInterval = 0.14
        static let startMenuShowDuration: TimeInterval = 0.28
        static let startMenuHideDuration: TimeInterval = 0.32
        static let startMenuFadeBegin: Double = 0.4
        static let hideDuration: TimeInterval = 0.14
        static let resizeDuration: TimeInterval = 0.34
        static let startMenuRise: CGFloat = 12
        static let startMenuFromScale: CGFloat = 0.18
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
    var idleScale: CGFloat = 1
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(macOS 15.0, *) {
                configuration.label
                    .scaleEffect(configuration.isPressed ? pressedScale : idleScale)
                    .animation(TaskbarMotion.press, value: configuration.isPressed)
                    .pointerStyle(.default)
            } else {
                configuration.label
                    .scaleEffect(configuration.isPressed ? pressedScale : idleScale)
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

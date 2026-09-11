import SwiftUI

/// Soft weather wash behind the calendar. One glow and a few drifting marks.
struct WeatherAtmosphereView: View {
    let kind: WeatherKind
    let isNight: Bool
    var isActive: Bool = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: isActive ? 0.7 : 60)) { timeline in
            Canvas { context, size in
                guard isActive, size.width > 2, size.height > 2 else { return }
                let t = timeline.date.timeIntervalSinceReferenceDate
                drawGlow(context: context, size: size, time: t)
                switch kind {
                case .sunny:
                    break
                case .partlyCloudy, .cloudy, .fog:
                    drawClouds(context: context, size: size, time: t, count: kind == .fog ? 2 : 1)
                case .drizzle:
                    drawDrops(context: context, size: size, time: t, count: 8, speed: 90, length: 8)
                case .rain, .storm:
                    drawDrops(context: context, size: size, time: t, count: 12, speed: 140, length: 12)
                case .snow:
                    drawFlakes(context: context, size: size, time: t)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawGlow(context: GraphicsContext, size: CGSize, time: Double) {
        let origin = CGPoint(x: 54, y: isNight ? 68 : 56)
        let pulse = 0.94 + 0.06 * sin(time * 0.35)
        let radius: CGFloat = isNight ? 56 : 78
        var glow = context
        glow.clip(to: Path(CGRect(x: 0, y: 0, width: min(170, size.width * 0.4), height: size.height)))
        glow.addFilter(.blur(radius: 20))
        glow.opacity = (isNight ? 0.32 : 0.55) * pulse
        let colors: [Color] = isNight
            ? [Color(red: 0.86, green: 0.9, blue: 1), Color.clear]
            : [Color(red: 1, green: 0.92, blue: 0.62), Color(red: 1, green: 0.72, blue: 0.28).opacity(0.2), Color.clear]
        glow.fill(
            Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(Gradient(colors: colors), center: origin, startRadius: 4, endRadius: radius)
        )
    }

    private func drawClouds(context: GraphicsContext, size: CGSize, time: Double, count: Int) {
        var clouds = context
        clouds.addFilter(.blur(radius: 16))
        for index in 0..<count {
            let travel = Double(size.width) + 160
            let x = wrap(time * (7 + Double(index) * 3) + Double(index) * 80, travel) - 80
            let y = 10 + CGFloat(index) * 28
            clouds.opacity = kind == .fog ? 0.22 : 0.18
            clouds.fill(
                Path(ellipseIn: CGRect(x: x, y: Double(y), width: Double(size.width) * 0.55, height: 36)),
                with: .color(.white)
            )
        }
    }

    private func drawDrops(context: GraphicsContext, size: CGSize, time: Double, count: Int, speed: Double, length: CGFloat) {
        let cycle = Double(size.height) + 24
        for index in 0..<count {
            let x = 12 + unit(index, 1.4) * Double(size.width - 24)
            let y = wrap(time * speed + unit(index, 2.2) * cycle, cycle) - Double(length)
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + 2, y: y + Double(length)))
            var rain = context
            rain.opacity = 0.35
            rain.stroke(path, with: .color(Color.white), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }
    }

    private func drawFlakes(context: GraphicsContext, size: CGSize, time: Double) {
        let cycle = Double(size.height) + 16
        for index in 0..<8 {
            let x = unit(index, 1.1) * Double(size.width) + sin(time * 0.4 + Double(index)) * 6
            let y = wrap(time * 22 + unit(index, 2.6) * cycle, cycle) - 8
            var flake = context
            flake.opacity = 0.55
            flake.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.4, height: 2.4)), with: .color(.white))
        }
    }

    private func unit(_ index: Int, _ salt: Double) -> Double {
        let value = sin(Double(index + 1) * 127.1 + salt * 311.7) * 43758.5453
        return value - floor(value)
    }

    private func wrap(_ value: Double, _ period: Double) -> Double {
        guard period > 0 else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }
}

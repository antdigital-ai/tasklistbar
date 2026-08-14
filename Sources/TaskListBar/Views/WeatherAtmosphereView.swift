import SwiftUI

/// Apple Weather–style atmosphere. Only ticks while the calendar is visible.
struct WeatherAtmosphereView: View {
    let kind: WeatherKind
    let isNight: Bool
    var isActive: Bool = true

    @State private var time = Date().timeIntervalSinceReferenceDate

    var body: some View {
        Canvas { context, size in
            guard isActive, size.width > 2, size.height > 2 else { return }
            switch kind {
            case .sunny:
                if isNight {
                    drawStars(context: context, size: size, time: time, count: 32)
                    drawMoon(context: context, size: size, time: time)
                } else {
                    drawSunshine(context: context, size: size, time: time)
                    drawLightMotes(context: context, size: size, time: time)
                }
            case .partlyCloudy:
                if isNight {
                    drawStars(context: context, size: size, time: time, count: 18)
                    drawMoon(context: context, size: size, time: time, intensity: 0.55)
                } else {
                    drawSunshine(context: context, size: size, time: time, intensity: 0.7)
                }
                drawCloudField(context: context, size: size, time: time, layers: 2, density: 3, opacity: 0.5)
            case .cloudy:
                drawCloudField(context: context, size: size, time: time, layers: 2, density: 4, opacity: 0.55)
            case .fog:
                drawFog(context: context, size: size, time: time)
            case .drizzle:
                drawCloudField(context: context, size: size, time: time, layers: 1, density: 2, opacity: 0.28)
                drawRain(context: context, size: size, time: time, far: 28, near: 16, speed: 180, length: 12, slant: 0.12)
            case .rain:
                drawCloudField(context: context, size: size, time: time, layers: 1, density: 2, opacity: 0.28)
                drawRain(context: context, size: size, time: time, far: 48, near: 28, speed: 280, length: 20, slant: 0.2)
            case .snow:
                drawCloudField(context: context, size: size, time: time, layers: 1, density: 2, opacity: 0.22)
                drawSnow(context: context, size: size, time: time)
            case .storm:
                drawCloudField(context: context, size: size, time: time, layers: 2, density: 3, opacity: 0.32)
                drawRain(context: context, size: size, time: time, far: 56, near: 36, speed: 340, length: 22, slant: 0.26)
                drawLightning(context: context, size: size, time: time)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                time = Date().timeIntervalSinceReferenceDate
            }
        }
    }

    // MARK: - Sun

    private func drawSunshine(context: GraphicsContext, size: CGSize, time: Double, intensity: Double = 1) {
        var context = context
        context.clip(to: Path(CGRect(x: 0, y: 0, width: min(168, size.width * 0.42), height: size.height)))
        let origin = CGPoint(x: 56, y: 58)
        let breathe = 0.86 + 0.14 * sin(time * 0.85)

        var halo = context
        halo.addFilter(.blur(radius: 18))
        halo.opacity = 0.95 * intensity * breathe
        let haloR: CGFloat = 110
        halo.fill(
            Path(ellipseIn: CGRect(x: origin.x - haloR, y: origin.y - haloR, width: haloR * 2, height: haloR * 2)),
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 1, green: 0.93, blue: 0.62),
                    Color(red: 1, green: 0.78, blue: 0.28).opacity(0.45),
                    Color(red: 1, green: 0.62, blue: 0.18).opacity(0.12),
                    Color.clear
                ]),
                center: origin,
                startRadius: 6,
                endRadius: haloR
            )
        )

        var shafts = context
        shafts.addFilter(.blur(radius: 4))
        let rotation = time * 0.22
        let rayCount = 12
        for index in 0..<rayCount {
            let angle = rotation + Double(index) * (.pi * 2 / Double(rayCount))
            let spread = index.isMultiple(of: 2) ? 0.13 : 0.06
            let outer: CGFloat = 130 * CGFloat(intensity)
            var path = Path()
            path.move(to: point(origin, angle - spread, 6))
            path.addLine(to: point(origin, angle, outer))
            path.addLine(to: point(origin, angle + spread, 6))
            path.closeSubpath()
            shafts.opacity = (index.isMultiple(of: 2) ? 0.38 : 0.22) * intensity * breathe
            shafts.fill(path, with: .color(Color(red: 1, green: 0.96, blue: 0.78)))
        }

        var core = context
        core.addFilter(.blur(radius: 3))
        core.opacity = 0.95 * intensity
        core.fill(
            Path(ellipseIn: CGRect(x: origin.x - 13, y: origin.y - 13, width: 26, height: 26)),
            with: .radialGradient(
                Gradient(colors: [
                    Color.white,
                    Color(red: 1, green: 0.94, blue: 0.62),
                    Color(red: 1, green: 0.8, blue: 0.3).opacity(0.2)
                ]),
                center: origin,
                startRadius: 0,
                endRadius: 13
            )
        )
    }

    private func drawLightMotes(context: GraphicsContext, size: CGSize, time: Double) {
        for index in 0..<8 {
            let orbit = 0.4 + unit(index, 1.2)
            let x = 40 + unit(index, 2.1) * 90 + sin(time * orbit * 0.35 + Double(index)) * 10
            let y = 20 + unit(index, 3.4) * 70 + cos(time * orbit * 0.28 + Double(index) * 0.7) * 8
            let r = 0.7 + unit(index, 4.5) * 1.6
            var mote = context
            mote.opacity = 0.45 + 0.4 * (0.5 + 0.5 * sin(time * 1.4 + Double(index)))
            mote.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                with: .color(Color(red: 1, green: 0.97, blue: 0.85))
            )
        }
    }

    // MARK: - Night

    private func drawMoon(context: GraphicsContext, size: CGSize, time: Double, intensity: Double = 1) {
        var context = context
        context.clip(to: Path(CGRect(x: 0, y: 0, width: min(168, size.width * 0.42), height: size.height)))
        let origin = CGPoint(x: 52, y: 72)
        let breathe = 0.9 + 0.1 * sin(time * 0.55)

        var halo = context
        halo.addFilter(.blur(radius: 22))
        halo.opacity = 0.5 * intensity * breathe
        let haloR: CGFloat = 70
        halo.fill(
            Path(ellipseIn: CGRect(x: origin.x - haloR, y: origin.y - haloR, width: haloR * 2, height: haloR * 2)),
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.92, green: 0.94, blue: 1),
                    Color(red: 0.7, green: 0.78, blue: 1).opacity(0.25),
                    Color.clear
                ]),
                center: origin,
                startRadius: 4,
                endRadius: haloR
            )
        )

        var disc = context
        disc.opacity = 0.92 * intensity
        disc.fill(
            Path(ellipseIn: CGRect(x: origin.x - 11, y: origin.y - 11, width: 22, height: 22)),
            with: .radialGradient(
                Gradient(colors: [
                    Color.white,
                    Color(red: 0.88, green: 0.9, blue: 0.98),
                    Color(red: 0.72, green: 0.76, blue: 0.9)
                ]),
                center: CGPoint(x: origin.x - 3, y: origin.y - 3),
                startRadius: 0,
                endRadius: 18
            )
        )
    }

    private func drawStars(context: GraphicsContext, size: CGSize, time: Double, count: Int) {
        for index in 0..<count {
            let x = unit(index, 1.1) * size.width
            let y = unit(index, 2.7) * size.height * 0.88
            let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(time * (0.7 + unit(index, 4.4) * 1.8) + Double(index)))
            let radius = 0.45 + unit(index, 3.3) * 1.15
            var star = context
            star.opacity = twinkle * (0.55 + unit(index, 5.1) * 0.45)
            star.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                with: .color(.white)
            )

            if unit(index, 8.2) > 0.78 {
                var spark = context
                spark.opacity = twinkle * 0.45
                let arm = radius * 3.2
                var cross = Path()
                cross.move(to: CGPoint(x: x + radius - arm, y: y + radius))
                cross.addLine(to: CGPoint(x: x + radius + arm, y: y + radius))
                cross.move(to: CGPoint(x: x + radius, y: y + radius - arm))
                cross.addLine(to: CGPoint(x: x + radius, y: y + radius + arm))
                spark.stroke(cross, with: .color(.white), style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
            }
        }
    }

    // MARK: - Clouds

    private func drawCloudField(
        context: GraphicsContext,
        size: CGSize,
        time: Double,
        layers: Int,
        density: Int,
        opacity: Double
    ) {
        for layer in 0..<layers {
            let layerSpeed = 16 + Double(layer) * 10
            let layerY = CGFloat(layer) * 18
            var clouds = context
            clouds.addFilter(.blur(radius: 8 + CGFloat(layer) * 2))
            for index in 0..<density {
                let seed = index + layer * 17
                let width = size.width * CGFloat(0.34 + unit(seed, 1.4) * 0.32)
                let height = 26 + unit(seed, 2.1) * 22
                let travel = Double(size.width) + Double(width) + 80
                let x = wrap(time * layerSpeed + unit(seed, 4.8) * travel, travel) - Double(width) - 40
                let y = 4 + layerY + unit(seed, 6.1) * (size.height * 0.28)
                clouds.opacity = opacity * (0.55 + 0.45 * unit(seed, 7.7)) * (layer == 0 ? 0.7 : 1)
                drawCloudShape(
                    context: clouds,
                    origin: CGPoint(x: x, y: Double(y)),
                    width: Double(width),
                    height: Double(height),
                    seed: seed
                )
            }
        }
    }

    private func drawCloudShape(
        context: GraphicsContext,
        origin: CGPoint,
        width: Double,
        height: Double,
        seed: Int
    ) {
        let blobs = [
            CGRect(x: origin.x, y: origin.y + height * 0.2, width: width * 0.62, height: height * 0.72),
            CGRect(x: origin.x + width * 0.28, y: origin.y, width: width * 0.48, height: height * 0.7),
            CGRect(x: origin.x + width * 0.5, y: origin.y + height * 0.18, width: width * 0.5, height: height * 0.68)
        ]
        for blob in blobs {
            context.fill(Path(ellipseIn: blob), with: .color(.white))
        }
        _ = seed
    }

    // MARK: - Fog

    private func drawFog(context: GraphicsContext, size: CGSize, time: Double) {
        var wash = context
        wash.opacity = 0.18
        wash.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.08), Color.white.opacity(0.3)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )

        var fog = context
        fog.addFilter(.blur(radius: 22))
        for index in 0..<6 {
            let height: CGFloat = 42 + CGFloat(index) * 4
            let speed = 12 + Double(index) * 5
            let travel = Double(size.width) + 220
            let x = wrap(time * speed + Double(index) * 70, travel) - 110
            let y = size.height * (0.08 + CGFloat(index) * 0.14) + CGFloat(sin(time * 0.25 + Double(index)) * 6)
            fog.opacity = 0.28 + Double(index) * 0.05
            fog.fill(
                Path(ellipseIn: CGRect(x: x, y: Double(y), width: Double(size.width) * 0.85, height: Double(height))),
                with: .color(.white)
            )
        }
    }

    // MARK: - Rain

    private func drawRain(
        context: GraphicsContext,
        size: CGSize,
        time: Double,
        far: Int,
        near: Int,
        speed: Double,
        length: CGFloat,
        slant: CGFloat
    ) {
        drawRainLayer(
            context: context,
            size: size,
            time: time,
            count: far,
            speed: speed * 0.62,
            length: length * 0.62,
            slant: slant * 0.8,
            opacity: 0.38,
            width: 1.15,
            salt: 1
        )
        drawRainLayer(
            context: context,
            size: size,
            time: time,
            count: near,
            speed: speed,
            length: length,
            slant: slant,
            opacity: 0.72,
            width: 1.9,
            salt: 2
        )
    }

    private func drawRainLayer(
        context: GraphicsContext,
        size: CGSize,
        time: Double,
        count: Int,
        speed: Double,
        length: CGFloat,
        slant: CGFloat,
        opacity: Double,
        width: Double,
        salt: Int
    ) {
        let cycle = Double(size.height) + Double(length) + 36
        for index in 0..<count {
            let x0 = unit(index, Double(salt) + 1.7) * Double(size.width + 50) - 25
            let offset = unit(index, Double(salt) + 2.9) * cycle
            let y = wrap(time * speed + offset, cycle) - Double(length)
            let dropLength = Double(length) * (0.65 + unit(index, Double(salt) + 3.6) * 0.7)
            let start = CGPoint(x: x0 + y * Double(slant), y: y)
            let end = CGPoint(x: start.x + dropLength * Double(slant), y: start.y + dropLength)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            var rain = context
            rain.opacity = opacity + unit(index, Double(salt) + 4.2) * opacity * 0.7
            rain.stroke(
                path,
                with: .color(Color(red: 0.84, green: 0.91, blue: 1)),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
        }
    }

    // MARK: - Snow

    private func drawSnow(context: GraphicsContext, size: CGSize, time: Double) {
        drawSnowLayer(context: context, size: size, time: time, count: 16, speed: 28, blur: false, salt: 1)
        drawSnowLayer(context: context, size: size, time: time, count: 24, speed: 48, blur: false, salt: 2)
    }

    private func drawSnowLayer(
        context: GraphicsContext,
        size: CGSize,
        time: Double,
        count: Int,
        speed: Double,
        blur: Bool,
        salt: Int
    ) {
        let cycle = Double(size.height) + 24
        for index in 0..<count {
            let baseX = unit(index, Double(salt) + 1.3) * Double(size.width)
            let fall = speed + unit(index, Double(salt) + 2.2) * speed * 0.8
            let y = wrap(time * fall + unit(index, Double(salt) + 3.1) * cycle, cycle) - 12
            let drift = sin(time * (0.45 + unit(index, Double(salt) + 4.4)) + Double(index)) * (10 + unit(index, 9.1) * 10)
            let radius = blur ? 2.2 + unit(index, 5.8) * 3.4 : 0.9 + unit(index, 5.8) * 1.8
            var flake = context
            if blur {
                flake.addFilter(.blur(radius: 2.4))
            }
            flake.opacity = blur ? 0.4 + unit(index, 6.6) * 0.25 : 0.7 + unit(index, 6.6) * 0.3
            flake.fill(
                Path(ellipseIn: CGRect(
                    x: baseX + drift,
                    y: y,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(.white)
            )
        }
    }

    // MARK: - Lightning

    private func drawLightning(context: GraphicsContext, size: CGSize, time: Double) {
        let flash = lightningImpulse(time)
        guard flash > 0.02 else { return }

        var sheet = context
        sheet.opacity = flash * 0.72
        sheet.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.82, green: 0.86, blue: 1),
                    Color(red: 0.7, green: 0.74, blue: 0.95).opacity(0.35),
                    Color.clear
                ]),
                startPoint: CGPoint(x: size.width * 0.5, y: 0),
                endPoint: CGPoint(x: size.width * 0.5, y: size.height)
            )
        )
    }

    /// Apple-like double flash every few seconds.
    private func lightningImpulse(_ time: Double) -> Double {
        let cycle = wrap(time, 4.2)
        return min(1, pulse(cycle, width: 0.08) + pulse(cycle - 0.16, width: 0.14) * 0.75)
    }

    private func pulse(_ x: Double, width: Double) -> Double {
        guard x >= 0, x <= width else { return 0 }
        return sin(x / width * .pi)
    }

    // MARK: - Math

    private func point(_ origin: CGPoint, _ angle: Double, _ radius: CGFloat) -> CGPoint {
        CGPoint(
            x: origin.x + CGFloat(cos(angle)) * radius,
            y: origin.y + CGFloat(sin(angle)) * radius
        )
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

struct WeatherIconPulse: ViewModifier {
    let kind: WeatherKind
    let isNight: Bool
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.04 : 0.97)
            .onAppear {
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }

    private var duration: Double {
        switch kind {
        case .sunny: return 3.6
        case .rain, .storm, .drizzle: return 2.2
        case .snow: return 3.2
        default: return 2.8
        }
    }
}

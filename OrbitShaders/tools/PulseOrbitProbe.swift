import Foundation

/// JSON-lines bridge for offline GPU review; uses the application's actual simulation.
@main struct PulseOrbitProbe {
    struct Request: Decodable, Equatable {
        var seconds: Double
        var drive: Double
        var attraction: Double
        var inertia: Double
        var center: Double
        var dynamics: Double
        var rhythmRate: Double
        var counterflow: Bool
        var clustering: Double
        var laneRates: [Double]
        var outerReverse: Bool
        var linkRange: Double
        var density: Double
        var lineCount: Int?
        var accentKind: Int?
        var accentTime: Double?
        var controls: PulseOrbitSimulation.Controls {
            .init(drive: drive, attraction: attraction, inertia: inertia, center: center,
                  dynamics:dynamics, rhythmRate:rhythmRate, counterflow:counterflow,
                  clustering:clustering,laneRates:laneRates,outerReverse:outerReverse,linkRange:linkRange,density:density)
        }
    }
    static func main() throws {
        var simulation = PulseOrbitSimulation()
        var previous: Request?
        while let line = readLine() {
            let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
            var start = 0.0
            if var last = previous {
                start = last.seconds
                last.seconds = request.seconds
                if last != request || start > request.seconds { start = 0; simulation = .init() }
            }
            if request.accentKind != nil {start=0;simulation = .init()}
            simulation.setLineCount(request.lineCount ?? 3)
            var fired=false
            if let kind=request.accentKind, let event=PulseOrbitSimulation.AccentKind(rawValue:kind), (request.accentTime ?? 0)<=0 {
                simulation.accent(event,controls:request.controls);fired=true
            }
            var remaining = max(0, request.seconds - start)
            while remaining > 1e-9 {
                var delta = min(remaining, 0.1)
                if let kind=request.accentKind,let event=PulseOrbitSimulation.AccentKind(rawValue:kind),!fired {
                    let until=(request.accentTime ?? 0)-simulation.time
                    if until<1e-7 {simulation.accent(event,controls:request.controls);fired=true}
                    else {delta=min(delta,until)}
                }
                simulation.advance(by: delta, controls: request.controls)
                remaining -= delta
            }
            previous = request
            let encoded = try JSONEncoder().encode(simulation.uniforms + [Float(simulation.time)] + simulation.eventUniforms + simulation.extendedUniforms + simulation.accentUniforms + simulation.traceUniforms)
            FileHandle.standardOutput.write(encoded + Data([10]))
        }
    }
}

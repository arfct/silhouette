// Report where each op of a Core ML model runs and how long a prediction takes.
// Usage: bench <model.mlpackage> [...]
import CoreML
import Foundation

func device(_ d: MLComputeDevice?) -> String {
    switch d {
    case .cpu?: return "cpu"
    case .gpu?: return "gpu"
    case .neuralEngine?: return "ane"
    default: return "none"
    }
}

func randomInputs(_ model: MLModel) throws -> MLFeatureProvider {
    var dict: [String: MLFeatureValue] = [:]
    for (name, desc) in model.modelDescription.inputDescriptionsByName {
        let c = desc.multiArrayConstraint!
        let a = try MLMultiArray(shape: c.shape, dataType: c.dataType == .float16 ? .float16 : .float32)
        for i in 0..<a.count { a[i] = NSNumber(value: Float.random(in: 0...1)) }
        dict[name] = MLFeatureValue(multiArray: a)
    }
    return try MLDictionaryFeatureProvider(dictionary: dict)
}

@main struct Bench {
    static func main() async throws {
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let compiled = try await MLModel.compileModel(at: url)
            print("== \(url.deletingPathExtension().lastPathComponent)")

            let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndNeuralEngine
            let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: cfg)
            if case .program(let program) = plan.modelStructure, let main = program.functions["main"] {
                var counts: [String: Int] = [:], costs: [String: Double] = [:], aneMisses: [String: Int] = [:]
                for op in main.block.operations {
                    guard let usage = plan.deviceUsage(for: op) else { continue }
                    let d = device(usage.preferred)
                    counts[d, default: 0] += 1
                    costs[d, default: 0] += plan.estimatedCost(of: op)?.weight ?? 0
                    if d != "ane", !usage.supported.contains(where: { if case .neuralEngine = $0 { return true }; return false }) {
                        aneMisses[op.operatorName, default: 0] += 1
                    }
                }
                print("ops by device (cpu+ANE config):", counts.sorted { $0.key < $1.key })
                print("estimated cost share:", costs.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.0f%%", $0.value * 100))" })
                if !aneMisses.isEmpty { print("ops the ANE can't run:", aneMisses.sorted { $0.value > $1.value }) }
            }

            for (label, units) in [("cpu+ane", MLComputeUnits.cpuAndNeuralEngine), ("cpu+gpu", .cpuAndGPU), ("all", .all)] {
                let c = MLModelConfiguration(); c.computeUnits = units
                let t0 = Date()
                let model = try MLModel(contentsOf: compiled, configuration: c)
                let load = Date().timeIntervalSince(t0)
                let input = try randomInputs(model)
                for _ in 0..<3 { _ = try await model.prediction(from: input) }
                var times: [Double] = []
                for _ in 0..<20 { let s = Date(); _ = try await model.prediction(from: input); times.append(Date().timeIntervalSince(s) * 1000) }
                times.sort()
                print("\(label): load \(String(format: "%.1f", load)) s, median \(String(format: "%.1f", times[10])) ms, best \(String(format: "%.1f", times[0])) ms")
            }
        }
    }
}

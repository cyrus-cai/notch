// Offline evaluation harness for IntentEngine — NOT part of the app target.
//
// Compiles the real engine + corpus straight from Sources/ so what's measured is
// exactly what ships:
//
//   swiftc -O scripts/intent_eval/main.swift \
//       NotchGlass/Sources/IntentEngine.swift \
//       NotchGlass/Sources/IntentExamples.swift \
//       -o /tmp/intent_eval && /tmp/intent_eval
//
// For each of several split seeds: hold out 20% of each class per language, fit
// heads on the remaining 80% (bypassing the disk cache), and score the holdout.
// Reports per-seed and aggregate accuracy, the confidence distribution (to pick
// the routing floor), and per-classify latency.

import Foundation

// Deterministic split so runs are comparable.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

func split(_ items: [String], rng: inout SeededRNG,
           testFraction: Double) -> (train: [String], test: [String]) {
    let shuffled = items.shuffled(using: &rng)
    let testCount = max(1, Int(Double(shuffled.count) * testFraction))
    return (Array(shuffled.dropFirst(testCount)), Array(shuffled.prefix(testCount)))
}

var allCorrectConfidences: [Double] = []
var allWrongConfidences: [Double] = []
var latencies: [Double] = []
var grandTotals = (0, 0)
var grandTrainTotals = (0, 0)

func evaluate(_ engine: IntentEngine, _ label: String, _ lines: [String],
              expect: IntentEngine.Intent, quiet: Bool = false) async -> (Int, Int) {
    var correct = 0
    for line in lines {
        let start = DispatchTime.now()
        let reading = await engine.classify(line)
        latencies.append(Double(DispatchTime.now().uptimeNanoseconds
                                - start.uptimeNanoseconds) / 1e6)
        if reading.intent == expect {
            correct += 1
            if !quiet { allCorrectConfidences.append(reading.confidence) }
        } else if !quiet {
            allWrongConfidences.append(reading.confidence)
            print(String(format: "    MISS [%@] conf %.2f → %@: %@",
                         label, reading.confidence, "\(reading.intent)", line))
        }
    }
    return (correct, lines.count)
}

for seed in [42, 7, 1234] as [UInt64] {
    var rng = SeededRNG(state: seed)
    let zhAsk = split(IntentExamples.chinese.ask, rng: &rng, testFraction: 0.2)
    let zhNote = split(IntentExamples.chinese.note, rng: &rng, testFraction: 0.2)
    let enAsk = split(IntentExamples.english.ask, rng: &rng, testFraction: 0.2)
    let enNote = split(IntentExamples.english.note, rng: &rng, testFraction: 0.2)

    let engine = IntentEngine()
    let prepStart = Date()
    await engine.prepareForEvaluation(
        chinese: IntentExampleSet(ask: zhAsk.train, note: zhNote.train),
        english: IntentExampleSet(ask: enAsk.train, note: enNote.train))
    print(String(format: "—— seed %d (prepare %.1fs) ——", seed,
                 Date().timeIntervalSince(prepStart)))

    var trainTotals = (0, 0)
    for (lines, expect): ([String], IntentEngine.Intent) in [
        (zhAsk.train, .ask), (zhNote.train, .note),
        (enAsk.train, .ask), (enNote.train, .note),
    ] {
        let (c, n) = await evaluate(engine, "", lines, expect: expect, quiet: true)
        trainTotals.0 += c; trainTotals.1 += n
    }
    grandTrainTotals.0 += trainTotals.0; grandTrainTotals.1 += trainTotals.1
    latencies.removeAll()

    var totals = (0, 0)
    for (label, lines, expect): (String, [String], IntentEngine.Intent) in [
        ("zh ask ", zhAsk.test, .ask),
        ("zh note", zhNote.test, .note),
        ("en ask ", enAsk.test, .ask),
        ("en note", enNote.test, .note),
    ] {
        let (c, n) = await evaluate(engine, label, lines, expect: expect)
        totals.0 += c; totals.1 += n
    }
    grandTotals.0 += totals.0; grandTotals.1 += totals.1
    print(String(format: "  seed %d: train %.1f%%, holdout %d/%d = %.1f%%",
                 seed, 100.0 * Double(trainTotals.0) / Double(trainTotals.1),
                 totals.0, totals.1, 100.0 * Double(totals.0) / Double(totals.1)))
}

print(String(format: "\n=== aggregate: train %.1f%%, holdout %d/%d = %.1f%% ===",
             100.0 * Double(grandTrainTotals.0) / Double(grandTrainTotals.1),
             grandTotals.0, grandTotals.1,
             100.0 * Double(grandTotals.0) / Double(grandTotals.1)))

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

print(String(format: "confidence — correct: p10 %.2f / p50 %.2f；wrong: p50 %.2f / p90 %.2f",
             percentile(allCorrectConfidences, 0.1), percentile(allCorrectConfidences, 0.5),
             percentile(allWrongConfidences, 0.5), percentile(allWrongConfidences, 0.9)))

// How a candidate routing floor would play out: below the floor the app refuses
// to route (defaults to Ask), so floored-out wrong answers are saves and
// floored-out correct answers are missed routings.
for floor in [0.2, 0.3, 0.4, 0.5] {
    let keptWrong = allWrongConfidences.filter { $0 >= floor }.count
    let keptCorrect = allCorrectConfidences.filter { $0 >= floor }.count
    print(String(format: "floor %.1f → confident-and-wrong %d, confident-and-correct %d/%d",
                 floor, keptWrong, keptCorrect, allCorrectConfidences.count))
}

print(String(format: "\nclassify latency: p50 %.2fms / p90 %.2fms / max %.2fms",
             percentile(latencies, 0.5), percentile(latencies, 0.9),
             percentile(latencies, 1.0)))

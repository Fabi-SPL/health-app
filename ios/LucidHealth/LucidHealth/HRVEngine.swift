import Foundation

// ════════════════════════════════════════════════════════════
// HRV Engine — RMSSD, SDNN, pNN50, DFA α1, Respiratory Rate
// Extension on HealthEngine for all HRV-related computation
//
// Research basis:
//   - RMSSD: vagal tone marker (Task Force 1996)
//   - SDNN: best single predictor of executive function (Poole 2018)
//   - pNN50: correlates with processing speed (Shaffer & Ginsberg 2017)
//   - DFA α1: overtraining detection (Plews 2013)
//   - Respiratory rate: RSA extraction via autocorrelation
//   - Cognitive Readiness: composite from Thayer 2022 meta-analysis
// ════════════════════════════════════════════════════════════

extension HealthEngine {

    // MARK: - RR Interval Input

    /// Add a new RR interval (in milliseconds) from the Whoop strap
    func addRRInterval(_ rr: Double) {
        // Filter ectopic beats: reject >20% deviation from local median
        if !rrBuffer.isEmpty {
            let recent = Array(rrBuffer.suffix(5))
            let sorted = recent.sorted()
            let median = sorted[sorted.count / 2]
            if abs(rr - median) / median > 0.20 {
                return  // ectopic beat, skip
            }
        }

        rrBuffer.append(rr)
        rrTimestamps.append(Date())

        // Keep buffer size bounded
        if rrBuffer.count > rrBufferSize {
            rrBuffer.removeFirst()
            rrTimestamps.removeFirst()
        }

        // Recompute HRV metrics every 10 new RR intervals
        if rrBuffer.count >= rmssdWindowSize && rrBuffer.count % 10 == 0 {
            computeRMSSD()
            computeSDNN()
            computePNN50()
            computePoincaré()
            computeRespiratoryRate()
            computeCoherenceScore()
        }

        // DFA α1 needs 120+ intervals — compute less frequently
        if rrBuffer.count >= 120 && rrBuffer.count % 30 == 0 {
            computeDFAAlpha1()
        }

        // Baevsky Stress Index — needs ~100+ RRs (5+ min). Recompute every 30 new RRs.
        if rrBuffer.count >= 100 && rrBuffer.count % 30 == 0 {
            computeBaevskyStress()
        }
    }

    // MARK: - RMSSD Computation

    /// RMSSD = Root Mean Square of Successive Differences
    func computeRMSSD() {
        let window = Array(rrBuffer.suffix(rmssdWindowSize))
        guard window.count >= 2 else { return }

        var sumSquaredDiffs: Double = 0
        for i in 1..<window.count {
            let diff = window[i] - window[i - 1]
            sumSquaredDiffs += diff * diff
        }
        let rmssd = sqrt(sumSquaredDiffs / Double(window.count - 1))

        DispatchQueue.main.async {
            self.currentRMSSD = rmssd
            self.lnRMSSD = rmssd > 0 ? log(rmssd) : 0
            UserDefaults.standard.set(rmssd, forKey: self.currentRMSSDKey)
            self.updateReadiness()
            // Feed RMSSD slope tracker — rising trend across 3×5min windows =
            // N3→N2→N1 transition, primary wake-readiness signal.
            self.feedRmssdForSlope(rmssd)

            // Capture sleep-window RMSSD samples for the morning recovery
            // computation. Whoop uses last-SWS HRV; we approximate with the
            // last hour of sleep (kept rolling at 360 samples = 6h @ 1/min).
            // Buchheit 2014: daytime HRV is contaminated by task-state, so
            // recovery must use sleep-window samples only.
            if self.sleepDetected && rmssd > 0 {
                self.sleepPeriodRMSSDSamples.append(rmssd)
                if self.sleepPeriodRMSSDSamples.count > 360 {
                    self.sleepPeriodRMSSDSamples.removeFirst(self.sleepPeriodRMSSDSamples.count - 360)
                }
            }
        }

        // Track 5-min RMSSD values
        rmssdHistory.append(rmssd)
    }

    // MARK: - SDNN (Standard Deviation of NN Intervals)
    // Best single predictor of executive function (Poole 2018).
    // Captures overall autonomic function (both sympathetic + parasympathetic).

    func computeSDNN() {
        let window = Array(rrBuffer.suffix(rmssdWindowSize))
        guard window.count >= 10 else { return }

        let mean = window.reduce(0, +) / Double(window.count)
        let variance = window.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(window.count)

        DispatchQueue.main.async {
            self.sdnn = sqrt(variance)
        }
    }

    // MARK: - pNN50 (% successive intervals >50ms apart)
    // Correlates with information processing speed (Shaffer & Ginsberg 2017).

    func computePNN50() {
        let window = Array(rrBuffer.suffix(rmssdWindowSize))
        guard window.count >= 10 else { return }

        var count50 = 0
        for i in 1..<window.count {
            if abs(window[i] - window[i - 1]) > 50 {
                count50 += 1
            }
        }

        DispatchQueue.main.async {
            self.pnn50 = Double(count50) / Double(window.count - 1) * 100
        }
    }

    // MARK: - DFA α1 (Detrended Fluctuation Analysis)
    // Detects overtraining/overreaching BEFORE subjective fatigue.
    // More sensitive than RMSSD to training stress.
    // α1 ≈ 1.0 at rest = healthy fractal correlations
    // α1 dropping toward 0.5 = autonomic stress / overreaching

    func computeDFAAlpha1() {
        let rr = Array(rrBuffer.suffix(120))
        guard rr.count >= 100 else { return }

        // Step 1: Integrate the RR series (cumulative sum of deviations from mean)
        let mean = rr.reduce(0, +) / Double(rr.count)
        var integrated = [Double](repeating: 0, count: rr.count)
        integrated[0] = rr[0] - mean
        for i in 1..<rr.count {
            integrated[i] = integrated[i - 1] + (rr[i] - mean)
        }

        // Step 2: Compute F(n) for window sizes 4 to 16
        let boxSizes = [4, 6, 8, 10, 12, 16]
        var logN = [Double]()
        var logF = [Double]()

        for n in boxSizes {
            guard n <= rr.count / 4 else { continue }

            let numBoxes = rr.count / n
            guard numBoxes > 0 else { continue }

            var totalResidual: Double = 0

            for b in 0..<numBoxes {
                let start = b * n
                let end = start + n

                // Linear least-squares fit within box
                var sumX: Double = 0, sumY: Double = 0, sumXY: Double = 0, sumX2: Double = 0
                for i in start..<end {
                    let x = Double(i - start)
                    let y = integrated[i]
                    sumX += x; sumY += y; sumXY += x * y; sumX2 += x * x
                }
                let nD = Double(n)
                let slope = (nD * sumXY - sumX * sumY) / (nD * sumX2 - sumX * sumX)
                let intercept = (sumY - slope * sumX) / nD

                // Residual variance
                for i in start..<end {
                    let x = Double(i - start)
                    let trend = slope * x + intercept
                    let residual = integrated[i] - trend
                    totalResidual += residual * residual
                }
            }

            let fn = sqrt(totalResidual / Double(numBoxes * n))
            if fn > 0 {
                logN.append(log(Double(n)))
                logF.append(log(fn))
            }
        }

        // Step 3: α1 = slope of log(F(n)) vs log(n)
        guard logN.count >= 3 else { return }

        let n = Double(logN.count)
        let sumX = logN.reduce(0, +)
        let sumY = logF.reduce(0, +)
        let sumXY = zip(logN, logF).map { $0 * $1 }.reduce(0, +)
        let sumX2 = logN.map { $0 * $0 }.reduce(0, +)

        let alpha = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX)

        DispatchQueue.main.async {
            self.dfaAlpha1 = round(alpha * 100) / 100
        }
    }

    // MARK: - Cognitive Readiness v2 (Research-Backed Composite)
    //
    // Composite: LnRMSSD (30%) + SDNN (30%) + Sleep quality (25%) + DFA α1 (15%)
    // (Thayer 2022 meta-analysis: HRV→exec function r=0.19; Poole 2018: SDNN best predictor)
    // Bands: Green (80-100), Yellow (50-79), Red (0-49)

    func updateReadiness() {
        guard !baselineRMSSD.isEmpty else {
            readiness = .unknown
            return
        }

        // --- Legacy readiness (simple LnRMSSD deviation) ---
        let baselineLn = baselineRMSSD.map { $0 > 0 ? log($0) : 0 }
        let meanLn = baselineLn.reduce(0, +) / Double(baselineLn.count)
        let varianceLn = baselineLn.map { ($0 - meanLn) * ($0 - meanLn) }.reduce(0, +) / Double(baselineLn.count)
        let sdLn = sqrt(varianceLn)
        let deviation = (lnRMSSD - meanLn) / max(sdLn, 0.01)

        if deviation >= -0.5 {
            readiness = .green
        } else if deviation >= -1.0 {
            readiness = .yellow
        } else {
            readiness = .red
        }

        // --- Cognitive Capacity v3 (0-100 composite) ---
        //
        // Reweighted against what is actually validated WITHIN a person, not
        // across people. The HRV-to-executive-function literature is trait-level:
        // people with habitually higher vagal tone test better. No study found
        // shows one person's daily HRV swing predicts that person's own daily
        // executive function. Treating it as if it does is the ergodic fallacy,
        // and it used to be 60% of this score.
        //
        // Sleep duration measured as a deviation from his OWN average is the one
        // predictor with within-person validation (+0.11 processing-speed units
        // per extra hour, 95% CI 0.06-0.15, 21-day ILD, N=326, Oxford Sleep
        // 2026), with the between-person effect null. So it leads now.
        //
        // Sleep efficiency was flatly null in the same study (0.00, CI -0.01 to
        // 0.01) and no longer enters the score at all. Stage minutes never did,
        // which turns out to be correct: nothing links deep/REM minutes to
        // next-day cognition within-person either.

        // 1. Sleep-duration deviation from his own baseline (45%)
        let sleepComp: Double
        if sleepHoursBaseline > 0, sleepHoursSD > 0.1, sleepDurationHours > 0 {
            let sleepZ = (sleepDurationHours - sleepHoursBaseline) / sleepHoursSD
            sleepComp = max(0, min(100, 50 + sleepZ * 25))
        } else {
            // No usable personal baseline yet. Stay neutral rather than fall back
            // to absolute cutoffs — "7 hours is good" is a between-person claim
            // and carries no signal about his own day.
            sleepComp = 50
        }

        // 2. LnRMSSD component (25%): kept as an untested hypothesis, not a fact.
        // Whether this predicts HIS executive function is the open question the
        // n=1 experiment harness exists to answer.
        let rmssdScore = max(0, min(100, 50 + deviation * 25))

        // 3. SDNN component (15%): same trait-level caveat as RMSSD, so demoted
        // with it rather than carried at equal weight.
        let baselineSDNN = sdnnHistory.isEmpty ? baselineHRV : (sdnnHistory.reduce(0, +) / Double(sdnnHistory.count))
        let sdnnRatio = baselineSDNN > 0 ? min(sdnn / baselineSDNN, 1.5) : 1.0
        let sdnnScore = min(sdnnRatio * 100, 100) * (sdnn > 0 ? 1.0 : 0.0)

        // 4. DFA α1 component (15%): healthy resting ≈ 1.0. Held at weight —
        // this is an autonomic-fatigue marker, not a cognition claim.
        let dfaComp: Double
        if dfaAlpha1 > 0 {
            if dfaAlpha1 >= 0.9 && dfaAlpha1 <= 1.2 {
                dfaComp = 100  // healthy fractal
            } else if dfaAlpha1 >= 0.75 {
                dfaComp = 60 + (dfaAlpha1 - 0.75) / 0.15 * 40
            } else {
                dfaComp = max(dfaAlpha1 / 0.75 * 60, 0)  // stressed/overreaching
            }
        } else {
            dfaComp = 50  // no data — neutral
        }

        let capacity = sleepComp * 0.45 + rmssdScore * 0.25 + sdnnScore * 0.15 + dfaComp * 0.15

        DispatchQueue.main.async {
            self.cognitiveCapacity = round(capacity)
            if capacity >= 80 {
                self.cognitiveLabel = "Full"
            } else if capacity >= 50 {
                self.cognitiveLabel = "Reduced"
            } else {
                self.cognitiveLabel = "Low"
            }
        }
    }

    // MARK: - Respiratory Rate (RSA Extraction)
    //
    // Research: Lomb-Scargle periodogram on RR intervals.
    // Best during sleep. Window: 60s. Reject if SNR < 2.5 or rate outside 8-25 bpm.
    // Using simplified FFT approach with Accelerate framework.

    func computeRespiratoryRate() {
        guard rrBuffer.count >= 30 else { return }

        // Use last 60 seconds of RR intervals
        let window = Array(rrBuffer.suffix(60))
        guard window.count >= 20 else { return }

        // Interpolate RR intervals to 4 Hz evenly-sampled signal
        let totalDuration = window.reduce(0, +) / 1000.0  // convert ms to seconds
        let sampleRate: Double = 4.0
        let numSamples = Int(totalDuration * sampleRate)
        guard numSamples >= 16 else { return }

        // Create cumulative time array
        var cumTime: [Double] = [0]
        for rr in window {
            cumTime.append(cumTime.last! + rr / 1000.0)
        }

        // Linear interpolation to evenly-sampled signal
        var interpolated = [Double](repeating: 0, count: numSamples)
        for i in 0..<numSamples {
            let t = Double(i) / sampleRate
            // Find bracketing RR values
            var j = 0
            while j < cumTime.count - 2 && cumTime[j + 1] < t { j += 1 }
            let span = cumTime[j + 1] - cumTime[j]
            let frac = span > 0 ? min(1.0, max(0.0, (t - cumTime[j]) / span)) : 0
            let a = window[min(j, window.count - 1)]
            let b = window[min(j + 1, window.count - 1)]
            interpolated[i] = a + (b - a) * frac
        }

        // Remove the linear trend, not just the mean. A slow RR drift leaves the
        // autocorrelation decaying monotonically, which pins the band maximum at
        // minLag and reports a constant 24.0 bpm.
        let n = Double(interpolated.count)
        let sumX = (n - 1) * n / 2
        let sumXX = (n - 1) * n * (2 * n - 1) / 6
        var sumY: Double = 0
        var sumXY: Double = 0
        for (i, v) in interpolated.enumerated() {
            sumY += v
            sumXY += Double(i) * v
        }
        let denom = n * sumXX - sumX * sumX
        guard denom != 0 else { return }
        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n
        for i in 0..<interpolated.count {
            interpolated[i] -= intercept + slope * Double(i)
        }

        // Spectral peak in the respiratory band, which is the method that
        // benchmarked best of ten ECG-derived-respiration techniques (0.0 bpm
        // bias): tachogram, even resample, band-limit, take the peak. Computed as
        // a direct periodogram over the band rather than a full FFT — the band is
        // only ~0.1-0.5 Hz wide, so this is a few dozen bins, and it avoids
        // needing a power-of-two window.
        let minFreq = 0.1
        let maxFreq = 0.5
        let freqStep = 0.005   // 0.3 bpm resolution
        let m = interpolated.count

        var bestFreq = 0.0
        var bestPower = 0.0
        var totalPower = 0.0
        var bandPowers: [(freq: Double, power: Double)] = []

        var f = minFreq
        while f <= maxFreq {
            var re = 0.0
            var im = 0.0
            for (i, v) in interpolated.enumerated() {
                let phase = 2.0 * Double.pi * f * Double(i) / sampleRate
                re += v * cos(phase)
                im += v * sin(phase)
            }
            let power = (re * re + im * im) / Double(m)
            bandPowers.append((f, power))
            totalPower += power
            if power > bestPower {
                bestPower = power
                bestFreq = f
            }
            f += freqStep
        }

        guard bestPower > 0, totalPower > 0, bandPowers.count > 2 else { return }

        // The peak has to actually stand out. A flat band means there is no
        // respiratory rhythm resolvable in this window, and reporting the
        // arg-max of noise is exactly how this ended up pinned at one value.
        let meanPower = totalPower / Double(bandPowers.count)
        let snr = bestPower / max(meanPower, 1e-9)
        guard snr >= 2.5 else { return }

        // And it must be an interior peak, not the edge of the search band.
        guard bestFreq > minFreq + freqStep, bestFreq < maxFreq - freqStep else { return }

        let bpm = bestFreq * 60.0

        if bpm >= 8 && bpm <= 25 {
            DispatchQueue.main.async {
                self.respiratoryRate = bpm
            }
        }
    }

    // MARK: - Cardiac Coherence (HeartMath 0.1 Hz spectral ratio)
    //
    // During paced 6-breaths/min breathing, HR oscillation concentrates into a
    // single sharp peak near 0.1 Hz. Coherence = power in a narrow window around
    // that peak / total LF-band power. Returns 0...1 (incoherent ~0.1-0.2, well
    // paced ~0.4-0.8). Real band-limited DFT on the RR tachogram, replacing the
    // old RMSSD-ratio proxy in CoherenceDrillView. Runs on the BLE delegate
    // queue (called from addRRInterval, same queue rrBuffer is mutated on, so no
    // race), publishes to main like respiratoryRate.
    func computeCoherenceScore() {
        guard rrBuffer.count >= 30 else { return }

        // Last ~64 seconds of beats (need >=5 cycles of the 0.1 Hz rhythm).
        var window: [Double] = []
        var acc = 0.0
        for rr in rrBuffer.reversed() {
            window.append(rr)
            acc += rr / 1000.0
            if acc >= 64 { break }
        }
        window.reverse()
        guard window.count >= 20 else { return }

        // Interpolate the RR tachogram to an evenly-sampled 4 Hz signal.
        let fs = 4.0
        let totalDur = window.reduce(0, +) / 1000.0
        let n = Int(totalDur * fs)
        guard n >= 32 else { return }

        var cumTime: [Double] = [0]
        for rr in window { cumTime.append(cumTime.last! + rr / 1000.0) }

        var sig = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            var j = 0
            while j < cumTime.count - 1 && cumTime[j + 1] < t { j += 1 }
            if j < window.count { sig[i] = window[j] }
        }

        // Remove mean + Hann window (cut spectral leakage).
        let mean = sig.reduce(0, +) / Double(n)
        for i in 0..<n {
            let hann = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(n - 1))
            sig[i] = (sig[i] - mean) * hann
        }

        // Band-limited DFT: power across 0.04...0.40 Hz.
        let fStep = 0.005
        var freqs: [Double] = []
        var power: [Double] = []
        var f = 0.04
        while f <= 0.40 + 1e-9 {
            var re = 0.0, im = 0.0
            let w = 2.0 * Double.pi * f / fs
            for i in 0..<n {
                re += sig[i] * cos(w * Double(i))
                im -= sig[i] * sin(w * Double(i))
            }
            freqs.append(f)
            power.append(re * re + im * im)
            f += fStep
        }

        let total = power.reduce(0, +)
        guard total > 0 else { return }

        // Peak in the coherence band (0.04...0.15 Hz; 6/min breathing = 0.1 Hz).
        var peakIdx = -1
        var peakVal = -1.0
        for (i, fr) in freqs.enumerated() where fr >= 0.04 && fr <= 0.15 {
            if power[i] > peakVal { peakVal = power[i]; peakIdx = i }
        }
        guard peakIdx >= 0 else { return }

        // Power within +/-0.015 Hz of the peak.
        let peakF = freqs[peakIdx]
        var peakBand = 0.0
        for (i, fr) in freqs.enumerated() where abs(fr - peakF) <= 0.015 {
            peakBand += power[i]
        }

        let coherence = min(max(peakBand / total, 0), 1)
        DispatchQueue.main.async {
            self.currentCoherence = coherence
        }
    }

    // MARK: - Poincaré SD1/SD2 (Finding 1.1 — Autonomic Balance)
    // SD1 = short-term parasympathetic (beat-to-beat), correlates with RMSSD
    // SD2 = long-term sympathovagal balance
    // SD2/SD1 ratio: high = sympathetic dominant, low = parasympathetic dominant

    func computePoincaré() {
        let window = Array(rrBuffer.suffix(rmssdWindowSize))
        guard window.count >= 10 else { return }

        // SDSD = standard deviation of successive differences
        var diffs = [Double]()
        for i in 1..<window.count {
            diffs.append(window[i] - window[i - 1])
        }
        let meanDiff = diffs.reduce(0, +) / Double(diffs.count)
        let sdsd = sqrt(diffs.map { ($0 - meanDiff) * ($0 - meanDiff) }.reduce(0, +) / Double(diffs.count))

        // SDNN for SD2 computation
        let meanRR = window.reduce(0, +) / Double(window.count)
        let sdnnVal = sqrt(window.map { ($0 - meanRR) * ($0 - meanRR) }.reduce(0, +) / Double(window.count))

        // SD1 = sqrt(0.5 * SDSD²)
        let sd1 = sqrt(0.5 * sdsd * sdsd)
        // SD2 = sqrt(2 * SDNN² - 0.5 * SDSD²)
        let sd2Squared = 2 * sdnnVal * sdnnVal - 0.5 * sdsd * sdsd
        let sd2 = sd2Squared > 0 ? sqrt(sd2Squared) : 0

        DispatchQueue.main.async {
            self.poincaréSD1 = round(sd1 * 10) / 10
            self.poincaréSD2 = round(sd2 * 10) / 10
            self.poincaréRatio = sd1 > 0 ? round((sd2 / sd1) * 100) / 100 : 0
        }
    }

    // MARK: - Whoop-Style HRV Score (0-100)

    var hrvScore: Double {
        guard currentRMSSD > 0 else { return 0 }
        return min((log(currentRMSSD) / 6.5) * 100, 100)
    }

    // MARK: - Baevsky Stress Index (P3 — stolen from openwhoop community)
    // SI = AMo / (2 × Mo × MxDMn). 0-500: <100 calm, 100-300 normal, >300 stressed.
    // Independent of HRV mean — captures sympathetic activation HRV misses.
    func computeBaevskyStress() {
        let window = Array(rrBuffer.suffix(300))
        guard window.count >= 100 else { return }
        let rrSec = window.map { $0 / 1000.0 }
        let sorted = rrSec.sorted()
        let p05 = sorted[Int(Double(sorted.count) * 0.05)]
        let p95 = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
        let mxdmn = max(p95 - p05, 0.001)
        let binWidth = 0.050
        let minBin = floor(p05 / binWidth) * binWidth
        let numBins = max(Int(ceil((p95 - minBin) / binWidth)) + 1, 1)
        var bins = [Int](repeating: 0, count: numBins)
        for rr in rrSec {
            if rr < p05 || rr > p95 { continue }
            let idx = min(max(Int((rr - minBin) / binWidth), 0), numBins - 1)
            bins[idx] += 1
        }
        guard let peakIdx = bins.indices.max(by: { bins[$0] < bins[$1] }) else { return }
        let mo = minBin + (Double(peakIdx) + 0.5) * binWidth
        let modeCount = bins[peakIdx]
        let totalCounted = bins.reduce(0, +)
        guard totalCounted > 0 else { return }
        let amoPct = Double(modeCount) / Double(totalCounted) * 100.0
        let si = amoPct / (2.0 * mo * mxdmn)
        let clipped = max(0, min(si, 999))
        let label: String
        if clipped < 100 { label = "Calm" }
        else if clipped < 300 { label = "Normal" }
        else { label = "Stressed" }
        DispatchQueue.main.async {
            self.baevskyStress = round(clipped)
            self.baevskyStressLabel = label
        }
    }
}

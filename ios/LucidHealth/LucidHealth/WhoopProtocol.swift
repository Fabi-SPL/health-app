import Foundation

// MARK: - Whoop BLE UUIDs
enum WhoopUUID {
    static let service       = "61080001-8D6D-82B8-614A-1C8CB0F8DCC6"
    static let cmdToStrap    = "61080002-8D6D-82B8-614A-1C8CB0F8DCC6"
    static let cmdFromStrap  = "61080003-8D6D-82B8-614A-1C8CB0F8DCC6"
    static let events        = "61080004-8D6D-82B8-614A-1C8CB0F8DCC6"
    static let data          = "61080005-8D6D-82B8-614A-1C8CB0F8DCC6"
    /// Firmware fault/crash log stream (currently unsubscribed prior to v66).
    static let memfault      = "61080007-8D6D-82B8-614A-1C8CB0F8DCC6"
}

// MARK: - Packet Types
enum PacketType: UInt8 {
    case command           = 35
    case commandResponse   = 36
    case realtimeData      = 40
    case realtimeRawData   = 43   // Raw optical (PPG) frames — type-43
    case historicalData    = 47
    case event             = 48
    case metadata          = 49
    case consoleLogs       = 50   // Firmware debug/console output
    case imuRealtime       = 51   // Live IMU (accel + gyro @ 52 Hz)
    case imuHistorical     = 52   // Historical IMU buffer
}

// MARK: - Commands
enum WhoopCommand: UInt8 {
    case toggleRealtimeHR         = 3
    case reportVersionInfo        = 7    // Returns firmware version string
    case setClock                 = 10   // SET_CLOCK (separate from GET at 11)
    case getClock                 = 11
    case sendHistoricalData       = 22
    case historyAck               = 23
    case eraseHistory             = 25   // 0x19 ERASE_HISTORY — wipes the strap's internal flash buffer (DESTRUCTIVE)
    case getBatteryLevel          = 26
    case getHelloHarvard          = 35
    case startRawData             = 81   // Activate raw optical (PPG) stream → type-43
    case stopRawData              = 82
    case runHapticsPattern        = 79
    case getAllHapticsPattern     = 80
    case getBodyLocationAndStatus = 84   // Strap orientation + status
    case toggleIMUHistorical      = 105
    case toggleIMU                = 106  // Live IMU — enable → type-51 @ 52 Hz
    case enableOpticalData        = 107
    case toggleOpticalMode        = 108
    case stopHaptics              = 122
    case selectWrist              = 123  // 0=left / 1=right
    case getExtendedBatteryInfo   = 98   // Voltage + cycles + SoH from MAX77818
}

// MARK: - Event Types
enum WhoopEvent: UInt8 {
    case battery            = 3
    case chargingOn         = 7
    case chargingOff        = 8
    case wristOn            = 9
    case wristOff           = 10
    case doubleTap          = 14
    case temperatureLevel   = 17
    case strapCondition     = 29   // Boot-time strap condition report
    case realtimeHROn       = 33
    case realtimeHROff      = 34
    case afeReset           = 36   // Optical analog front-end reset
    case ch1Saturation      = 40   // LED photodiode channel 1 saturated
    case ch2Saturation      = 41
    case accelSaturation    = 42   // IMU range exceeded
    case rawDataOn          = 46   // Confirms CMD 81 accepted
    case rawDataOff         = 47
    case hapticsFired       = 60   // Strap confirms haptic pattern fired
    case extendedBattery    = 63   // Richer battery telemetry
}

// MARK: - Temperature Parsing

extension WhoopProtocol {
    /// Parse skin temperature from Event 17 payload
    /// Sensor: MAX6631MTT — 12-bit signed register, +/-1°C accuracy
    ///
    /// MAX6631 register format (2 bytes, big-endian, transmitted little-endian over BLE):
    ///   Byte 1 (MSB) = integer part of Celsius
    ///   Byte 0 (LSB) = fractional part (bit 7 = 0.5°C, bit 6 = 0.25°C, etc.)
    ///   Decode: Int16(LE) / 256.0 = Celsius
    ///   Example: 33°C → register 0x2100 → LE bytes [00, 21] → 8448 / 256.0 = 33.0°C
    ///
    /// Tries two byte offsets: some firmware variants prepend a 1-byte status field.
    static func parseTemperature(_ data: Data) -> Double? {
        guard data.count >= 2 else { return nil }

        // Try at byte offset 0 (no status prefix) and offset 1 (1-byte status prefix)
        for offset in [0, 1] {
            guard data.count >= offset + 2 else { continue }
            let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            let rawSigned = Int16(bitPattern: raw)

            // Primary: MAX6631MTT correct decode — int16 LE / 256.0
            let tempC = Double(rawSigned) / 256.0
            if tempC >= 25.0 && tempC <= 42.0 { return tempC }

            // Fallback A: fixed-point × 100 (some wearable sensors)
            let tempC2 = Double(rawSigned) / 100.0
            if tempC2 >= 25.0 && tempC2 <= 42.0 { return tempC2 }

            // Fallback B: × 10
            let tempC3 = Double(rawSigned) / 10.0
            if tempC3 >= 25.0 && tempC3 <= 42.0 { return tempC3 }
        }

        return nil  // All strategies failed — raw bytes are logged separately for analysis
    }
}

// MARK: - Parsed Packet
struct WhoopPacket {
    let type: UInt8
    let seq: UInt8
    let cmd: UInt8
    let data: Data
}

// MARK: - HR Reading
struct HRReading {
    let timestamp: UInt32
    let heartRate: UInt8
    let rrIntervals: [UInt16]  // in milliseconds
    var distributedDate: Date?  // Set by gap sync for sub-second timestamp precision
}

// MARK: - Protocol Implementation
struct WhoopProtocol {

    // CRC8 lookup table — exact copy from whoomp. MUST use this, not bitwise.
    static let crc8Table: [UInt8] = [
        0x00, 0x07, 0x0E, 0x09, 0x1C, 0x1B, 0x12, 0x15, 0x38, 0x3F, 0x36, 0x31, 0x24, 0x23, 0x2A, 0x2D,
        0x70, 0x77, 0x7E, 0x79, 0x6C, 0x6B, 0x62, 0x65, 0x48, 0x4F, 0x46, 0x41, 0x54, 0x53, 0x5A, 0x5D,
        0xE0, 0xE7, 0xEE, 0xE9, 0xFC, 0xFB, 0xF2, 0xF5, 0xD8, 0xDF, 0xD6, 0xD1, 0xC4, 0xC3, 0xCA, 0xCD,
        0x90, 0x97, 0x9E, 0x99, 0x8C, 0x8B, 0x82, 0x85, 0xA8, 0xAF, 0xA6, 0xA1, 0xB4, 0xB3, 0xBA, 0xBD,
        0xC7, 0xC0, 0xC9, 0xCE, 0xDB, 0xDC, 0xD5, 0xD2, 0xFF, 0xF8, 0xF1, 0xF6, 0xE3, 0xE4, 0xED, 0xEA,
        0xB7, 0xB0, 0xB9, 0xBE, 0xAB, 0xAC, 0xA5, 0xA2, 0x8F, 0x88, 0x81, 0x86, 0x93, 0x94, 0x9D, 0x9A,
        0x27, 0x20, 0x29, 0x2E, 0x3B, 0x3C, 0x35, 0x32, 0x1F, 0x18, 0x11, 0x16, 0x03, 0x04, 0x0D, 0x0A,
        0x57, 0x50, 0x59, 0x5E, 0x4B, 0x4C, 0x45, 0x42, 0x6F, 0x68, 0x61, 0x66, 0x73, 0x74, 0x7D, 0x7A,
        0x89, 0x8E, 0x87, 0x80, 0x95, 0x92, 0x9B, 0x9C, 0xB1, 0xB6, 0xBF, 0xB8, 0xAD, 0xAA, 0xA3, 0xA4,
        0xF9, 0xFE, 0xF7, 0xF0, 0xE5, 0xE2, 0xEB, 0xEC, 0xC1, 0xC6, 0xCF, 0xC8, 0xDD, 0xDA, 0xD3, 0xD4,
        0x69, 0x6E, 0x67, 0x60, 0x75, 0x72, 0x7B, 0x7C, 0x51, 0x56, 0x5F, 0x58, 0x4D, 0x4A, 0x43, 0x44,
        0x19, 0x1E, 0x17, 0x10, 0x05, 0x02, 0x0B, 0x0C, 0x21, 0x26, 0x2F, 0x28, 0x3D, 0x3A, 0x33, 0x34,
        0x4E, 0x49, 0x40, 0x47, 0x52, 0x55, 0x5C, 0x5B, 0x76, 0x71, 0x78, 0x7F, 0x6A, 0x6D, 0x64, 0x63,
        0x3E, 0x39, 0x30, 0x37, 0x22, 0x25, 0x2C, 0x2B, 0x06, 0x01, 0x08, 0x0F, 0x1A, 0x1D, 0x14, 0x13,
        0xAE, 0xA9, 0xA0, 0xA7, 0xB2, 0xB5, 0xBC, 0xBB, 0x96, 0x91, 0x98, 0x9F, 0x8A, 0x8D, 0x84, 0x83,
        0xDE, 0xD9, 0xD0, 0xD7, 0xC2, 0xC5, 0xCC, 0xCB, 0xE6, 0xE1, 0xE8, 0xEF, 0xFA, 0xFD, 0xF4, 0xF3
    ]

    /// CRC8 using the whoomp lookup table
    static func crc8(_ data: Data) -> UInt8 {
        var crc: UInt8 = 0
        for byte in data {
            crc = crc8Table[Int(crc ^ byte)]
        }
        return crc
    }

    /// CRC32 (standard zlib, available via Darwin) — returns as UInt32
    static func crc32(_ data: Data) -> UInt32 {
        // Swift's standard library on Apple platforms includes zlib via Darwin
        var crc: UInt32 = 0
        crc = data.withUnsafeBytes { ptr -> UInt32 in
            let bytes = ptr.bindMemory(to: UInt8.self)
            var result: UInt32 = 0xFFFFFFFF
            for i in 0..<data.count {
                let index = Int((result ^ UInt32(bytes[i])) & 0xFF)
                result = Self.crc32Table[index] ^ (result >> 8)
            }
            return result ^ 0xFFFFFFFF
        }
        return crc
    }

    // Standard CRC32 lookup table (same as zlib)
    private static let crc32Table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = 0xEDB88320 ^ (crc >> 1)
                } else {
                    crc = crc >> 1
                }
            }
            table[i] = crc
        }
        return table
    }()

    /// Build a framed Whoop BLE packet
    ///
    /// Payload: [type(1), seq=10(1), cmd(1)] + data
    /// Frame: SOF(0xAA) + length(2 LE) + crc8(1) + payload + crc32(4 LE)
    /// Length = payload.count + 4 (for the CRC32 trailer)
    static func buildPacket(type: PacketType, cmd: WhoopCommand, data: Data = Data()) -> Data {
        // Build payload: [type, seq=10, cmd] + data
        var payload = Data([type.rawValue, 10, cmd.rawValue])
        payload.append(data)

        // Length = payload + 4 bytes for CRC32 trailer
        let length = UInt16(payload.count + 4)
        var lengthBytes = Data(count: 2)
        lengthBytes[0] = UInt8(length & 0xFF)
        lengthBytes[1] = UInt8(length >> 8)

        // CRC8 over the length bytes only
        let crc8Val = crc8(lengthBytes)

        // CRC32 over payload, stored as little-endian
        let crc32Val = crc32(payload)
        var crc32Bytes = Data(count: 4)
        crc32Bytes[0] = UInt8(crc32Val & 0xFF)
        crc32Bytes[1] = UInt8((crc32Val >> 8) & 0xFF)
        crc32Bytes[2] = UInt8((crc32Val >> 16) & 0xFF)
        crc32Bytes[3] = UInt8((crc32Val >> 24) & 0xFF)

        // Assemble: SOF + length + crc8 + payload + crc32
        var packet = Data([0xAA])
        packet.append(lengthBytes)
        packet.append(crc8Val)
        packet.append(payload)
        packet.append(crc32Bytes)

        return packet
    }

    /// Parse a framed Whoop BLE packet
    static func parsePacket(_ raw: Data) -> WhoopPacket? {
        guard raw.count >= 7, raw[0] == 0xAA else { return nil }

        let length = UInt16(raw[1]) | (UInt16(raw[2]) << 8)
        let payloadEnd = 4 + Int(length) - 4  // subtract CRC32 from length

        guard payloadEnd >= 7, raw.count >= payloadEnd else { return nil }

        let payload = raw[4..<payloadEnd]
        guard payload.count >= 3 else { return nil }

        return WhoopPacket(
            type: payload[payload.startIndex],
            seq: payload[payload.startIndex + 1],
            cmd: payload[payload.startIndex + 2],
            data: payload.count > 3 ? Data(payload[(payload.startIndex + 3)...]) : Data()
        )
    }

    /// Parse realtime HR data (type=40 on DATA characteristic)
    ///
    /// Reconstruct: [cmd] + data[0:7] → unpack as <LHBB (unix, subsec, heart, rrnum)
    /// RR intervals follow at data[7:] as uint16 LE pairs
    static func parseHRData(cmd: UInt8, data: Data) -> HRReading? {
        guard data.count >= 7 else { return nil }

        // Reconstruct 8-byte header: cmd byte + first 7 data bytes
        var recon = Data([cmd])
        recon.append(data[data.startIndex..<(data.startIndex + 7)])

        // Unpack: uint32 LE (unix), uint16 LE (subsec), uint8 (heart), uint8 (rrnum)
        let unix = UInt32(recon[0]) | (UInt32(recon[1]) << 8) | (UInt32(recon[2]) << 16) | (UInt32(recon[3]) << 24)
        // subsec at [4:6] — not needed for storage
        let heart = recon[6]
        let rrnum = recon[7]

        // Extract RR intervals
        var rrIntervals: [UInt16] = []
        if rrnum > 0 {
            let maxRR = min(Int(rrnum), 4)
            for i in 0..<maxRR {
                let offset = data.startIndex + 7 + i * 2
                guard offset + 1 < data.endIndex else { break }
                let rr = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                if rr > 0 {
                    rrIntervals.append(rr)
                }
            }
        }

        return HRReading(
            timestamp: unix,
            heartRate: heart,
            rrIntervals: rrIntervals
        )
    }

    /// Parse battery response: data[2:4] as uint16 LE / 10.0
    static func parseBattery(_ data: Data) -> Double? {
        guard data.count >= 4 else { return nil }
        let raw = UInt16(data[data.startIndex + 2]) | (UInt16(data[data.startIndex + 3]) << 8)
        return Double(raw) / 10.0
    }

    /// Parse clock response: data[2:6] as uint32 LE unix timestamp
    static func parseClock(_ data: Data) -> Date? {
        guard data.count >= 6 else { return nil }
        let offset = data.startIndex + 2
        let unix = UInt32(data[offset]) | (UInt32(data[offset+1]) << 8) | (UInt32(data[offset+2]) << 16) | (UInt32(data[offset+3]) << 24)
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    /// Build command packets for common operations
    static func batteryPacket() -> Data {
        buildPacket(type: .command, cmd: .getBatteryLevel, data: Data([0x00]))
    }

    static func clockPacket() -> Data {
        buildPacket(type: .command, cmd: .getClock, data: Data([0x00]))
    }

    static func startHRPacket() -> Data {
        buildPacket(type: .command, cmd: .toggleRealtimeHR, data: Data([0x01]))
    }

    static func stopHRPacket() -> Data {
        buildPacket(type: .command, cmd: .toggleRealtimeHR, data: Data([0x00]))
    }

    static func helloHarvardPacket() -> Data {
        buildPacket(type: .command, cmd: .getHelloHarvard, data: Data([0x00]))
    }

    /// Set the strap's clock to the current real time
    static func setClockPacket() -> Data {
        let now = UInt32(Date().timeIntervalSince1970)
        let timeData = Data([
            UInt8(now & 0xFF),
            UInt8((now >> 8) & 0xFF),
            UInt8((now >> 16) & 0xFF),
            UInt8((now >> 24) & 0xFF)
        ])
        return buildPacket(type: .command, cmd: .getClock, data: timeData)
    }

    // MARK: - Haptics

    /// List all available haptic patterns on the strap
    static func listHapticsPacket() -> Data {
        buildPacket(type: .command, cmd: .getAllHapticsPattern, data: Data([0x00]))
    }

    /// Run a specific haptic pattern by ID
    static func runHapticsPacket(patternId: UInt8) -> Data {
        buildPacket(type: .command, cmd: .runHapticsPattern, data: Data([patternId]))
    }

    /// Stop any currently playing haptic pattern
    static func stopHapticsPacket() -> Data {
        buildPacket(type: .command, cmd: .stopHaptics, data: Data([0x00]))
    }

    // MARK: - LED / Optical Experiments

    /// Toggle optical mode (may control LEDs for SpO2/visual feedback)
    static func toggleOpticalPacket(mode: UInt8) -> Data {
        buildPacket(type: .command, cmd: .toggleOpticalMode, data: Data([mode]))
    }

    /// Toggle IMU streaming (accelerometer + gyro)
    static func toggleIMUPacket(enable: Bool) -> Data {
        buildPacket(type: .command, cmd: .toggleIMU, data: Data([enable ? 0x01 : 0x00]))
    }

    // MARK: - History Download Protocol

    /// Request the strap to send its stored history buffer
    static func requestHistoryPacket() -> Data {
        buildPacket(type: .command, cmd: .sendHistoricalData, data: Data([0x00]))
    }

    /// Erase the strap's internal history buffer (0x19 ERASE_HISTORY).
    /// Reference frame (bWanShiTong RE): aa1000..23..19 fe×8 00 ..crc32 — payload is
    /// 8 bytes of 0xFE padding + 1 zero byte. DESTRUCTIVE + irreversible. Only used to
    /// clear a stuck/dead backlog the strap keeps re-serving (off-wrist garbage that
    /// blocks the drain from ever reaching "now"). Live streaming is unaffected.
    static func eraseHistoryPacket() -> Data {
        buildPacket(type: .command, cmd: .eraseHistory,
                    data: Data([0xfe, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe, 0x00]))
    }

    /// Acknowledge a history batch and request the next one
    /// - Parameter trim: The trim value from the META_HISTORY_END metadata
    static func historyAckPacket(trim: UInt32) -> Data {
        var ackData = Data([0x01])
        ackData.append(UInt8(trim & 0xFF))
        ackData.append(UInt8((trim >> 8) & 0xFF))
        ackData.append(UInt8((trim >> 16) & 0xFF))
        ackData.append(UInt8((trim >> 24) & 0xFF))
        ackData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return buildPacket(type: .command, cmd: .historyAck, data: ackData)
    }

    /// Parse a historical data record (type 47)
    /// Returns HRReading with timestamp, HR, and up to 4 RR intervals
    ///
    /// Python ref: struct.unpack("<LHLB", pdata[4:15])
    /// Layout: [4 skip] [unix uint32=4B] [subsec uint16=2B] [unk uint32=4B] [hr uint8=1B]
    /// Then:   pdata[15] = rrnum, pdata[16:24] = rr1-4 as uint16 LE
    /// v142 — upper bound added. Firmware 41.x sends 73-byte raw waveform frames on
    /// the same type/cmd; byte 14 there is a constant 0/1, not HR, so this parser
    /// must never see them (see historyFrameKind).
    static func parseHistoricalRecord(data: Data) -> HRReading? {
        guard data.count >= 24, data.count < 70 else { return nil }

        let s = data.startIndex
        // pdata[4:8] = unix timestamp (uint32 LE)
        let unix = UInt32(data[s+4]) | (UInt32(data[s+5]) << 8) |
                   (UInt32(data[s+6]) << 16) | (UInt32(data[s+7]) << 24)
        // pdata[8:10] = subsec (uint16 LE) — skip
        // pdata[10:14] = unk (uint32 LE) — skip (NOT uint16!)
        // pdata[14] = heart rate (uint8)
        let heart = data[s + 14]
        // pdata[15] = RR count
        let rrnum = data[s + 15]
        // pdata[16:24] = up to 4 RR intervals (uint16 LE each)
        var rrIntervals: [UInt16] = []
        if rrnum > 0 {
            let maxRR = min(Int(rrnum), 4)
            for i in 0..<maxRR {
                let rrOffset = s + 16 + i * 2
                guard rrOffset + 1 < data.endIndex else { break }
                let rr = UInt16(data[rrOffset]) | (UInt16(data[rrOffset + 1]) << 8)
                if rr > 0 { rrIntervals.append(rr) }
            }
        }

        return HRReading(timestamp: unix, heartRate: heart, rrIntervals: rrIntervals)
    }

    /// The frame shapes firmware 41.x serves on type=47. Discriminating on length
    /// alone was the bug: `count >= 70` swept the 93-byte status frames into the
    /// raw-waveform stub together with the 73-byte PPG frames, so the one shape
    /// that does carry heart rate was discarded along with the one that doesn't.
    enum HistoryFrameKind {
        case legacyRecord   // < 70 bytes — the original <LHLB> cooked record
        case statusWithHR   // cmd 5/7, 93 bytes — cooked HR at byte 14
        case rawWaveform    // cmd 0, 73 bytes — raw optical waveform, no HR in it
    }

    static func historyFrameKind(cmd: UInt8, data: Data) -> HistoryFrameKind {
        if data.count >= 90 && (cmd == 5 || cmd == 7) { return .statusWithHR }
        if data.count >= 70 { return .rawWaveform }
        return .legacyRecord
    }

    /// Firmware-41.x status frame (type=47, cmd=5 or 7, len=93), emitted once per
    /// second alongside the raw waveform.
    ///
    /// Layout: [0:4] record counter · [4:8] unix uint32 LE · [8:12] microseconds
    /// [12:14] uint16 · [14] heart rate · then float32 triples holding a unit
    /// gravity vector (magnitude 1.0, which is what identified them).
    ///
    /// Byte 14 was verified against ground truth before being trusted, because a
    /// wrong guess here feeds invented HR straight into recovery scores. Compared
    /// to 15,208 realtime_health samples the strap never saw: r = 0.90, mean abs
    /// error 4.35 bpm. Time-shifted controls separate cleanly — aligned MAE 5.3 bpm
    /// vs 13.7 at +20 min, 15.1 at +1 h, 19.7 at -3 h — so the field is genuinely
    /// time-locked heart rate and not two HR-shaped series happening to agree.
    ///
    /// Carries no RR intervals, so history can restore HR but never HRV.
    static func parseHistoricalStatusFrame(data: Data) -> HRReading? {
        guard data.count >= 16 else { return nil }
        let s = data.startIndex
        let unix = UInt32(data[s+4]) | (UInt32(data[s+5]) << 8) |
                   (UInt32(data[s+6]) << 16) | (UInt32(data[s+7]) << 24)
        let hr = data[s + 14]
        // 0 means off-wrist. Anything outside a plausible human range is a layout
        // surprise rather than a reading, and is dropped instead of stored.
        guard hr >= 30, hr <= 220 else { return nil }
        guard unix > 1_600_000_000 else { return nil }
        return HRReading(timestamp: unix, heartRate: hr, rrIntervals: [])
    }

    /// Firmware-41.x raw waveform frame (cmd 0, 73 bytes): ~28 int16 optical
    /// samples per second. Heart rate is not cooked into it — recovering HR would
    /// mean running a full PPG pipeline, and the status frame above already
    /// carries the strap's own answer at the same 1 Hz. Deliberately returns nil.
    static func parseHistoricalRawFrame(data: Data) -> HRReading? {
        return nil
    }

    /// Parse history batch metadata (type 49, cmd 2 = META_HISTORY_END)
    /// Returns the trim value needed for acknowledgment
    static func parseHistoryMetadata(data: Data) -> UInt32? {
        // Python: unix, subsec, unk0, trim = struct.unpack("<LHHL", pkt.data[:12])
        guard data.count >= 12 else { return nil }
        let offset = data.startIndex + 8  // skip unix(4) + subsec(2) + unk(2)
        let trim = UInt32(data[offset]) | (UInt32(data[offset+1]) << 8) |
                   (UInt32(data[offset+2]) << 16) | (UInt32(data[offset+3]) << 24)
        return trim
    }

    // MARK: - Extended Command Builders (v66 — Whoop full signal capture)

    static func firmwareVersionPacket() -> Data {
        buildPacket(type: .command, cmd: .reportVersionInfo, data: Data([0x00]))
    }

    static func extendedBatteryPacket() -> Data {
        buildPacket(type: .command, cmd: .getExtendedBatteryInfo, data: Data([0x00]))
    }

    static func bodyLocationPacket() -> Data {
        buildPacket(type: .command, cmd: .getBodyLocationAndStatus, data: Data([0x00]))
    }

    static func selectWristPacket(right: Bool) -> Data {
        buildPacket(type: .command, cmd: .selectWrist, data: Data([right ? 0x01 : 0x00]))
    }

    static func startRawOpticalPacket() -> Data {
        buildPacket(type: .command, cmd: .startRawData, data: Data([0x00]))
    }

    static func stopRawOpticalPacket() -> Data {
        buildPacket(type: .command, cmd: .stopRawData, data: Data([0x00]))
    }

    // MARK: - IMU Parsing (type 51 realtime, type 52 historical)
    //
    // Verified layout from whoomp RawDataStreamResult (decompiled Whoop app):
    //   [unix uint32 LE][subsec uint16 LE][heart_rate int32 LE]
    //   [accel_x int16 LE][accel_y int16 LE][accel_z int16 LE]
    //   [gyro_x  int16 LE][gyro_y  int16 LE][gyro_z  int16 LE]
    //   ... more triplets (batched frames per packet)
    // Scale: ±4g → 8192 LSB/g for accel; ±250 dps → 131 LSB/dps for gyro.
    // Stride: 12 bytes (6× int16) per additional frame after the first.

    struct IMUFrame {
        let timestamp: UInt32   // seconds since epoch
        let heartRate: Int32    // carried in packet header (verified vs HR stream)
        let accelX: Int16
        let accelY: Int16
        let accelZ: Int16
        let gyroX: Int16
        let gyroY: Int16
        let gyroZ: Int16

        /// Accel magnitude in milli-g (assuming ±4g → 8192 LSB/g)
        var accelMagnitudeMg: Int {
            let ax = Double(accelX) / 8.192   // → mg
            let ay = Double(accelY) / 8.192
            let az = Double(accelZ) / 8.192
            return Int((ax * ax + ay * ay + az * az).squareRoot())
        }

        /// Normalized movement score 0..1 (1g = still, deviation = movement).
        var movementScore: Double {
            let deviation = abs(Double(accelMagnitudeMg) - 1000.0)
            return min(1.0, deviation / 2000.0)
        }
    }

    /// Parse one or more IMU frames from a type-51 realtime packet.
    /// Uses the verified whoomp layout. Header is 10 bytes (unix + subsec + int32 HR).
    static func parseIMUPacket(cmd: UInt8, data: Data) -> [IMUFrame] {
        var recon = Data([cmd])
        recon.append(data)
        guard recon.count >= 22 else { return [] }  // 10-byte header + at least 1 frame

        let unix = UInt32(recon[0]) | (UInt32(recon[1]) << 8) |
                   (UInt32(recon[2]) << 16) | (UInt32(recon[3]) << 24)
        if unix < 1_600_000_000 || unix > 2_500_000_000 { return [] }

        let hr = Int32(bitPattern:
            UInt32(recon[6])  | (UInt32(recon[7]) << 8) |
            (UInt32(recon[8]) << 16) | (UInt32(recon[9]) << 24)
        )

        var frames: [IMUFrame] = []
        let headerLen = 10
        let frameStride = 12

        var i = recon.startIndex + headerLen
        while i + frameStride <= recon.endIndex {
            let ax = Int16(bitPattern: UInt16(recon[i])   | (UInt16(recon[i+1]) << 8))
            let ay = Int16(bitPattern: UInt16(recon[i+2]) | (UInt16(recon[i+3]) << 8))
            let az = Int16(bitPattern: UInt16(recon[i+4]) | (UInt16(recon[i+5]) << 8))
            let gx = Int16(bitPattern: UInt16(recon[i+6]) | (UInt16(recon[i+7]) << 8))
            let gy = Int16(bitPattern: UInt16(recon[i+8]) | (UInt16(recon[i+9]) << 8))
            let gz = Int16(bitPattern: UInt16(recon[i+10]) | (UInt16(recon[i+11]) << 8))

            frames.append(IMUFrame(
                timestamp: unix,
                heartRate: hr,
                accelX: ax, accelY: ay, accelZ: az,
                gyroX: gx, gyroY: gy, gyroZ: gz
            ))
            i += frameStride
        }
        return frames
    }

    // MARK: - MAX77818 ModelGauge m5 Decoder (verified register map)
    //
    // CMD 98 GET_EXTENDED_BATTERY_INFO returns a dump of the fuel-gauge registers.
    // Register offsets / scales (Maxim MAX77818 datasheet):
    //   0x06 RepSOC   — uint16, 1/256 % per LSB
    //   0x07 Age      — uint16, 1/256 % per LSB (State of Health, full-cap ratio)
    //   0x09 VCell    — uint16, 78.125 µV per LSB
    //   0x17 Cycles   — uint16, 1% per LSB (older rev = 0.16%, but reading as uint16 is consistent)
    // Whoop's response packet is not fully documented — empirically, the register
    // block starts at a small offset (often 2-4 bytes after the command byte).
    // We scan the first ~16 bytes looking for plausible values at the known offsets.
    struct ExtendedBattery {
        let voltageMv: Int?
        let socPct: Double?           // state of charge
        let stateOfHealthPct: Int?
        let cycleCount: Int?
    }
    static func parseExtendedBattery(_ data: Data) -> ExtendedBattery {
        // Read uint16 LE at an absolute data offset with bounds check.
        func u16(_ offset: Int) -> Int? {
            let start = data.startIndex + offset
            guard start + 1 < data.endIndex else { return nil }
            return Int(data[start]) | (Int(data[start + 1]) << 8)
        }

        // Try common base offsets for the register block. Whoop typically prefixes the
        // response with 2-4 bytes of packet metadata before the raw register read-out.
        for base in [0, 2, 4] {
            // VCell at base+0x09 (each reg = 2 bytes) — scaled 78.125 µV/LSB.
            guard let vRaw = u16(base + 0x09 * 2) else { continue }
            let mv = Int(Double(vRaw) * 78.125 / 1000.0)
            guard mv > 2500 && mv < 5000 else { continue }   // sanity gate

            let socRaw = u16(base + 0x06 * 2) ?? 0
            let socPct = Double(socRaw) / 256.0

            let ageRaw = u16(base + 0x07 * 2) ?? 0
            let soh = Int(Double(ageRaw) / 256.0)

            let cyclesRaw = u16(base + 0x17 * 2) ?? 0
            let cycles = cyclesRaw

            return ExtendedBattery(
                voltageMv: mv,
                socPct: socPct > 0 && socPct <= 100 ? socPct : nil,
                stateOfHealthPct: soh > 0 && soh <= 100 ? soh : nil,
                cycleCount: cycles >= 0 && cycles < 10000 ? cycles : nil
            )
        }
        return ExtendedBattery(voltageMv: nil, socPct: nil, stateOfHealthPct: nil, cycleCount: nil)
    }

    // MARK: - PPG / Raw Optical Decoder (type-43 packets)
    //
    // MAX86171 FIFO format (Maxim datasheet §8.8.1):
    //   Each sample = 3 bytes.
    //     byte0 bits [7:5] = sample tag high bits
    //     byte0 bits [4:0] = ADC value bits [18:14]
    //     byte1            = ADC value bits [13:6]
    //     byte2 bits [7:2] = ADC value bits [5:0]
    //     byte2 bits [1:0] = sample tag low bits
    //   Effectively: [5-bit tag][19-bit signed ADC] packed across 3 bytes big-endian.
    // Whoop wraps a batch of these samples with a timestamp header similar to the IMU layout.

    enum PPGChannel: Int {
        case green1 = 1, green2 = 2, green3 = 3
        case red = 4, infrared = 5
        case unknown = 0
    }

    struct PPGSample {
        let timestamp: UInt32
        let channel: PPGChannel
        let adc: Int32            // 19-bit signed, promoted to int32
    }

    /// Parse a type-43 raw optical packet into per-channel samples.
    /// Header format mirrors IMU: uint32 unix + uint16 subsec + optional bytes.
    /// Body = repeated 3-byte MAX86171 FIFO words.
    static func parsePPGPacket(cmd: UInt8, data: Data) -> [PPGSample] {
        var recon = Data([cmd])
        recon.append(data)
        guard recon.count >= 9 else { return [] }   // 6-byte header + at least one 3-byte word

        let unix = UInt32(recon[0]) | (UInt32(recon[1]) << 8) |
                   (UInt32(recon[2]) << 16) | (UInt32(recon[3]) << 24)
        if unix < 1_600_000_000 || unix > 2_500_000_000 { return [] }

        // Try two header lengths: 6 (timestamp+subsec) and 10 (with int32 extra field).
        for headerLen in [6, 10] {
            var out: [PPGSample] = []
            var i = recon.startIndex + headerLen
            while i + 3 <= recon.endIndex {
                let b0 = UInt32(recon[i])
                let b1 = UInt32(recon[i + 1])
                let b2 = UInt32(recon[i + 2])

                // Tag: 5 high bits of byte0 concatenated with 2 low bits of byte2? Some
                // MAX86171 revs split the tag across bits. Whoop's actual split is not
                // fully published — use bits [23:19] of the 24-bit word as the channel tag,
                // which matches the datasheet in "sample-tag-only" mode.
                let word = (b0 << 16) | (b1 << 8) | b2
                let tag = Int((word >> 19) & 0x1F)

                // ADC: bits [18:0] sign-extended from 19-bit.
                var adc = Int32(word & 0x7FFFF)
                if adc & 0x40000 != 0 { adc -= 0x80000 }

                let channel: PPGChannel = {
                    switch tag {
                    case 1, 2, 3: return .green1    // grouped green channels
                    case 4: return .red
                    case 5: return .infrared
                    default: return .unknown
                    }
                }()

                out.append(PPGSample(timestamp: unix, channel: channel, adc: adc))
                i += 3
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    // MARK: - Empirical Probe Builders
    //
    // These send commands whose responses we want to capture raw for later analysis.
    // Responses land in whoop_events as raw_bytes so we can mine them later.

    /// Build a command packet for an arbitrary CMD byte NOT defined in WhoopCommand.
    /// Needed for probes (CMD 124/125/132/139) since we don't want to pollute the enum
    /// with experimental commands.
    static func buildRawCommandPacket(cmd: UInt8, data: Data = Data([0x00])) -> Data {
        var payload = Data([PacketType.command.rawValue, 10, cmd])
        payload.append(data)
        let length = UInt16(payload.count + 4)
        var lengthBytes = Data(count: 2)
        lengthBytes[0] = UInt8(length & 0xFF)
        lengthBytes[1] = UInt8(length >> 8)
        let crc8Val = crc8(lengthBytes)
        let crc32Val = crc32(payload)
        var crc32Bytes = Data(count: 4)
        crc32Bytes[0] = UInt8(crc32Val & 0xFF)
        crc32Bytes[1] = UInt8((crc32Val >> 8) & 0xFF)
        crc32Bytes[2] = UInt8((crc32Val >> 16) & 0xFF)
        crc32Bytes[3] = UInt8((crc32Val >> 24) & 0xFF)
        var packet = Data([0xAA])
        packet.append(lengthBytes)
        packet.append(crc8Val)
        packet.append(payload)
        packet.append(crc32Bytes)
        return packet
    }

    /// CMD 132 — GET_RESEARCH_PACKET.
    static func getResearchPacket() -> Data {
        buildRawCommandPacket(cmd: 132)
    }

    /// CMD 124 — TOGGLE_LABRADOR_DATA_GENERATION.
    static func labradorDataGenPacket(enable: Bool) -> Data {
        buildRawCommandPacket(cmd: 124, data: Data([enable ? 0x01 : 0x00]))
    }

    /// CMD 125 — TOGGLE_LABRADOR_RAW_SAVE.
    static func labradorRawSavePacket(enable: Bool) -> Data {
        buildRawCommandPacket(cmd: 125, data: Data([enable ? 0x01 : 0x00]))
    }

    /// CMD 139 — TOGGLE_LABRADOR_FILTERED.
    static func labradorFilteredPacket(enable: Bool) -> Data {
        buildRawCommandPacket(cmd: 139, data: Data([enable ? 0x01 : 0x00]))
    }

    /// CMD 107 — ENABLE_OPTICAL_DATA.
    /// Community RE (bWanShiTong, 2026) hypothesises this is the required
    /// precursor that tells the MAX86171 AFE to start pushing optical frames
    /// into the BLE pipeline. Expected to be sent BEFORE CMD 81 (START_RAW_DATA).
    static func enableOpticalDataPacket(enable: Bool = true) -> Data {
        buildRawCommandPacket(cmd: 107, data: Data([enable ? 0x01 : 0x00]))
    }

    /// CMD 108 — TOGGLE_OPTICAL_MODE.
    /// Switches the optical front-end between modes (likely HR vs raw-PPG).
    static func toggleOpticalModePacket(enable: Bool = true) -> Data {
        buildRawCommandPacket(cmd: 108, data: Data([enable ? 0x01 : 0x00]))
    }

    // MARK: - Realtime Temperature (decode_1c subtype 0x31)
    //
    // Skin temperature streams continuously on packet type 49 (0x31) — what our
    // enum previously called "metadata". bWanShiTong's misc.py exposes the layout:
    //   data[0..3]  = unix timestamp (LE)
    //   data[4..9]  = temperature raw int48 LE; divide by 100,000 = °C
    // Source: bWanShiTong/reverse-engineering-whoop misc.py → decode_1c.
    //
    // Accept range clamped to [20°C, 45°C] — everything outside is treated as
    // a non-temperature type-49 packet (e.g., actual metadata during history sync).
    static func parseRealtimeTemperature(data: Data) -> Double? {
        guard data.count >= 10 else { return nil }
        var rawInt: UInt64 = 0
        for i in 0..<6 {
            rawInt |= UInt64(data[4 + i]) << (8 * i)
        }
        let tempC = Double(rawInt) / 100_000.0
        return (tempC >= 20.0 && tempC <= 45.0) ? tempC : nil
    }

    // MARK: - Type-47 "decode_5c" Full Sensor Packet (v70)
    //
    // Observed on Fabi's strap in v1.1.41 firmware: packet type 47 (HISTORICAL_DATA
    // per our enum), length 93 bytes, arriving in bursts after BLE reconnect.
    //
    // Byte-variance analysis across 50 samples revealed 25+ bytes with range 195-255
    // in the [26..85] region — dynamic signal data, not padding.
    //
    // Layout (empirical, from 5 samples):
    //   [0..1]   = packet sequence / type indicator (varies)
    //   [2..3]   = "0003" constant — subtype marker
    //   [4..7]   = unix timestamp seconds LE
    //   [8..11]  = unix timestamp sub-second LE
    //   [12]     = 0x4A constant flag
    //   [13]     = 0x01 constant flag
    //   [14..15] = incrementing counter (u16 LE)
    //   [16..25] = 10 bytes of zero padding
    //   [26..85] = 60 bytes of IEEE-754 float data (15 × 4-byte LE floats)
    //   [86..92] = 7 bytes trailing (alignment / next-chunk marker)
    //
    // The 15 floats likely represent: accelerometer XYZ, gyroscope XYZ, PPG channels
    // (green1/2/3 + red + IR normalised), optional skin temp / derived signals.
    // Ordering TBD — correlate with motion vs stillness to identify XYZ axes.
    struct Type47Decoded {
        let seq: UInt16
        let timestamp: UInt32
        let timestampFrac: UInt32
        let counter: UInt16
        let floats: [Float]     // 15 values from bytes [26..85]
        let trailingHex: String
    }

    static func parseType47Packet(_ data: Data) -> Type47Decoded? {
        guard data.count >= 93 else { return nil }
        let seq = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let ts = UInt32(data[4]) | (UInt32(data[5]) << 8) | (UInt32(data[6]) << 16) | (UInt32(data[7]) << 24)
        let tsFrac = UInt32(data[8]) | (UInt32(data[9]) << 8) | (UInt32(data[10]) << 16) | (UInt32(data[11]) << 24)
        let counter = UInt16(data[14]) | (UInt16(data[15]) << 8)

        var floats: [Float] = []
        floats.reserveCapacity(15)
        for i in 0..<15 {
            let offset = 26 + i * 4
            let raw = UInt32(data[offset])
                   | (UInt32(data[offset+1]) << 8)
                   | (UInt32(data[offset+2]) << 16)
                   | (UInt32(data[offset+3]) << 24)
            floats.append(Float(bitPattern: raw))
        }

        let trailing = data[86..<93].map { String(format: "%02x", $0) }.joined()
        return Type47Decoded(
            seq: seq,
            timestamp: ts,
            timestampFrac: tsFrac,
            counter: counter,
            floats: floats,
            trailingHex: trailing
        )
    }

    // MARK: - Payload-variant probe builders (v69)
    //
    // CMD 131 (SET_RESEARCH_PACKET) returned status 0 with our [0x00] payload.
    // Different payload bytes may unlock different research modes.
    static func setResearchPacket(_ value: UInt8) -> Data {
        buildRawCommandPacket(cmd: 131, data: Data([value]))
    }

    // CMD 107 (ENABLE_OPTICAL_DATA) returned `0a 01 01 00 00` with our [0x01].
    // Try other modes — the trailing 0x01 in the response might be "currently enabled"
    // meaning we need a different payload to actually start the raw stream.
    static func enableOpticalDataRaw(_ value: UInt8) -> Data {
        buildRawCommandPacket(cmd: 107, data: Data([value]))
    }

    // CMD 41 (SET_TIA_GAIN) returned status 0 with our [0x00] payload.
    // Gain values 0-7 or 0-15 depending on MAX86171 register config. Try a sweep.
    static func setTiaGain(_ value: UInt8) -> Data {
        buildRawCommandPacket(cmd: 41, data: Data([value]))
    }

    // CMD 39 (SET_LED_DRIVE) — configure PPG LED current. Values 0-255.
    static func setLedDrive(_ value: UInt8) -> Data {
        buildRawCommandPacket(cmd: 39, data: Data([value]))
    }

    // MARK: - Firmware Version (dual-MCU decode)
    //
    // CMD 7 response is 3 status bytes + 16 × uint32-LE:
    //   fields[0..3] = Harvard (MAX32652 MCU) version — our "user-visible" firmware
    //   fields[4..7] = Boylston (nRF52840 BLE chip) version
    //   fields[8..15] = build metadata (unknown)
    // Source: jogolden/whoomp packet.js → parseVersionData.
    static func decodeFirmwareVersion(from data: Data) -> (harvard: String, boylston: String, meta: [UInt32])? {
        // Skip first 3 bytes of header/status, then read 16 × u32 LE.
        guard data.count >= 3 + 16 * 4 else { return nil }
        var fields: [UInt32] = []
        var i = 3
        while i + 4 <= data.endIndex && fields.count < 16 {
            let v = UInt32(data[i]) | (UInt32(data[i+1]) << 8) | (UInt32(data[i+2]) << 16) | (UInt32(data[i+3]) << 24)
            fields.append(v)
            i += 4
        }
        guard fields.count >= 8 else { return nil }
        let harvard = "\(fields[0]).\(fields[1]).\(fields[2]).\(fields[3])"
        let boylston = "\(fields[4]).\(fields[5]).\(fields[6]).\(fields[7])"
        let meta = Array(fields.dropFirst(8))
        return (harvard, boylston, meta)
    }
}

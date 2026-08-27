import Foundation

extension GameCore {
    nonisolated enum StrictJSON {
        struct ValidationError: Error, Equatable, Sendable {
            let detail: String
        }

        static func object(from data: Data) throws -> Any {
            var parser = Parser(data: data)
            try parser.validate()
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }

        static func canonicalData(_ value: Any) throws -> Data {
            Data(try canonicalString(value).utf8)
        }

        private static func canonicalString(_ value: Any) throws -> String {
            if value is NSNull {
                return "null"
            }
            if let string = value as? String {
                let data = try JSONSerialization.data(
                    withJSONObject: string,
                    options: [.fragmentsAllowed, .withoutEscapingSlashes]
                )
                guard let encoded = String(data: data, encoding: .utf8) else {
                    throw ValidationError(detail: "String is not valid UTF-8")
                }
                return encoded
            }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return number.boolValue ? "true" : "false"
                }
                guard number.doubleValue.isFinite else {
                    throw ValidationError(detail: "Non-finite number")
                }
                return number.stringValue
            }
            if let array = value as? [Any] {
                return "[" + (try array.map(canonicalString)).joined(separator: ",") + "]"
            }
            if let object = value as? [String: Any] {
                let entries = try object.keys.sorted().map { key in
                    try canonicalString(key) + ":" + canonicalString(object[key] as Any)
                }
                return "{" + entries.joined(separator: ",") + "}"
            }
            throw ValidationError(detail: "Unsupported JSON value")
        }

        private struct Parser {
            let bytes: [UInt8]
            var index = 0

            init(data: Data) {
                bytes = Array(data)
            }

            mutating func validate() throws {
                skipWhitespace()
                try parseValue()
                skipWhitespace()
                guard index == bytes.count else {
                    throw ValidationError(detail: "Trailing content after JSON value")
                }
            }

            mutating func parseValue() throws {
                guard let byte = current else {
                    throw ValidationError(detail: "Unexpected end of JSON")
                }
                switch byte {
                case 0x7B: try parseObject()
                case 0x5B: try parseArray()
                case 0x22: _ = try parseString()
                case 0x74: try consume(Array("true".utf8))
                case 0x66: try consume(Array("false".utf8))
                case 0x6E: try consume(Array("null".utf8))
                case 0x2D, 0x30 ... 0x39: try parseNumber()
                default: throw ValidationError(detail: "Invalid JSON token")
                }
            }

            mutating func parseObject() throws {
                index += 1
                skipWhitespace()
                var keys: Set<String> = []
                if consumeIf(0x7D) { return }
                while true {
                    guard current == 0x22 else {
                        throw ValidationError(detail: "Object key must be a string")
                    }
                    let key = try parseString()
                    guard keys.insert(key).inserted else {
                        throw ValidationError(detail: "Duplicate JSON key: \(key)")
                    }
                    skipWhitespace()
                    try require(0x3A)
                    skipWhitespace()
                    try parseValue()
                    skipWhitespace()
                    if consumeIf(0x7D) { return }
                    try require(0x2C)
                    skipWhitespace()
                }
            }

            mutating func parseArray() throws {
                index += 1
                skipWhitespace()
                if consumeIf(0x5D) { return }
                while true {
                    try parseValue()
                    skipWhitespace()
                    if consumeIf(0x5D) { return }
                    try require(0x2C)
                    skipWhitespace()
                }
            }

            mutating func parseString() throws -> String {
                let start = index
                try require(0x22)
                while let byte = current {
                    if byte == 0x22 {
                        index += 1
                        let data = Data(bytes[start ..< index])
                        guard let value = try JSONSerialization.jsonObject(
                            with: data,
                            options: [.fragmentsAllowed]
                        ) as? String else {
                            throw ValidationError(detail: "Invalid JSON string")
                        }
                        return value
                    }
                    if byte < 0x20 {
                        throw ValidationError(detail: "Unescaped control character in string")
                    }
                    if byte == 0x5C {
                        index += 1
                        guard let escape = current else {
                            throw ValidationError(detail: "Incomplete string escape")
                        }
                        if escape == 0x75 {
                            index += 1
                            for _ in 0 ..< 4 {
                                guard let hex = current,
                                    (0x30 ... 0x39).contains(hex)
                                        || (0x41 ... 0x46).contains(hex)
                                        || (0x61 ... 0x66).contains(hex)
                                else {
                                    throw ValidationError(detail: "Invalid Unicode escape")
                                }
                                index += 1
                            }
                            continue
                        }
                        guard [0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape) else {
                            throw ValidationError(detail: "Invalid string escape")
                        }
                    }
                    index += 1
                }
                throw ValidationError(detail: "Unterminated JSON string")
            }

            mutating func parseNumber() throws {
                if consumeIf(0x2D), current == nil {
                    throw ValidationError(detail: "Incomplete number")
                }
                if consumeIf(0x30) {
                    if let current, (0x30 ... 0x39).contains(current) {
                        throw ValidationError(detail: "Leading zero in number")
                    }
                } else {
                    try consumeDigits(requireAtLeastOne: true)
                }
                if consumeIf(0x2E) {
                    try consumeDigits(requireAtLeastOne: true)
                }
                if consumeIf(0x65) || consumeIf(0x45) {
                    _ = consumeIf(0x2B) || consumeIf(0x2D)
                    try consumeDigits(requireAtLeastOne: true)
                }
            }

            mutating func consumeDigits(requireAtLeastOne: Bool) throws {
                let start = index
                while let current, (0x30 ... 0x39).contains(current) {
                    index += 1
                }
                if requireAtLeastOne, index == start {
                    throw ValidationError(detail: "Number requires digits")
                }
            }

            mutating func consume(_ expected: [UInt8]) throws {
                guard index + expected.count <= bytes.count,
                    Array(bytes[index ..< index + expected.count]) == expected
                else {
                    throw ValidationError(detail: "Invalid JSON literal")
                }
                index += expected.count
            }

            mutating func require(_ byte: UInt8) throws {
                guard consumeIf(byte) else {
                    throw ValidationError(detail: "Unexpected JSON punctuation")
                }
            }

            mutating func skipWhitespace() {
                while let current, [0x20, 0x09, 0x0A, 0x0D].contains(current) {
                    index += 1
                }
            }

            mutating func consumeIf(_ byte: UInt8) -> Bool {
                guard current == byte else { return false }
                index += 1
                return true
            }

            var current: UInt8? {
                index < bytes.count ? bytes[index] : nil
            }
        }
    }
}

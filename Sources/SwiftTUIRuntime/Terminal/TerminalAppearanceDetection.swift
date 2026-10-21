import SwiftTUICore

package enum TerminalAppearanceQuery: Hashable, Sendable {
  case foreground
  case background
  case palette(index: Int)

  /// The colours an appearance probe asks for, in the order it asks.
  static let probed: [Self] =
    [.foreground, .background] + [1, 2, 3, 4, 6, 8].map { .palette(index: $0) }

  /// Parses the payload of an OSC 10, 11 or 4 colour reply (the bytes
  /// between `ESC ]` and the BEL/ST terminator), such as
  /// `11;rgb:2828/2a2a/3636`.
  static func parseReply(
    payload: some Collection<UInt8>
  ) -> (query: Self, color: Color)? {
    guard let text = strictUTF8String(from: Array(payload)) else {
      return nil
    }
    let fields = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
    let query: Self
    let spec: Substring
    switch (fields.first.map(String.init) ?? "", fields.count) {
    case ("10", 2):
      query = .foreground
      spec = fields[1]
    case ("11", 2):
      query = .background
      spec = fields[1]
    case ("4", 3):
      guard let index = Int(fields[1]), (0...255).contains(index) else {
        return nil
      }
      query = .palette(index: index)
      spec = fields[2]
    default:
      return nil
    }
    guard let color = query.parseColor(from: String(spec)) else {
      return nil
    }
    return (query, color)
  }

  var request: String {
    switch self {
    case .foreground:
      return "\u{001B}]10;?\u{0007}"
    case .background:
      return "\u{001B}]11;?\u{0007}"
    case .palette(let index):
      return "\u{001B}]4;\(index);?\u{0007}"
    }
  }

  private var responsePrefix: String {
    switch self {
    case .foreground:
      return "\u{001B}]10;"
    case .background:
      return "\u{001B}]11;"
    case .palette(let index):
      return "\u{001B}]4;\(index);"
    }
  }

  func extractResponse(
    from bytes: [UInt8]
  ) -> String? {
    guard let response = strictUTF8String(from: bytes),
      let range = response.firstLiteralRange(of: responsePrefix)
    else {
      return nil
    }

    let suffixText = String(response[range.upperBound...])
    // A reply must be terminated (BEL or ST) before the next OSC introducer
    // begins a new reply; scanning past it would let an unterminated reply
    // borrow the following reply's terminator.
    let boundary =
      suffixText.firstLiteralRange(of: "\u{001B}]")?.lowerBound ?? suffixText.endIndex
    let bounded = String(suffixText[..<boundary])

    if let bellIndex = bounded.firstIndex(of: "\u{0007}") {
      return String(bounded[..<bellIndex])
    }

    if let stRange = bounded.firstLiteralRange(of: "\u{001B}\\") {
      return String(bounded[..<stRange.lowerBound])
    }

    return nil
  }

  func parseColor(
    from response: String
  ) -> Color? {
    let trimmed = response.trimmedUnicodeWhitespace()
    if let rgbIndex = trimmed.firstLiteralRange(of: "rgb:") {
      return parseRGBSpec(String(trimmed[rgbIndex.upperBound...]))
    }

    return parseHexSpec(trimmed)
  }
}

extension TerminalAppearance {
  static func detect(
    environment: [String: String],
    capabilityProfile: TerminalCapabilityProfile,
    queryColor: ((TerminalAppearanceQuery) throws -> Color?)? = nil
  ) -> Self {
    let heuristic = heuristicAppearance(
      environment: environment,
      capabilityProfile: capabilityProfile
    )

    guard let queryColor else {
      return heuristic
    }

    do {
      var replies: [TerminalAppearanceQuery: Color] = [:]
      for query in TerminalAppearanceQuery.probed {
        if let color = try queryColor(query) {
          replies[query] = color
        }
      }
      return heuristic.applying(replies)
    } catch {
      return heuristic
    }
  }

  /// Returns this appearance with the queried colours replaced. Colours the
  /// terminal did not answer for keep their current values.
  func applying(
    _ replies: [TerminalAppearanceQuery: Color]
  ) -> Self {
    var palette = self.palette
    for case (.palette(let index), let color) in replies {
      palette[index] = color
    }
    return .init(
      foregroundColor: replies[.foreground] ?? foregroundColor,
      backgroundColor: replies[.background] ?? backgroundColor,
      tintColor: palette[4] ?? palette[6] ?? tintColor,
      palette: palette,
      source: .activeQuery
    )
  }

  private static func heuristicAppearance(
    environment: [String: String],
    capabilityProfile _: TerminalCapabilityProfile
  ) -> Self {
    let palette = defaultPalette

    if let colorFGBG = environment["COLORFGBG"] {
      let values =
        colorFGBG
        .split(whereSeparator: { $0 == ";" || $0 == ":" })
        .compactMap { Int($0) }

      if values.count >= 2 {
        let foregroundIndex = values[values.count - 2]
        let backgroundIndex = values[values.count - 1]
        let foreground = palette[foregroundIndex] ?? fallback.foregroundColor
        let background = palette[backgroundIndex] ?? fallback.backgroundColor
        return .init(
          foregroundColor: foreground,
          backgroundColor: background,
          tintColor: palette[4] ?? fallback.tintColor,
          palette: palette,
          source: .environmentHeuristics
        )
      }
    }

    return .init(
      foregroundColor: fallback.foregroundColor,
      backgroundColor: fallback.backgroundColor,
      tintColor: palette[4] ?? fallback.tintColor,
      palette: palette,
      source: .fallback
    )
  }
}

private func parseRGBSpec(
  _ spec: String
) -> Color? {
  let components = spec.split(separator: "/")
  guard components.count == 3 else {
    return nil
  }

  let values = components.compactMap(parseHexComponentNormalized)
  guard values.count == 3 else {
    return nil
  }

  return .init(red: values[0], green: values[1], blue: values[2])
}

private func parseHexSpec(
  _ spec: String
) -> Color? {
  try? Color(hex: spec)
}

private func parseHexComponentNormalized(
  _ raw: Substring
) -> Double? {
  // `Int(_, radix:)` admits a leading sign, so a component like "-1" would
  // parse to a negative channel value. A hex color component is unsigned:
  // reject anything that is not purely hex digits.
  guard !raw.isEmpty, raw.allSatisfy(\.isHexDigit) else {
    return nil
  }
  let text = String(raw)
  guard let value = Int(text, radix: 16) else {
    return nil
  }

  let maxValue = Int(powDouble(16, Double(text.count))) - 1
  guard maxValue > 0 else {
    return nil
  }

  return Double(value) / Double(maxValue)
}

private func strictUTF8String(
  from bytes: [UInt8]
) -> String? {
  let decoded = String(decoding: bytes, as: UTF8.self)
  return Array(decoded.utf8) == bytes ? decoded : nil
}

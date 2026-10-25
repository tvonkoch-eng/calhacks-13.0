import CoreLocation
import EventKit
import Foundation
import MapKit

/// What a tool found or did, laid out for the lens: the answer, one line of detail, an icon.
struct ToolResult: Sendable, Equatable {
    var title: String
    var detail: String
    /// A lens icon name (MWDATDisplay.IconName): cart, forkKnife, coffeeCup, cloud, bell, calendar…
    var icon: String
}

/// Things the aid can look up or do right now, on this device. The model picks one with native
/// tool calling; the result goes straight onto a card, with no second model call to word it.
protocol Toolbox: Sendable {
    /// OpenAI-style function definitions, as JSON text.
    var definitions: String { get }
    /// What to show while `name` runs, if it's slow: "Finding Target nearby".
    func working(_ name: String, arguments: String) -> String
    func run(_ name: String, arguments: String) async throws -> ToolResult
    /// Start the obvious tool before the model has decided ("nearest Target" → search now), so
    /// the decision and the work overlap. A guess the model doesn't confirm is simply dropped.
    func prefetch(_ request: String)
    /// Roughly where the user is ("near 333 Post St, San Francisco, CA"), so a research task can
    /// say "near here" in words a web search understands.
    func whereabouts() async -> String?
}

extension Toolbox {
    func prefetch(_ request: String) {}
    func whereabouts() async -> String? { nil }
}

enum Tools {
    enum Decision: Equatable {
        case answer(String)
        case skip
        case call(name: String, arguments: String)
    }

    /// "Lens, how far is the nearest Target?" → "how far is the nearest Target?". Only at the very
    /// start of what the wearer says, so ordinary talk about lenses never counts.
    static func command(in text: String) -> String? {
        let pattern = #"^\s*(?:hey |ok |okay )?(?:lens|lenz|lense)\b[\s,.:!-]*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let rest = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.contains(where: \.isLetter) ? rest : nil
    }

    /// Could this need a tool? Generous on purpose: a false yes costs one tool-enabled call that
    /// answers in plain text anyway; a false no sends "how far is the Target" to a model with no
    /// way to know.
    static func wants(_ question: String) -> Bool {
        let q = " " + question.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
        // "How far is Berkeley from San Francisco": between two named places, a fact from memory,
        // streamed before the question ends. Only a distance from here needs the device.
        let between = q.contains(" from ") && ![" from here", " from us", " from me", " from where"].contains(where: q.contains)
        return cues.contains { cue in q.contains(cue) && !(between && (cue == "how far" || cue == "walking distance")) }
    }

    private static let cues = [
        // places
        "nearest", "closest", "near me", "near here", "nearby", "around here", "close by", "close to here",
        // "us" and "you" as often as "me": "a popular Chinese restaurant near us" went unanswered.
        "near us", "near you", "around us", "close to us", "in the area", "around the corner", "walk from here",
        "how far", "walking distance", "where's the", "where is the", "where can i", "where do i find",
        "directions to", "get to the",
        // weather
        "weather", " rain", "umbrella", "temperature", "how cold", "how hot", "how warm", "forecast", " snow",
        // reminders and calendar
        "remind", "reminder", "calendar", "my next", "meeting", "schedule", "agenda", "what do i have",
    ]

    /// Where the answer lives decides who answers. The web knows public things, not these two
    /// people: "what's the latest on the GENIUS Act" is research; "what did she say her company
    /// does" is the conversation; "how's her fundraise going" is nobody's to look up.
    private static func prompt(research: Bool) -> String {
        var sources = """
        - the conversation, or what's known about the person they're talking to: answer from that;
        - where they are, the weather, their reminders or their calendar: call that tool;
        - stable general knowledge: answer it yourself;
        """
        if research {
            sources += "\n" + """
            - public facts that are recent or specific (news, prices, scores, opening hours, a \
            company's or product's latest, places with conditions like open late): call research \
            with a self-contained task.
            Never research a person, or anything only the people talking would know (their plans, \
            their work in progress, their history together): answer that from what's known, or SKIP.
            """
        }
        return """
        You act for someone wearing smart glasses, usually mid-conversation. Answer from wherever \
        the answer lives:
        \(sources)

        As short as the question allows: a fact in a few words, one or two sentences (at most \
        25 words) only if it needs explaining. US units (miles, feet, °F, pounds). No preamble, no restating the question, no full stop ("Frank Herbert", not "Frank Herbert wrote Dune."). Reply \
        exactly SKIP if nothing above can answer it. Never ask a follow-up.
        """
    }

    /// One round: the model answers in a line, says SKIP, or names a tool for the caller to run.
    static func decide(_ request: String, context: String, toolbox: any Toolbox,
                       provider: Provider, key: String, model: String) async throws -> Decision {
        let now = Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
        let place = await toolbox.whereabouts().map { " They are \($0)." } ?? ""
        let user = (context.isEmpty ? "" : "Conversation so far:\n\(context)\n\n") + "Request: \(request)"
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "tool_choice": "auto",
            "messages": [
                ["role": "system", "content": prompt(research: toolbox.definitions.contains("\"research\""))
                    + "\nIt is \(now), \(TimeZone.current.identifier).\(place)"],
                ["role": "user", "content": user],
            ],
        ]
        if let tools = try? JSONSerialization.jsonObject(with: Data(toolbox.definitions.utf8)) { body["tools"] = tools }
        // Reasoning models think first; Cerebras' Qwen thinks unless told not to.
        if model.contains("gpt-oss") {
            body.merge(["max_tokens": 500, "reasoning_effort": "low"]) { _, new in new }
        } else if provider == .cerebras || provider == .openrouter, model.contains("qwen") {
            body.merge(["max_tokens": 200, "reasoning_effort": "none"]) { _, new in new }
        } else {
            body["max_tokens"] = 200
        }
        let reply = try await LLM.chat(provider.endpoint, key: key, body: body, timeout: 8)
        if let call = reply.calls.first { return .call(name: call.name, arguments: call.arguments) }
        let text = (reply.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.uppercased().hasPrefix("SKIP") || Answerer.refuses(text) ? .skip : .answer(text)
    }

    // MARK: - Formatting, shared and testable

    /// "0.3 mi" / "500 ft" in the US, "450 m" / "1.2 km" elsewhere.
    static func distance(_ meters: Double, us: Bool) -> String {
        if us {
            let miles = meters / 1609.34
            return miles < 0.1 ? "\(Int((meters * 3.28084 / 50).rounded()) * 50) ft"
                               : (miles < 10 ? String(format: "%.1f mi", miles) : "\(Int(miles.rounded())) mi")
        }
        return meters < 1000 ? "\(Int((meters / 10).rounded()) * 10) m"
                             : (meters < 10_000 ? String(format: "%.1f km", meters / 1000) : "\(Int((meters / 1000).rounded())) km")
    }

    /// An honest estimate without a routing call: walking pace up to ~30 min, then city driving.
    /// Streets run about 1.3× the straight line, so that's built in.
    static func travel(_ meters: Double) -> String {
        let route = meters * 1.3
        let walk = route / 80   // ~4.8 km/h
        return walk <= 30 ? "~\(max(1, Int(walk.rounded()))) min walk" : "~\(max(1, Int((route / 500).rounded()))) min drive"
    }

    /// "how far is the nearest Target?" → "Target". Only the plain shapes; anything else waits for
    /// the model, which is the authority on what was asked.
    static func placeQuery(in request: String) -> String? {
        let patterns = [
            #"(?:nearest|closest) ([a-z0-9' &.-]+?)(?:\?|$| near| around| from| to | is | that| here)"#,
            #"is there (?:a|an|any) ([a-z0-9' &.-]+?) (?:near|around|close|nearby)"#,
            #"where(?:'s| is) (?:a |an |the )?([a-z0-9' &.-]+?) (?:near|around|nearby|close)"#,
        ]
        let text = request.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            var query = text[range].trimmingCharacters(in: .whitespaces)
            for article in ["a ", "an ", "the ", "good "] where query.hasPrefix(article) { query.removeFirst(article.count) }
            if !query.isEmpty { return query }
        }
        return nil
    }

    static func wantsWeather(_ request: String) -> Bool {
        let q = " " + request.lowercased() + " "
        return [" weather", " rain", "umbrella", "temperature", "how cold", "how hot", "how warm", "forecast"].contains { q.contains($0) }
    }

    /// A long finding (search models write paragraphs with links) as one glanceable card.
    static func card(from finding: String, about task: String, provider: Provider, key: String, model: String) async throws -> ToolResult {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": """
                    Turn research notes into one card for smart glasses. Reply with JSON only: \
                    {"title": "the answer itself, at most 6 words", "detail": "what else they need to know: \
                    empty for a bare fact, up to 25 words if it needs explaining"}. The title answers the task: lead with the \
                    number, name or date ("3,000+ hackers", not "Cal Hacks attendance"); never the \
                    topic restated. If the notes don't answer the task (not announced, no data, only \
                    related facts), reply {"title": ""}. No links, no citations, no preamble.
                    """],
                ["role": "user", "content": "Task: \(task)\n\nNotes:\n\(finding.prefix(4000))"],
            ],
        ]
        if model.contains("gpt-oss") { body.merge(["max_tokens": 400, "reasoning_effort": "low"]) { _, new in new } }
        else if provider == .cerebras || provider == .openrouter, model.contains("qwen") { body.merge(["max_tokens": 120, "reasoning_effort": "none"]) { _, new in new } }
        else { body["max_tokens"] = 120 }
        let text = try await LLM.complete(provider.endpoint, key: key, body: body, timeout: 8)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
           let title = json["title"] as? String {
            // An empty title is the notes not answering it: the caller shows nothing.
            return ToolResult(title: title.trimmingCharacters(in: .whitespaces), detail: json["detail"] as? String ?? "",
                              icon: "starCircleTriangleAi")
        }
        return ToolResult(title: String(text.prefix(80)), detail: "", icon: "starCircleTriangleAi")
    }

    /// "2026-10-24T18:00" (what the model is asked for), with or without seconds or a zone.
    static func date(_ text: String) -> Date? {
        if let zoned = ISO8601DateFormatter().date(from: text) { return zoned }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

// MARK: - The real tools

/// Keyless, on-device: Apple Maps for places, Open-Meteo for weather, EventKit for reminders and
/// the calendar. Location comes from Core Location, unless `pinned` (TEST_LOCATION) says where to
/// pretend to be: for testing, or a Mac command-line tool that can't get a fix.
final class DeviceTools: Toolbox, @unchecked Sendable {
    private let locator: Locator
    private let store = EKEventStore()
    private let us = Locale.current.measurementSystem == .us
    private let researcher: (any Researcher)?
    /// Turns a research finding into a card; a fast model.
    private let condenser: (provider: Provider, key: String, model: String)?
    private let early = Prefetch()

    init(pinned: CLLocation? = nil, researcher: (any Researcher)? = nil,
         condenser: (provider: Provider, key: String, model: String)? = nil) {
        locator = Locator(pinned: pinned)
        self.researcher = researcher
        self.condenser = condenser
        Task { [locator] in _ = await locator.describe() }   // the first question shouldn't wait for a fix
        // The research tool is only offered when there's a researcher behind it.
        var tools = (try? JSONSerialization.jsonObject(with: Data(Self.device.utf8)) as? [Any]) ?? []
        if researcher != nil, let research = try? JSONSerialization.jsonObject(with: Data(Self.research.utf8)) { tools.append(research) }
        definitions = (try? JSONSerialization.data(withJSONObject: tools)).map { String(decoding: $0, as: UTF8.self) } ?? Self.device
    }

    let definitions: String

    private static let research = """
      {"type": "function", "function": {"name": "research",
        "description": "Public facts from the web: news and anything recent, prices, scores, opening hours, a company's or product's public details, places matching conditions (open late, quiet, vegetarian). Never a person, and nothing only the people talking would know. Takes several seconds.",
        "parameters": {"type": "object", "properties": {"task": {"type": "string", "description": "The full task, self-contained: 'her company' or 'that bill' resolved from the conversation, 'near here' replaced by where they are, and no names of the people talking"}}, "required": ["task"]}}}
    """

    private static let device = """
    [
      {"type": "function", "function": {"name": "nearby",
        "description": "The nearest place matching a plain query (a store, brand, kind of place or landmark) and how far it is. It cannot check opening hours, reviews or atmosphere.",
        "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "What to look for: Target, coffee, pharmacy, Moscone Center"}}, "required": ["query"]}}},
      {"type": "function", "function": {"name": "weather",
        "description": "The weather now and over the next few hours where the user is.",
        "parameters": {"type": "object", "properties": {}}}},
      {"type": "function", "function": {"name": "remind",
        "description": "Create a reminder for the user.",
        "parameters": {"type": "object", "properties": {"text": {"type": "string", "description": "What to remind them of, short"}, "at": {"type": "string", "description": "When, as local ISO 8601 date-time like 2026-10-24T18:00, only if they said"}}, "required": ["text"]}}},
      {"type": "function", "function": {"name": "next_event",
        "description": "The user's next calendar event.",
        "parameters": {"type": "object", "properties": {}}}}
    ]
    """

    func whereabouts() async -> String? {
        await locator.describe()
    }

    func prefetch(_ request: String) {
        if let query = Tools.placeQuery(in: request) {
            Task { await early.start(key: "nearby:" + query) { try await self.nearby(query) } }
        } else if Tools.wantsWeather(request) {
            Task { await early.start(key: "weather") { try await self.weather() } }
        }
    }

    func working(_ name: String, arguments: String) -> String {
        switch name {
        case "research": return researcher?.name.contains("Fetch") == true ? "Asking Fetch.ai" : "Looking it up"
        case "nearby": return "Finding \(Self.arguments(arguments)["query"] as? String ?? "it") nearby"
        case "weather": return "Checking the weather"
        case "remind": return "Setting a reminder"
        case "next_event": return "Checking your calendar"
        default: return "Working on it"
        }
    }

    func run(_ name: String, arguments: String) async throws -> ToolResult {
        let args = Self.arguments(arguments)
        switch name {
        case "nearby":
            let query = args["query"] as? String ?? ""
            if let early = await early.take(key: "nearby:" + query.lowercased()) { return try await early.value }
            return try await nearby(query)
        case "weather":
            if let early = await early.take(key: "weather") { return try await early.value }
            return try await weather()
        case "research": return try await research(args["task"] as? String ?? "")
        case "remind": return try await remind(args["text"] as? String ?? "", at: (args["at"] as? String).flatMap(Tools.date))
        case "next_event": return try await nextEvent()
        default: return ToolResult(title: "Can't do that yet", detail: name, icon: "exclamationCircle")
        }
    }

    private static func arguments(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    private static let noLocation = ToolResult(title: "Location unavailable", detail: "allow location access", icon: "exclamationCircle")

    // MARK: Places

    private func nearby(_ query: String) async throws -> ToolResult {
        guard !query.isEmpty else { return ToolResult(title: "Nearby what?", detail: "", icon: "exclamationCircle") }
        guard let here = await locator.current() else { return Self.noLocation }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 6000, longitudinalMeters: 6000)
        // Inside the region, not just near it: as a hint, "coffee" around Berkeley came back as a café
        // 10 miles away.
        if #available(iOS 18.0, macOS 15.0, *) { request.regionPriority = .required }
        let items = try await MKLocalSearch(request: request).start().mapItems
        let ranked = items.compactMap { item in Self.location(of: item).map { (item, $0.distance(from: here)) } }
        guard let (item, meters) = ranked.min(by: { $0.1 < $1.1 }) else {
            return ToolResult(title: "No \(query) nearby", detail: "", icon: "globeWesternHemisphere")
        }
        let detail = [Tools.travel(meters), Self.street(of: item)].compactMap { $0 }.joined(separator: " · ")
        return ToolResult(title: "\(item.name ?? query) · \(Tools.distance(meters, us: us))", detail: detail,
                          icon: Self.icon(item.pointOfInterestCategory))
    }

    private static func location(of item: MKMapItem) -> CLLocation? {
        if #available(iOS 26, macOS 26, *) { return item.location }
        return item.placemark.location
    }

    private static func street(of item: MKMapItem) -> String? {
        if #available(iOS 26, macOS 26, *) {
            return item.address?.shortAddress?.split(separator: ",").first.map(String.init)
        }
        return item.placemark.thoroughfare
    }

    private static func icon(_ category: MKPointOfInterestCategory?) -> String {
        guard let category else { return "globeWesternHemisphere" }
        switch category {
        case .restaurant, .bakery: return "forkKnife"
        case .cafe: return "coffeeCup"
        case .nightlife, .brewery, .winery: return "cocktailGlass"
        case .store, .foodMarket: return "cart"
        case .pharmacy, .hospital: return "crossBriefcase"   // the lens set's first-aid kit
        case .publicTransport: return "train"
        case .airport: return "airplane"
        case .hotel: return "house"
        case .museum: return "museumBuilding"
        case .stadium: return "stadium"
        case .park, .nationalPark: return "tree"
        default: return "globeWesternHemisphere"
        }
    }

    // MARK: Weather

    private func weather() async throws -> ToolResult {
        guard let here = await locator.current() else { return Self.noLocation }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(here.coordinate.latitude)),
            .init(name: "longitude", value: String(here.coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "hourly", value: "precipitation_probability"),
            .init(name: "daily", value: "temperature_2m_max"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "forecast_hours", value: "6"),
            .init(name: "temperature_unit", value: us ? "fahrenheit" : "celsius"),
            .init(name: "timezone", value: "auto"),
        ]
        let (data, _) = try await URLSession.shared.data(from: url.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue else {
            return ToolResult(title: "Weather unavailable", detail: "", icon: "exclamationCircle")
        }
        let code = (current["weather_code"] as? NSNumber)?.intValue ?? 0
        let hourly = json["hourly"] as? [String: Any]
        let chances = (hourly?["precipitation_probability"] as? [NSNumber])?.map(\.intValue) ?? []
        let times = hourly?["time"] as? [String] ?? []
        var rain = "no rain in the next few hours"
        if let peak = chances.max(), peak >= 30, let i = chances.firstIndex(of: peak) {
            let hour = i < times.count ? times[i].suffix(5) : ""
            rain = "\(peak)% chance of rain" + (hour.isEmpty || i == 0 ? "" : " around \(Self.clock(String(hour)))")
        }
        let day = (current["is_day"] as? NSNumber)?.intValue != 0
        let (condition, icon) = Self.describe(code, day: day)
        let high = ((json["daily"] as? [String: Any])?["temperature_2m_max"] as? [NSNumber])?.first.map { "high \(Int($0.doubleValue.rounded()))°" }
        return ToolResult(title: "\(Int(temperature.rounded()))°\(us ? "F" : "C"), \(condition)",
                          detail: [high, rain].compactMap { $0 }.joined(separator: " · "), icon: icon)
    }

    /// "18:00" → "6 PM" in the US.
    private static func clock(_ hhmm: String) -> String {
        guard let hour = Int(hhmm.prefix(2)), Locale.current.measurementSystem == .us else { return hhmm }
        return "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }

    /// WMO weather codes, as Open-Meteo reports them. The lens icon set has no sun or raindrop:
    /// sun-behind-cloud for a clear day, the moon at night, plain cloud for the rest.
    private static func describe(_ code: Int, day: Bool) -> (String, String) {
        let clear = day ? "cloudDotFourRays" : "cloudCrescentMoon"
        switch code {
        case 0: return ("clear", clear)
        case 1, 2: return ("partly cloudy", clear)
        case 3: return ("overcast", "cloud")
        case 45, 48: return ("foggy", "cloudFiveDashes")
        case 51...57: return ("drizzle", "cloud")
        case 61...67, 80...82: return ("rain", "cloud")
        case 71...77, 85, 86: return ("snow", "cloud")
        case 95...99: return ("thunderstorms", "cloudLightning")
        default: return ("mixed", "cloud")
        }
    }

    // MARK: Reminders and calendar

    private func remind(_ text: String, at date: Date?) async throws -> ToolResult {
        guard !text.isEmpty else { return ToolResult(title: "Remind you of what?", detail: "", icon: "exclamationCircle") }
        guard try await store.requestFullAccessToReminders() else {
            return ToolResult(title: "Reminders not allowed", detail: "allow in Privacy settings", icon: "exclamationCircle")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let date {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
        try store.save(reminder, commit: true)
        let when = date.map { $0.formatted(Calendar.current.isDateInToday($0) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute()) }
        return ToolResult(title: "Reminder set", detail: [text, when].compactMap { $0 }.joined(separator: " · "), icon: "bell")
    }

    private func nextEvent() async throws -> ToolResult {
        guard try await store.requestFullAccessToEvents() else {
            return ToolResult(title: "Calendar not allowed", detail: "allow in Privacy settings", icon: "exclamationCircle")
        }
        let now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: now.addingTimeInterval(36 * 3600), calendars: nil))
        guard let next = events.filter({ !$0.isAllDay && $0.endDate > now }).min(by: { $0.startDate < $1.startDate }) else {
            return ToolResult(title: "Nothing coming up", detail: "next 36 hours", icon: "calendar")
        }
        let start = next.startDate ?? now
        let when = start <= now ? "now" : RelativeDateTimeFormatter().localizedString(for: start, relativeTo: now)
        let time = start.formatted(Calendar.current.isDateInToday(start) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())
        return ToolResult(title: "\(next.title ?? "Event") · \(time)",
                          detail: [when, next.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), icon: "calendar")
    }
}

extension DeviceTools {
    /// The deep lane as a tool: the researcher (Fetch.ai ASI:One, OpenAI web search…) does the
    /// work, a fast model cuts the finding down to a card.
    fileprivate func research(_ task: String) async throws -> ToolResult {
        guard let researcher, !task.isEmpty else { return ToolResult(title: "Research is off", detail: "", icon: "exclamationCircle") }
        let finding = try await researcher.research(task, context: "")
        guard let condenser else { return ToolResult(title: String(finding.prefix(60)), detail: "", icon: "starCircleTriangleAi") }
        return try await Tools.card(from: finding, about: task, provider: condenser.provider, key: condenser.key, model: condenser.model)
    }
}

/// Tool work started before the model decided: kept for 20 s, used at most once.
actor Prefetch {
    private var tasks: [String: (task: Task<ToolResult, Error>, started: Date)] = [:]

    func start(key: String, _ work: @escaping @Sendable () async throws -> ToolResult) {
        tasks = tasks.filter { -$0.value.started.timeIntervalSinceNow < 20 }
        guard tasks[key] == nil else { return }
        tasks[key] = (Task { try await work() }, Date())
    }

    func take(key: String) -> Task<ToolResult, Error>? {
        guard let entry = tasks.removeValue(forKey: key), -entry.started.timeIntervalSinceNow < 20 else { return nil }
        return entry.task
    }
}

/// Where the device is: the pinned location if there is one (no permission asked), else a fix
/// cached for two minutes, waiting at most 1.5 s for a fresh one.
actor Locator {
    private var last: CLLocation?
    private let pinned: CLLocation?
    private var asked = false

    init(pinned: CLLocation?) {
        self.pinned = pinned
    }

    func current() async -> CLLocation? {
        if let pinned { return pinned }
        if let last, -last.timestamp.timeIntervalSinceNow < 120 { return last }
        if !asked {
            asked = true
            await MainActor.run { Permission.location() }
        }
        // No fix last time (no permission, deep indoors, a Mac): don't make every question wait
        // another 1.5 s for one, for a minute.
        if -failedAt.timeIntervalSinceNow < 60 { return last }
        if let fresh = await fix(within: 1.5) {
            last = fresh
            return fresh
        }
        failedAt = Date()
        return last
    }
    private var failedAt = Date.distantPast

    private var described: (text: String, at: Date)?

    /// "near 333 Post St, San Francisco, CA", cached for ten minutes.
    func describe() async -> String? {
        if let described, -described.at.timeIntervalSinceNow < 600 { return described.text }
        guard let here = await current() else { return nil }
        var parts: [String] = []
        if #available(iOS 26, macOS 26, *) {
            if let request = MKReverseGeocodingRequest(location: here),
               let item = try? await Task { @MainActor in try await request.mapItems }.value.first {
                parts = [item.address?.shortAddress, item.addressRepresentations?.cityWithContext].compactMap { $0 }
            }
        } else if let mark = try? await CLGeocoder().reverseGeocodeLocation(here).first {
            parts = [mark.thoroughfare.map { [mark.subThoroughfare, $0].compactMap { $0 }.joined(separator: " ") },
                     mark.locality, mark.administrativeArea].compactMap { $0 }
        }
        guard !parts.isEmpty else { return nil }
        // shortAddress often already ends with the city; don't say it twice.
        var unique: [String] = []
        for part in parts where !unique.contains(where: { $0.contains(part) || part.contains($0) }) { unique.append(part) }
        let text = "near " + unique.joined(separator: ", ")
        described = (text, Date())
        return text
    }

    private func fix(within seconds: Double) async -> CLLocation? {
        await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Core Location only asks once there's a manager to ask through; keep it alive.
@MainActor enum Permission {
    private static var manager: CLLocationManager?

    static func location() {
        guard manager == nil else { return }
        let manager = CLLocationManager()
        manager.requestWhenInUseAuthorization()
        Self.manager = manager
    }
}

import Foundation

/// Ready-made example decks for different sectors, so people can see what
/// Snazzy Pro is for before writing anything. All names and figures are made up.
///
/// Each sample becomes an ordinary Builder presentation project, and the
/// assistant can edit it like any other project.
public struct SampleDeck: Identifiable, Sendable {
    public enum Sector: String, CaseIterable, Identifiable, Sendable {
        case education = "Education"
        case sales = "Sales"
        case healthcare = "Healthcare"
        case finance = "Finance"
        case people = "HR & People"
        case marketing = "Marketing"
        case realEstate = "Real estate"
        case nonprofit = "Nonprofit"
        case support = "Customer support"
        case manufacturing = "Manufacturing"
        case hospitality = "Hospitality"
        case developers = "Developers"

        public var id: String { rawValue }

        public var symbol: String {
            switch self {
            case .education: "graduationcap"
            case .sales: "chart.line.uptrend.xyaxis"
            case .healthcare: "cross.case"
            case .finance: "sterlingsign.circle"
            case .people: "person.2"
            case .marketing: "megaphone"
            case .realEstate: "house"
            case .nonprofit: "heart"
            case .support: "questionmark.bubble"
            case .manufacturing: "gearshape.2"
            case .hospitality: "fork.knife"
            case .developers: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    public struct Slide: Sendable, Equatable {
        public enum Layout: String, Sendable {
            /// heading = title, items[0] = subtitle
            case title
            case bullets
            /// items = [value, caption] pairs
            case stats
            /// items split in half: left column, right column; first item of each is its label
            case columns
            /// heading = quote, items[0] = who said it
            case quote
            /// numbered steps
            case steps
            /// heading = call to action, items[0] = detail
            case closing
        }

        public var layout: Layout
        public var heading: String
        public var items: [String]
        public var notes: String

        public init(_ layout: Layout, _ heading: String, _ items: [String] = [], notes: String = "") {
            self.layout = layout
            self.heading = heading
            self.items = items
            self.notes = notes
        }
    }

    public let id: String
    public let sector: Sector
    public let title: String
    /// What the video is for, in one line.
    public let useCase: String
    public let audience: String
    public let minutes: Int
    /// How to set up the recording in Snazzy Pro.
    public let setup: [String]
    /// What to ask the assistant to get a deck like this for your own content.
    public let prompt: String
    public let accent: String
    public let slides: [Slide]

    /// Folder name when opened in the Builder.
    public var projectName: String { "sample-\(id)" }
}

// MARK: - Rendering

extension SampleDeck {
    /// The deck as Builder project files (index.html plus the standard deck.css and deck.js).
    public func files() -> [(String, String)] {
        let base = Templates.files(for: .presentation, title: title).filter { $0.0 != "index.html" }
        return [("index.html", html())] + base
    }

    public func html() -> String {
        let sections = slides.map(Self.render).joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>\(Self.esc(title))</title>
          <link rel="stylesheet" href="deck.css">
        </head>
        <body style="--accent: \(Self.esc(accent))">
          <!-- Sample deck (\(Self.esc(sector.rawValue))). All names and figures are made up. -->
          <div class="deck">
        \(sections)
          </div>
          <div class="counter"></div>
          <script src="deck.js"></script>
        </body>
        </html>

        """
    }

    static func render(_ s: Slide) -> String {
        let h = esc(s.heading)
        let notes = s.notes.isEmpty ? "" : "\n      <aside class=\"notes\">\(esc(s.notes))</aside>"
        let body: String
        switch s.layout {
        case .title:
            body = "<h1>\(h)</h1>" + (s.items.first.map { "<p class=\"subtitle\">\(esc($0))</p>" } ?? "")
        case .bullets:
            body = "<h2>\(h)</h2><ul>" + s.items.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
        case .steps:
            body = "<h2>\(h)</h2><ol class=\"steps\">" + s.items.map { "<li>\(esc($0))</li>" }.joined() + "</ol>"
        case .stats:
            let pairs = stride(from: 0, to: s.items.count - 1, by: 2).map {
                "<div class=\"stat\"><b>\(esc(s.items[$0]))</b><span>\(esc(s.items[$0 + 1]))</span></div>"
            }
            body = "<h2>\(h)</h2><div class=\"stats\">" + pairs.joined() + "</div>"
        case .columns:
            let half = (s.items.count + 1) / 2
            func column(_ items: ArraySlice<String>) -> String {
                guard let label = items.first else { return "<div></div>" }
                return "<div><h3>\(esc(label))</h3><ul>" + items.dropFirst().map { "<li>\(esc($0))</li>" }.joined() + "</ul></div>"
            }
            body = "<h2>\(h)</h2><div class=\"cols\">" + column(s.items.prefix(half)) + column(s.items.dropFirst(half)) + "</div>"
        case .quote:
            body = "<blockquote>\(h)</blockquote>" + (s.items.first.map { "<p class=\"by\">— \(esc($0))</p>" } ?? "")
        case .closing:
            body = "<h1>\(h)</h1>" + (s.items.first.map { "<p class=\"subtitle\">\(esc($0))</p>" } ?? "")
        }
        let cls = s.layout == .title || s.layout == .closing ? "slide title" : "slide layout-\(s.layout.rawValue)"
        return "    <section class=\"\(cls)\">\n      \(body)\(notes)\n    </section>"
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension Workspace {
    /// Copies a sample into the workspace as a presentation project (replacing
    /// an earlier copy of the same sample).
    @discardableResult
    /// Copies a sample into a project, or opens the copy made before (with any edits:
    /// opening a sample again never throws work away).
    public func createSample(_ sample: SampleDeck) throws -> BuilderProject {
        if let existing = project(sample.projectName) { return existing }
        let project = try createProject(name: sample.projectName, kind: .presentation, title: sample.title)
        for (path, content) in sample.files() {
            try write(project: project.name, path: path, content: content)
        }
        return project
    }
}

// MARK: - The samples

extension SampleDeck {
    public static let all: [SampleDeck] = [
        SampleDeck(
            id: "lesson-photosynthesis", sector: .education, title: "Photosynthesis in five minutes",
            useCase: "A flipped-classroom lesson students watch before class",
            audience: "Year 9 science students", minutes: 5,
            setup: ["Slides as the screen", "Camera inset bottom-right, rounded", "Captions on, so students can rewatch with sound off"],
            prompt: "Make a five-minute lesson on photosynthesis for 14-year-olds with a quick quiz at the end.",
            accent: "#34D399",
            slides: [
                Slide(.title, "Photosynthesis in five minutes", ["How plants turn light into food"], notes: "Smile, introduce the topic, say there's a quiz at the end."),
                Slide(.bullets, "What a plant needs", ["Light from the sun", "Water from the roots", "Carbon dioxide from the air"]),
                Slide(.quote, "Carbon dioxide + water → glucose + oxygen", ["The word equation, powered by light"], notes: "Point at each part as you say it."),
                Slide(.steps, "Inside the leaf", ["Chlorophyll absorbs light", "Water is split, releasing oxygen", "Carbon dioxide is built into glucose"]),
                Slide(.stats, "Why it matters", ["≈50%", "of the world's oxygen comes from ocean plankton", "100%", "of the food we eat depends on it"]),
                Slide(.bullets, "Quick quiz", ["What gas do plants take in?", "Where does the oxygen come from?", "What is the green pigment called?"], notes: "Pause two seconds after each question."),
                Slide(.closing, "Bring your answers to class", ["Next time: respiration"]),
            ]),
        SampleDeck(
            id: "sales-demo", sector: .sales, title: "Northwind Analytics in 10 minutes",
            useCase: "A personalised demo video sent to a prospect after a first call",
            audience: "A prospect's operations team", minutes: 10,
            setup: ["Screen: the product in a browser window", "Camera inset with a blurred background", "Zoom to text on key numbers"],
            prompt: "Build a short sales deck for Northwind Analytics aimed at a logistics company, with ROI numbers and a clear next step.",
            accent: "#6C5CFF",
            slides: [
                Slide(.title, "Hi Fabrikam Freight 👋", ["A ten-minute look at Northwind Analytics, made for your team"], notes: "Name the person you spoke to on the call."),
                Slide(.bullets, "What you told us", ["Weekly reports take two days to assemble", "Late deliveries are spotted after customers complain", "Data lives in four different tools"]),
                Slide(.columns, "Before and after", ["Today", "Spreadsheets emailed on Fridays", "Problems found late", "With Northwind", "Live dashboard every morning", "Alerts before a delivery slips"]),
                Slide(.stats, "What similar teams saw", ["-80%", "time spent on reporting", "3×", "faster response to late loads", "6 weeks", "to full rollout"]),
                Slide(.quote, "We stopped arguing about whose numbers were right.", ["Head of Operations, Contoso Haulage (pilot customer)"]),
                Slide(.closing, "Next step: a 30-day pilot", ["Reply to this email and we'll set it up with your data"]),
            ]),
        SampleDeck(
            id: "hand-hygiene", sector: .healthcare, title: "Hand hygiene refresher",
            useCase: "Mandatory training refreshed every year, watched on any device",
            audience: "Ward staff and volunteers", minutes: 6,
            setup: ["Slides as the screen", "iPhone on a stand as a second camera for the hand-washing demo", "Captions burned in for noisy wards"],
            prompt: "Make a six-minute staff refresher on hand hygiene using the five moments, with a short checklist at the end.",
            accent: "#38BDF8",
            slides: [
                Slide(.title, "Hand hygiene refresher", ["Riverside Community Hospital · annual training"]),
                Slide(.steps, "Your five moments", ["Before touching a patient", "Before a clean or aseptic procedure", "After body fluid exposure risk", "After touching a patient", "After touching patient surroundings"]),
                Slide(.columns, "Rub or wash?", ["Alcohol rub", "Hands look clean", "20–30 seconds", "Soap and water", "Hands visibly dirty", "40–60 seconds"]),
                Slide(.stats, "Our ward audit", ["92%", "compliance last quarter", "98%", "our target this year"], notes: "Example figures for the sample deck."),
                Slide(.bullets, "Before you finish", ["Nails short, no false nails", "Bare below the elbows", "Report sore or cracked skin to occupational health"]),
                Slide(.closing, "Thank you for keeping patients safe", ["Complete the quiz on the learning portal"]),
            ]),
        SampleDeck(
            id: "board-results", sector: .finance, title: "Q2 results for the board",
            useCase: "A recorded results briefing board members watch before the meeting",
            audience: "Board and investors", minutes: 8,
            setup: ["Slides as the screen", "Camera inset top-right, plain studio background", "Export with chapters so directors can jump to a section"],
            prompt: "Turn these quarterly numbers into an eight-minute board briefing with highlights, risks and asks.",
            accent: "#FFB020",
            slides: [
                Slide(.title, "Q2 results", ["Example Holdings Ltd · board briefing"]),
                Slide(.stats, "Headlines", ["£4.2m", "revenue, up 12% on Q1", "31%", "gross margin", "£1.1m", "cash generated"]),
                Slide(.columns, "What went well, what didn't", ["Went well", "Subscription renewals at 94%", "Two enterprise contracts signed", "Watch", "Hardware costs up 8%", "One delayed product launch"]),
                Slide(.bullets, "Risks", ["Currency exposure on US contracts", "Hiring for two senior roles still open", "Supplier concentration in one region"]),
                Slide(.steps, "What we need from the board", ["Approve the Q3 hiring plan", "Agree the hedging policy", "Note the revised launch date"]),
                Slide(.closing, "Questions before Thursday?", ["Reply in the board portal; full pack attached"]),
            ]),
        SampleDeck(
            id: "onboarding", sector: .people, title: "Welcome to Brightside",
            useCase: "A friendly first-day video for every new starter",
            audience: "New employees", minutes: 7,
            setup: ["Camera full-size for the welcome, then slides with a camera inset", "Brand background behind you", "Share link for the onboarding email"],
            prompt: "Create a warm onboarding deck for new starters covering our values, first week and who to ask for help.",
            accent: "#D946EF",
            slides: [
                Slide(.title, "Welcome to Brightside", ["We're glad you're here"], notes: "Record this slide with the camera full screen."),
                Slide(.bullets, "What we value", ["Be kind, be direct", "Ship small, learn fast", "Leave things better than you found them"]),
                Slide(.steps, "Your first week", ["Day 1: laptop, accounts and lunch with your buddy", "Day 2: meet your team and pick a starter task", "Day 3–4: shadow a customer call", "Day 5: show us what you learned"]),
                Slide(.columns, "Who to ask", ["People team", "Leave, pay, benefits", "Your buddy", "Everything else, really"]),
                Slide(.quote, "Nobody expects you to know everything in week one.", ["Sam, Head of People"]),
                Slide(.closing, "See you on Monday", ["Questions before then? Just reply to the welcome email"]),
            ]),
        SampleDeck(
            id: "campaign-launch", sector: .marketing, title: "Spring campaign launch",
            useCase: "Briefing the whole company and partner agencies in one video",
            audience: "Internal teams and agencies", minutes: 6,
            setup: ["Slides plus a browser window with the landing page", "Camera inset with the Spotlight background", "Upload the result for agency partners"],
            prompt: "Make a campaign briefing deck: the idea, audience, channels, key dates and what each team needs to do.",
            accent: "#FF6A55",
            slides: [
                Slide(.title, "Fresh Start", ["Spring campaign · launches 3 March"]),
                Slide(.quote, "Small changes, big spring.", ["Campaign line"]),
                Slide(.columns, "Who we're talking to", ["Primary", "First-time home owners", "25–34, mobile first", "Secondary", "Returning customers", "Lapsed in the last year"]),
                Slide(.stats, "Goals", ["+20%", "new customer sign-ups", "40k", "email list growth", "4.5★", "average review score"]),
                Slide(.steps, "Key dates", ["10 Feb: creative signed off", "24 Feb: social teasers start", "3 Mar: launch day", "31 Mar: results review"]),
                Slide(.closing, "Assets are in the shared folder", ["Questions to the campaign channel"]),
            ]),
        SampleDeck(
            id: "property-tour", sector: .realEstate, title: "14 Elm Row: the walkthrough",
            useCase: "A narrated property video for buyers who can't visit in person",
            audience: "Prospective buyers", minutes: 4,
            setup: ["iPhone as the camera, walking the rooms", "Slides for floor plan and key facts", "Background blur off — show the room"],
            prompt: "Make a short property presentation with key facts, the floor plan highlights, local area and how to book a viewing.",
            accent: "#0F766E",
            slides: [
                Slide(.title, "14 Elm Row", ["Three-bedroom Victorian terrace · offers over £450,000"]),
                Slide(.stats, "At a glance", ["3", "bedrooms", "1,180 ft²", "internal space", "60 ft", "south-facing garden"]),
                Slide(.bullets, "Highlights", ["Original fireplaces and high ceilings", "Kitchen extended in 2022", "Loft with planning permission"]),
                Slide(.columns, "The area", ["Nearby", "Station 6 minutes' walk", "Two 'Outstanding' schools", "Weekends", "Riverside park", "Saturday market"]),
                Slide(.closing, "Book a viewing", ["Call Oakfield Estates or reply to this message"]),
            ]),
        SampleDeck(
            id: "impact-report", sector: .nonprofit, title: "Riverbank Clean-up: our year",
            useCase: "An annual impact video for donors and volunteers",
            audience: "Donors, volunteers and local partners", minutes: 5,
            setup: ["Camera with a warm studio background", "Slides with photos from the year", "Captions and a share link for social"],
            prompt: "Create an impact report deck thanking volunteers, with our numbers for the year and what donations will fund next.",
            accent: "#22C55E",
            slides: [
                Slide(.title, "Thank you", ["Riverbank Clean-up · our year in five minutes"]),
                Slide(.stats, "What you made possible", ["412", "volunteers", "9.6 t", "of litter removed", "23 km", "of riverbank cleared"]),
                Slide(.quote, "My kids now spot litter before I do.", ["Priya, volunteer since spring"]),
                Slide(.bullets, "What's next", ["Two new sites downstream", "Litter traps on three storm drains", "School workshops every term"]),
                Slide(.stats, "What your gift does", ["£10", "buys a litter picker", "£50", "funds a school workshop", "£250", "installs a drain trap"]),
                Slide(.closing, "Join us on the first Saturday of the month", ["riverbank-cleanup.example.org"]),
            ]),
        SampleDeck(
            id: "router-reset", sector: .support, title: "How to reset your router",
            useCase: "A help-centre video that answers a top support question",
            audience: "Customers", minutes: 3,
            setup: ["iPhone or iPad camera pointed at the router", "Slides for the steps", "Captions, and keep it under three minutes"],
            prompt: "Make a short how-to deck for resetting our router, with numbered steps and what to do if it still doesn't work.",
            accent: "#3B82F6",
            slides: [
                Slide(.title, "Reset your router in 2 minutes", ["SwiftLink Home Hub 3"]),
                Slide(.steps, "Steps", ["Find the small reset hole on the back", "Hold a paper clip in it for 10 seconds", "Wait for the light to turn solid white", "Reconnect with the password on the sticker"]),
                Slide(.columns, "What the lights mean", ["Lights", "White: working", "Orange: starting up", "Red", "No signal from the street", "Check the cable is pushed in"]),
                Slide(.closing, "Still stuck?", ["Chat with us in the app, any time"]),
            ]),
        SampleDeck(
            id: "safety-briefing", sector: .manufacturing, title: "Line 3 safety briefing",
            useCase: "A shift-start safety briefing recorded once, played on the floor screen",
            audience: "Operators and contractors", minutes: 4,
            setup: ["Camera with a plain background", "Slides with big text for the floor screen", "Burned-in captions (it's loud)"],
            prompt: "Create a four-minute safety briefing for a packaging line: hazards, PPE, the stop procedure and who to call.",
            accent: "#F59E0B",
            slides: [
                Slide(.title, "Line 3 safety briefing", ["Read before every shift · Unit 7 packaging"]),
                Slide(.bullets, "PPE on the line", ["Safety boots and hi-vis at all times", "Cut-resistant gloves at the cutter", "Ear defenders past the yellow line"]),
                Slide(.steps, "If something goes wrong", ["Hit the red stop button", "Shout 'Line stop'", "Tell your shift lead", "Log it on the tablet before restarting"]),
                Slide(.stats, "This month", ["41", "days without a lost-time injury", "3", "near misses reported — thank you"]),
                Slide(.closing, "Safe shift, everyone", ["Shift lead today: radio channel 2"]),
            ]),
        SampleDeck(
            id: "menu-briefing", sector: .hospitality, title: "New autumn menu",
            useCase: "A menu briefing so every shift knows the dishes before service",
            audience: "Front-of-house and kitchen staff", minutes: 5,
            setup: ["iPad overhead camera showing each plate", "Slides for allergens", "Share link in the staff group chat"],
            prompt: "Build a menu briefing deck for staff: new dishes, how to describe them, allergens and pairings.",
            accent: "#B45309",
            slides: [
                Slide(.title, "Autumn menu", ["The Copper Kettle · starts Friday"]),
                Slide(.bullets, "New dishes", ["Roast squash with sage brown butter", "Braised short rib, celeriac mash", "Apple and blackberry crumble"]),
                Slide(.columns, "Allergens", ["Contains nuts", "Squash (hazelnut dukkah)", "Crumble (almond topping)", "Gluten-free", "Short rib", "Crumble on request"]),
                Slide(.quote, "Describe the short rib as 'slow-cooked for eight hours'. Guests love hearing that.", ["Head chef"]),
                Slide(.closing, "Tasting at 4pm Thursday", ["Every shift lead please attend"]),
            ]),
        SampleDeck(
            id: "release-demo", sector: .developers, title: "Release 2.4 demo",
            useCase: "A release walkthrough recorded straight from the pull request",
            audience: "The team, reviewers and customers", minutes: 6,
            setup: ["Screen: the app plus the code editor", "Camera inset small, bottom-right", "Generate captions and a summary from the recording"],
            prompt: "Make a release demo deck from my pull requests: what changed, a before/after, and how to upgrade.",
            accent: "#8B5CF6",
            slides: [
                Slide(.title, "Release 2.4", ["Faster search and offline mode"]),
                Slide(.bullets, "What's new", ["Search results in under 100 ms", "Offline mode for the mobile app", "Dark mode for reports"]),
                Slide(.stats, "By the numbers", ["5×", "faster search", "38", "pull requests merged", "0", "breaking changes"]),
                Slide(.steps, "Upgrade", ["Update the package to 2.4.0", "Run the migration command", "Turn on offline mode in settings"]),
                Slide(.closing, "Thanks, contributors", ["Full changelog in the release notes"]),
            ]),
    ]
}

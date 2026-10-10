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

    public struct Slide: Codable, Sendable, Equatable {
        public enum Layout: String, Codable, CaseIterable, Sendable {
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
        Self.deckHTML(title: title, accent: accent, slides: slides,
                      comment: "Sample deck (\(sector.rawValue)). All names and figures are made up.")
    }

    /// A complete deck page in the house style (deck.css + deck.js).
    public static func deckHTML(title: String, accent: String, slides: [Slide], comment: String? = nil) -> String {
        let sections = slides.map(Self.render).joined(separator: "\n")
        let note = comment.map { "  <!-- \(esc($0)) -->\n" } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>\(esc(title))</title>
          <link rel="stylesheet" href="deck.css">
        </head>
        <body style="--accent: \(esc(accent))">
        \(note)  <div class="deck">
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
        // Editable without AI in the slide editor.
        try DeckOutline(title: sample.title, accent: sample.accent, slides: sample.slides).save(to: self, project: project.name, writeHTML: false)
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
                Slide(.bullets, "What a plant needs", ["Light from the sun", "Water from the roots", "Carbon dioxide from the air"], notes: "A plant needs three things to make its food: light from the sun, water that comes up through the roots, and carbon dioxide it takes in from the air through tiny holes in its leaves."),
                Slide(.quote, "Carbon dioxide + water → glucose + oxygen", ["The word equation, powered by light"], notes: "Point at each part as you say it."),
                Slide(.steps, "Inside the leaf", ["Chlorophyll absorbs light", "Water is split, releasing oxygen", "Carbon dioxide is built into glucose"], notes: "Here's what happens inside the leaf. The green chlorophyll soaks up the light. That energy splits water, and the oxygen is let out. Then the carbon dioxide is built into glucose, the plant's food."),
                Slide(.stats, "Why it matters", ["≈50%", "of the world's oxygen comes from ocean plankton", "100%", "of the food we eat depends on it"], notes: "Why does it matter? About half the oxygen we breathe comes from tiny plankton in the oceans. And all the food we eat depends on photosynthesis, even meat, because animals eat plants."),
                Slide(.bullets, "Quick quiz", ["What gas do plants take in?", "Where does the oxygen come from?", "What is the green pigment called?"], notes: "Pause two seconds after each question."),
                Slide(.closing, "Bring your answers to class", ["Next time: respiration"], notes: "Write your answers down and bring them to our next lesson. Next time we'll look at respiration, which is a bit like photosynthesis running the other way. See you then."),
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
                Slide(.bullets, "What you told us", ["Weekly reports take two days to assemble", "Late deliveries are spotted after customers complain", "Data lives in four different tools"], notes: "When we spoke last week, you told us three things. Weekly reports take two days to put together. Late deliveries only show up when a customer complains. And your data is spread across four different tools."),
                Slide(.columns, "Before and after", ["Today", "Spreadsheets emailed on Fridays", "Problems found late", "With Northwind", "Live dashboard every morning", "Alerts before a delivery slips"], notes: "Here's what changes. Today it's spreadsheets emailed on Fridays, and problems are found late. With Northwind there's a live dashboard every morning, and an alert before a delivery slips, not after."),
                Slide(.stats, "What similar teams saw", ["-80%", "time spent on reporting", "3×", "faster response to late loads", "6 weeks", "to full rollout"], notes: "Teams like yours spent eighty percent less time on reporting, responded three times faster to late loads, and were fully rolled out in six weeks."),
                Slide(.quote, "We stopped arguing about whose numbers were right.", ["Head of Operations, Contoso Haulage (pilot customer)"], notes: "This is my favourite line from our pilot at Contoso Haulage. Once everyone saw the same live numbers, the arguments about whose spreadsheet was right simply stopped."),
                Slide(.closing, "Next step: a 30-day pilot", ["Reply to this email and we'll set it up with your data"], notes: "So the next step is a thirty-day pilot with your own data. Just reply to this email and we'll set everything up. Thanks for your time."),
            ]),
        SampleDeck(
            id: "hand-hygiene", sector: .healthcare, title: "Hand hygiene refresher",
            useCase: "Mandatory training refreshed every year, watched on any device",
            audience: "Ward staff and volunteers", minutes: 6,
            setup: ["Slides as the screen", "iPhone on a stand as a second camera for the hand-washing demo", "Captions burned in for noisy wards"],
            prompt: "Make a six-minute staff refresher on hand hygiene using the five moments, with a short checklist at the end.",
            accent: "#38BDF8",
            slides: [
                Slide(.title, "Hand hygiene refresher", ["Riverside Community Hospital · annual training"], notes: "Hello, and thanks for taking a few minutes for this year's hand hygiene refresher. It's short, and it's one of the simplest ways we keep our patients safe."),
                Slide(.steps, "Your five moments", ["Before touching a patient", "Before a clean or aseptic procedure", "After body fluid exposure risk", "After touching a patient", "After touching patient surroundings"], notes: "There are five moments to clean your hands: before touching a patient, before a clean or aseptic procedure, after any risk of contact with body fluids, after touching a patient, and after touching their surroundings."),
                Slide(.columns, "Rub or wash?", ["Alcohol rub", "Hands look clean", "20–30 seconds", "Soap and water", "Hands visibly dirty", "40–60 seconds"], notes: "Rub or wash? If your hands look clean, alcohol rub is fine: rub for twenty to thirty seconds, until dry. If they're visibly dirty, use soap and water for forty to sixty seconds."),
                Slide(.stats, "Our ward audit", ["92%", "compliance last quarter", "98%", "our target this year"], notes: "Our last ward audit showed ninety-two percent compliance. That's good, but this year we're aiming for ninety-eight, so every moment counts."),
                Slide(.bullets, "Before you finish", ["Nails short, no false nails", "Bare below the elbows", "Report sore or cracked skin to occupational health"], notes: "A few last reminders. Keep nails short, and no false nails. Stay bare below the elbows. And if your skin gets sore or cracked, tell occupational health."),
                Slide(.closing, "Thank you for keeping patients safe", ["Complete the quiz on the learning portal"], notes: "Thank you for everything you do to keep patients safe. Please finish the short quiz on the learning portal to complete your training."),
            ]),
        SampleDeck(
            id: "board-results", sector: .finance, title: "Q2 results for the board",
            useCase: "A recorded results briefing board members watch before the meeting",
            audience: "Board and investors", minutes: 8,
            setup: ["Slides as the screen", "Camera inset top-right, plain studio background", "Export with chapters so directors can jump to a section"],
            prompt: "Turn these quarterly numbers into an eight-minute board briefing with highlights, risks and asks.",
            accent: "#FFB020",
            slides: [
                Slide(.title, "Q2 results", ["Example Holdings Ltd · board briefing"], notes: "Good morning. This is our Q2 briefing for Example Holdings, so you have the headlines before Thursday's meeting. It takes about eight minutes."),
                Slide(.stats, "Headlines", ["£4.2m", "revenue, up 12% on Q1", "31%", "gross margin", "£1.1m", "cash generated"], notes: "Revenue was four point two million pounds, up twelve percent on the first quarter. Gross margin held at thirty-one percent, and we generated one point one million in cash."),
                Slide(.columns, "What went well, what didn't", ["Went well", "Subscription renewals at 94%", "Two enterprise contracts signed", "Watch", "Hardware costs up 8%", "One delayed product launch"], notes: "What went well: subscription renewals reached ninety-four percent, and we signed two enterprise contracts. What we're watching: hardware costs rose eight percent, and one product launch has slipped."),
                Slide(.bullets, "Risks", ["Currency exposure on US contracts", "Hiring for two senior roles still open", "Supplier concentration in one region"], notes: "Three risks to flag: our currency exposure on US contracts, two senior roles still unfilled, and too much of our supply coming from one region."),
                Slide(.steps, "What we need from the board", ["Approve the Q3 hiring plan", "Agree the hedging policy", "Note the revised launch date"], notes: "We need three things from the board on Thursday: approval of the Q3 hiring plan, agreement on the hedging policy, and to note the revised launch date."),
                Slide(.closing, "Questions before Thursday?", ["Reply in the board portal; full pack attached"], notes: "If you have questions before Thursday, please post them in the board portal. The full pack is attached. Thank you."),
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
                Slide(.bullets, "What we value", ["Be kind, be direct", "Ship small, learn fast", "Leave things better than you found them"], notes: "Three things we value. Be kind, and be direct: say what you think, nicely. Ship small and learn fast. And leave things a little better than you found them."),
                Slide(.steps, "Your first week", ["Day 1: laptop, accounts and lunch with your buddy", "Day 2: meet your team and pick a starter task", "Day 3–4: shadow a customer call", "Day 5: show us what you learned"], notes: "Here's your first week. Day one is your laptop, your accounts and lunch with your buddy. Day two you meet your team and pick a starter task. Then you'll shadow a customer call, and on Friday you show us what you learned."),
                Slide(.columns, "Who to ask", ["People team", "Leave, pay, benefits", "Your buddy", "Everything else, really"], notes: "Who to ask? The People team for leave, pay and benefits. Your buddy for everything else, really. No question is too small."),
                Slide(.quote, "Nobody expects you to know everything in week one.", ["Sam, Head of People"], notes: "Sam, our Head of People, says this to everyone who joins: nobody expects you to know everything in week one. So ask lots of questions."),
                Slide(.closing, "See you on Monday", ["Questions before then? Just reply to the welcome email"], notes: "We can't wait to meet you on Monday. If anything comes up before then, just reply to the welcome email."),
            ]),
        SampleDeck(
            id: "campaign-launch", sector: .marketing, title: "Spring campaign launch",
            useCase: "Briefing the whole company and partner agencies in one video",
            audience: "Internal teams and agencies", minutes: 6,
            setup: ["Slides plus a browser window with the landing page", "Camera inset with the Spotlight background", "Upload the result for agency partners"],
            prompt: "Make a campaign briefing deck: the idea, audience, channels, key dates and what each team needs to do.",
            accent: "#FF6A55",
            slides: [
                Slide(.title, "Fresh Start", ["Spring campaign · launches 3 March"], notes: "This is Fresh Start, our spring campaign. It launches on the third of March, and here's everything you need to know in a few minutes."),
                Slide(.quote, "Small changes, big spring.", ["Campaign line"], notes: "Our campaign line is: small changes, big spring. Everything we make should come back to that idea."),
                Slide(.columns, "Who we're talking to", ["Primary", "First-time home owners", "25–34, mobile first", "Secondary", "Returning customers", "Lapsed in the last year"], notes: "Who we're talking to. First, first-time home owners aged twenty-five to thirty-four, mostly on their phones. Second, returning customers who've lapsed in the last year."),
                Slide(.stats, "Goals", ["+20%", "new customer sign-ups", "40k", "email list growth", "4.5★", "average review score"], notes: "Our goals: twenty percent more new customer sign-ups, forty thousand more people on the email list, and an average review score of four and a half stars."),
                Slide(.steps, "Key dates", ["10 Feb: creative signed off", "24 Feb: social teasers start", "3 Mar: launch day", "31 Mar: results review"], notes: "The key dates. Creative is signed off on the tenth of February, social teasers start on the twenty-fourth, we launch on the third of March, and we review the results on the thirty-first."),
                Slide(.closing, "Assets are in the shared folder", ["Questions to the campaign channel"], notes: "All the assets are in the shared folder, and questions go to the campaign channel. Let's make it a great launch."),
            ]),
        SampleDeck(
            id: "property-tour", sector: .realEstate, title: "14 Elm Row: the walkthrough",
            useCase: "A narrated property video for buyers who can't visit in person",
            audience: "Prospective buyers", minutes: 4,
            setup: ["iPhone as the camera, walking the rooms", "Slides for floor plan and key facts", "Background blur off — show the room"],
            prompt: "Make a short property presentation with key facts, the floor plan highlights, local area and how to book a viewing.",
            accent: "#0F766E",
            slides: [
                Slide(.title, "14 Elm Row", ["Three-bedroom Victorian terrace · offers over £450,000"], notes: "Welcome to fourteen Elm Row, a three-bedroom Victorian terrace, with offers invited over four hundred and fifty thousand pounds. Let me show you around."),
                Slide(.stats, "At a glance", ["3", "bedrooms", "1,180 ft²", "internal space", "60 ft", "south-facing garden"], notes: "At a glance: three bedrooms, eleven hundred and eighty square feet inside, and a sixty-foot south-facing garden."),
                Slide(.bullets, "Highlights", ["Original fireplaces and high ceilings", "Kitchen extended in 2022", "Loft with planning permission"], notes: "The highlights: original fireplaces and high ceilings, a kitchen extended in 2022, and a loft that already has planning permission."),
                Slide(.columns, "The area", ["Nearby", "Station 6 minutes' walk", "Two 'Outstanding' schools", "Weekends", "Riverside park", "Saturday market"], notes: "The area: the station is six minutes' walk, and there are two Outstanding schools nearby. At weekends there's the riverside park and the Saturday market."),
                Slide(.closing, "Book a viewing", ["Call Oakfield Estates or reply to this message"], notes: "If you'd like to see it in person, call Oakfield Estates or reply to this message, and we'll book you a viewing."),
            ]),
        SampleDeck(
            id: "impact-report", sector: .nonprofit, title: "Riverbank Clean-up: our year",
            useCase: "An annual impact video for donors and volunteers",
            audience: "Donors, volunteers and local partners", minutes: 5,
            setup: ["Camera with a warm studio background", "Slides with photos from the year", "Captions and a share link for social"],
            prompt: "Create an impact report deck thanking volunteers, with our numbers for the year and what donations will fund next.",
            accent: "#22C55E",
            slides: [
                Slide(.title, "Thank you", ["Riverbank Clean-up · our year in five minutes"], notes: "Before anything else: thank you. This is our year in five minutes, and none of it would have happened without you."),
                Slide(.stats, "What you made possible", ["412", "volunteers", "9.6 t", "of litter removed", "23 km", "of riverbank cleared"], notes: "Here's what you made possible: four hundred and twelve volunteers, nine point six tonnes of litter removed, and twenty-three kilometres of riverbank cleared."),
                Slide(.quote, "My kids now spot litter before I do.", ["Priya, volunteer since spring"], notes: "Priya has volunteered with us since spring. She told us her kids now spot litter before she does. That's the change we hope for."),
                Slide(.bullets, "What's next", ["Two new sites downstream", "Litter traps on three storm drains", "School workshops every term"], notes: "Next year we're going further: two new sites downstream, litter traps on three storm drains, and workshops in schools every term."),
                Slide(.stats, "What your gift does", ["£10", "buys a litter picker", "£50", "funds a school workshop", "£250", "installs a drain trap"], notes: "Here's what your gift does. Ten pounds buys a litter picker. Fifty funds a school workshop. Two hundred and fifty installs a trap on a storm drain."),
                Slide(.closing, "Join us on the first Saturday of the month", ["riverbank-cleanup.example.org"], notes: "Come and join us on the first Saturday of every month. Everything's on our website. Thank you again."),
            ]),
        SampleDeck(
            id: "router-reset", sector: .support, title: "How to reset your router",
            useCase: "A help-centre video that answers a top support question",
            audience: "Customers", minutes: 3,
            setup: ["iPhone or iPad camera pointed at the router", "Slides for the steps", "Captions, and keep it under three minutes"],
            prompt: "Make a short how-to deck for resetting our router, with numbered steps and what to do if it still doesn't work.",
            accent: "#3B82F6",
            slides: [
                Slide(.title, "Reset your router in 2 minutes", ["SwiftLink Home Hub 3"], notes: "Hi. In the next two minutes I'll show you how to reset your SwiftLink Home Hub 3. You'll need a paper clip."),
                Slide(.steps, "Steps", ["Find the small reset hole on the back", "Hold a paper clip in it for 10 seconds", "Wait for the light to turn solid white", "Reconnect with the password on the sticker"], notes: "First, find the small reset hole on the back. Hold a paper clip in it for ten seconds. Wait until the light turns solid white, then reconnect using the password on the sticker."),
                Slide(.columns, "What the lights mean", ["Lights", "White: working", "Orange: starting up", "Red", "No signal from the street", "Check the cable is pushed in"], notes: "What do the lights mean? White means it's working. Orange means it's starting up. Red means there's no signal from the street, so check the cable is pushed in properly."),
                Slide(.closing, "Still stuck?", ["Chat with us in the app, any time"], notes: "Still stuck? Chat with us in the app, any time, and we'll help you get back online."),
            ]),
        SampleDeck(
            id: "safety-briefing", sector: .manufacturing, title: "Line 3 safety briefing",
            useCase: "A shift-start safety briefing recorded once, played on the floor screen",
            audience: "Operators and contractors", minutes: 4,
            setup: ["Camera with a plain background", "Slides with big text for the floor screen", "Burned-in captions (it's loud)"],
            prompt: "Create a four-minute safety briefing for a packaging line: hazards, PPE, the stop procedure and who to call.",
            accent: "#F59E0B",
            slides: [
                Slide(.title, "Line 3 safety briefing", ["Read before every shift · Unit 7 packaging"], notes: "This is the Line 3 safety briefing for Unit 7 packaging. Please watch it before every shift. It takes five minutes."),
                Slide(.bullets, "PPE on the line", ["Safety boots and hi-vis at all times", "Cut-resistant gloves at the cutter", "Ear defenders past the yellow line"], notes: "PPE on the line: safety boots and hi-vis at all times, cut-resistant gloves at the cutter, and ear defenders once you're past the yellow line."),
                Slide(.steps, "If something goes wrong", ["Hit the red stop button", "Shout 'Line stop'", "Tell your shift lead", "Log it on the tablet before restarting"], notes: "If something goes wrong: hit the red stop button, shout 'Line stop', tell your shift lead, and log it on the tablet before anyone restarts the line."),
                Slide(.stats, "This month", ["41", "days without a lost-time injury", "3", "near misses reported — thank you"], notes: "This month we're at forty-one days without a lost-time injury, and three near misses were reported. Thank you for reporting them: that's how we stay safe."),
                Slide(.closing, "Safe shift, everyone", ["Shift lead today: radio channel 2"], notes: "Have a safe shift, everyone. Today's shift lead is on radio channel two."),
            ]),
        SampleDeck(
            id: "menu-briefing", sector: .hospitality, title: "New autumn menu",
            useCase: "A menu briefing so every shift knows the dishes before service",
            audience: "Front-of-house and kitchen staff", minutes: 5,
            setup: ["iPad overhead camera showing each plate", "Slides for allergens", "Share link in the staff group chat"],
            prompt: "Build a menu briefing deck for staff: new dishes, how to describe them, allergens and pairings.",
            accent: "#B45309",
            slides: [
                Slide(.title, "Autumn menu", ["The Copper Kettle · starts Friday"], notes: "Hi team. This is our new autumn menu at the Copper Kettle, starting on Friday. Here's what you need to know."),
                Slide(.bullets, "New dishes", ["Roast squash with sage brown butter", "Braised short rib, celeriac mash", "Apple and blackberry crumble"], notes: "Three new dishes: roast squash with sage brown butter, braised short rib with celeriac mash, and apple and blackberry crumble."),
                Slide(.columns, "Allergens", ["Contains nuts", "Squash (hazelnut dukkah)", "Crumble (almond topping)", "Gluten-free", "Short rib", "Crumble on request"], notes: "Allergens. The squash has a hazelnut dukkah and the crumble has an almond topping, so both contain nuts. The short rib is gluten-free, and the crumble can be made gluten-free on request."),
                Slide(.quote, "Describe the short rib as 'slow-cooked for eight hours'. Guests love hearing that.", ["Head chef"], notes: "A tip from our head chef: describe the short rib as slow-cooked for eight hours. Guests love hearing that."),
                Slide(.closing, "Tasting at 4pm Thursday", ["Every shift lead please attend"], notes: "We're tasting everything at four o'clock on Thursday. Every shift lead, please be there."),
            ]),
        SampleDeck(
            id: "release-demo", sector: .developers, title: "Release 2.4 demo",
            useCase: "A release walkthrough recorded straight from the pull request",
            audience: "The team, reviewers and customers", minutes: 6,
            setup: ["Screen: the app plus the code editor", "Camera inset small, bottom-right", "Generate captions and a summary from the recording"],
            prompt: "Make a release demo deck from my pull requests: what changed, a before/after, and how to upgrade.",
            accent: "#8B5CF6",
            slides: [
                Slide(.title, "Release 2.4", ["Faster search and offline mode"], notes: "Welcome to the release 2.4 demo. The big news is faster search and an offline mode."),
                Slide(.bullets, "What's new", ["Search results in under 100 ms", "Offline mode for the mobile app", "Dark mode for reports"], notes: "What's new: search results in under a hundred milliseconds, offline mode in the mobile app, and dark mode for reports."),
                Slide(.stats, "By the numbers", ["5×", "faster search", "38", "pull requests merged", "0", "breaking changes"], notes: "By the numbers: search is five times faster, thirty-eight pull requests were merged, and there are no breaking changes."),
                Slide(.steps, "Upgrade", ["Update the package to 2.4.0", "Run the migration command", "Turn on offline mode in settings"], notes: "To upgrade, update the package to 2.4.0, run the migration command, and switch on offline mode in settings."),
                Slide(.closing, "Thanks, contributors", ["Full changelog in the release notes"], notes: "A big thank you to everyone who contributed. The full changelog is in the release notes."),
            ]),
        SampleDeck(
            id: "build-ship-ai", sector: .developers, title: "Build & Ship AI",
            useCase: "Curriculum for a Skool group that ships production-grade AI apps and a public showcase",
            audience: "Builders joining Build & Ship AI", minutes: 50,
            setup: ["Slides as the screen", "Camera inset bottom-right, rounded", "Record This Deck so each course is a chapter"],
            prompt: "Make a 50-minute curriculum deck for a Skool group called Build & Ship AI: eight courses, then a slide per lesson with what you learn, what you build and when it is done, ending in a production showcase film.",
            accent: "#6C5CFF",
            slides: [
                Slide(.title, "Build & Ship AI", ["A Skool group for people who ship production-grade AI apps, not demos"], notes: "Welcome them. This is the course map for the group: eight courses, thirty-two lessons, one shipped app you can put on a stage."),
                Slide(.bullets, "The promise", ["Leave with a live product, not a notebook", "AI as a system: models, tools, evals, spend caps", "A public showcase video of the thing you shipped"], notes: "Say the promise twice: you will ship something people can use, with the boring production pieces, and you will record a showcase of it."),
                Slide(.columns, "Who this is for", ["Builders", "Engineers, PMs and founders who can ship a vertical slice", "You already use ChatGPT or Cursor", "You want users, not another tutorial", "Not this", "Prompt-only playlists with no product", "Not this either", "Research papers with no customers"], notes: "This group is for people who can already write or steer code. We are not teaching Python from zero. We are teaching how to get an AI product into production."),
                Slide(.stats, "What you ship", ["1", "production URL with real users or a real waitlist", "1", "eval set that catches regressions", "1", "three-minute showcase film"], notes: "The capstone is three artefacts: a live URL, a small eval harness, and a three-minute film of the product working."),
                Slide(.bullets, "The production bar", ["Secrets never in git, logs or chat", "Ask before anything leaves the machine", "Traces for every model and tool call", "A kill switch and a spend cap", "A human in the loop for irreversible actions"], notes: "Read these slowly. This is the difference between a weekend demo and something you can show a customer."),
                Slide(.steps, "Eight courses, one arc", ["Welcome: builders who ship", "Find a problem worth shipping", "AI systems, not chat windows", "Product, UX and trust", "Architecture of production AI", "Build the vertical slice", "Ship for real", "Showcase night"], notes: "Walk the arc with your hand. Each course is one Skool classroom. Skip none. The last week is a public demo of what you built."),
                Slide(.quote, "A chatbot in a notebook is homework. A system with users is a product.", ["Build & Ship AI"], notes: "Pause. Let this land. Then: every lesson exists to move you from homework to product."),
                Slide(.bullets, "Course 0 — Welcome: builders who ship", ["0.1 Promise, rules, how we give feedback", "0.2 What production-grade means here", "0.3 Tooling: Git, Cursor, one cloud model, one local", "0.4 Pick your lane and open a shipping log"], notes: "Week zero. Get accounts working. Everyone posts a two-line shipping log: who they help, and the URL they will own by week seven."),
                Slide(.columns, "0.1 Promise, rules and feedback", ["You'll learn", "How lessons, live calls and logs work", "Feedback: kind, specific, on the artefact", "Asking for help with code and error", "You'll build", "Your intro post and a shipping log thread", "Done when: your log names who you help and your URL goal"], notes: "Explain the promise and the rhythm. Everyone posts an intro and opens a shipping log today. Public commitment is what gets people to showcase night."),
                Slide(.columns, "0.2 What production-grade means here", ["You'll learn", "Live URL, real users, evals, traces", "Spend caps, kill switch, human approval", "Demo versus product, side by side", "You'll build", "Your copy of the production checklist", "Done when: you can explain each item in one sentence"], notes: "Read the production bar slowly and show a weekend demo next to a product. Every later lesson ticks off part of this checklist."),
                Slide(.columns, "0.3 Tooling: Git, Cursor, cloud and local", ["You'll learn", "Git, GitHub and an AI code editor", "One cloud model and one local model", "Keys in .env, spend limits on day one", "You'll build", "A starter repo that calls both models", "Done when: fresh clone runs in one command, no keys in Git"], notes: "Do it live. Add .env to .gitignore first, set a spend limit on the provider dashboard. Leaked keys get abused within minutes."),
                Slide(.columns, "0.4 Pick your lane, open your log", ["You'll learn", "Lanes: copilot, specialist agent, workflow", "One user, one painful job, one sentence", "Why boring, real problems win", "You'll build", "A one-page brief for your app", "Done when: your brief is posted and a peer challenged it"], notes: "Give an example from each lane. Push for a specific user they can talk to. The brief is the north star for every course after this."),
                Slide(.bullets, "Course 1 — Find a problem worth shipping", ["1.1 Jobs-to-be-done: talk to five people", "1.2 The wedge: one user, one job, one metric", "1.3 Where AI belongs — and where code is enough", "1.4 Fake door, waitlist, or a paid letter of intent"], notes: "No building the model yet. If they cannot name five people and one number, they do not start Course 2."),
                Slide(.columns, "1.1 Jobs-to-be-done: talk to five people", ["You'll learn", "Interviewing without pitching", "Finding the job behind the request", "Writing up what you heard", "You'll build", "Notes from five user conversations", "Done when: five calls logged, with quotes, in your log"], notes: "Role-play an interview in the call. Ban the question 'would you use this?'. Ask about the last time they did the job instead."),
                Slide(.columns, "1.2 The wedge: one user, one job, one metric", ["You'll learn", "Narrowing to the smallest valuable job", "Choosing the one number that shows success", "What you will not build", "You'll build", "A wedge statement and its metric", "Done when: a stranger understands your wedge in ten seconds"], notes: "Read wedges aloud and cut each one in half. The metric must be something a user would notice, like minutes saved per week."),
                Slide(.columns, "1.3 Where AI belongs, and where code is enough", ["You'll learn", "Tasks models are good and bad at", "Rules and code for anything exact", "Mapping your job into AI and code steps", "You'll build", "A flow diagram marking AI steps and code steps", "Done when: every AI step says why code can't do it"], notes: "Many steps are plain code. Models for language and judgement, code for maths, rules and anything that must be exact."),
                Slide(.columns, "1.4 Fake door, waitlist or letter of intent", ["You'll learn", "Testing demand before building", "A landing page with one call to action", "Asking for a commitment, not a compliment", "You'll build", "A fake door, waitlist or paid letter of intent", "Done when: real sign-ups or a signed letter, in your log"], notes: "No Course 2 without a number. Ten waitlist sign-ups from strangers beats a hundred likes from friends."),
                Slide(.bullets, "Course 2 — AI systems, not chat", ["2.1 Model vs code vs retrieval vs tools", "2.2 Prompts as product: versioned and tested", "2.3 Tool calling, agents, human in the loop", "2.4 Eval harness from day one (twenty gold cases)"], notes: "This week they replace 'I asked the model' with a loop: input, tools, check, retry. Twenty gold cases in a file. That file is the product."),
                Slide(.columns, "2.1 Model vs code vs retrieval vs tools", ["You'll learn", "Tokens, context, cost and latency", "Retrieval (RAG) for your own data", "Tools when the AI must act", "You'll build", "Your first streaming model call in the app", "Done when: you can explain cost and latency of your main call"], notes: "Show the pricing page and a big versus small model on the same task. When the data won't fit in context, retrieve it. When the AI must act, give it a tool."),
                Slide(.columns, "2.2 Prompts as product: versioned and tested", ["You'll learn", "Instructions, context and examples", "Structured output that matches a schema", "Prompts in Git, reviewed like code", "You'll build", "Your system prompt in a file, with JSON output", "Done when: 100 sample inputs, zero schema failures"], notes: "Show a vague prompt, then one with role, context, format and examples. Validate every output with Zod or Pydantic, even when the model is usually right."),
                Slide(.columns, "2.3 Tool calling, agents, human in the loop", ["You'll learn", "The tool loop: ask, run, return", "MCP to plug in tools from anywhere", "Approval before anything irreversible", "You'll build", "Two tools and an approval step in your app", "Done when: a doc saying 'ignore your rules' can't trigger an action"], notes: "Tool descriptions are prompts. Run the prompt-injection demo live. Rule: the model proposes, a person or a policy approves."),
                Slide(.columns, "2.4 Eval harness from day one", ["You'll learn", "Twenty gold cases from real inputs", "Graders: code checks and LLM-as-judge", "One command, one score", "You'll build", "An eval file with twenty gold cases and a runner", "Done when: your score prints, and a bad prompt lowers it"], notes: "Evals are unit tests for behaviour. Start with twenty cases and grow it. That file is the product."),
                Slide(.bullets, "Course 3 — Product, UX and trust", ["3.1 Latency, streaming, empty and error states", "3.2 Show your work: citations, diffs, ask first", "3.3 Cost per successful action", "3.4 Privacy: what never leaves the device"], notes: "Users forgive a slow answer they can see thinking. They do not forgive a silent wrong one. Cost and privacy are product features, not later."),
                Slide(.columns, "3.1 Latency, streaming, empty and error states", ["You'll learn", "Streaming so first words appear fast", "Stop, retry and copy buttons", "Loading, empty and error states", "You'll build", "A streaming UI with every state designed", "Done when: first words in under a second; errors are friendly"], notes: "Show waiting versus streaming. Build the stop button live, it's the feature people miss most. Pull the network cable to test errors."),
                Slide(.columns, "3.2 Show your work: citations, diffs, ask first", ["You'll learn", "Citing sources from retrieval", "Showing diffs before changes", "Saying 'I don't know'", "You'll build", "Citations or a preview on every AI answer", "Done when: out-of-scope questions get an honest 'not sure'"], notes: "Trust comes from seeing the work. Demo an out-of-scope question. Retrieved text is data, not instructions."),
                Slide(.columns, "3.3 Cost per successful action", ["You'll learn", "Measuring cost per task, not per call", "Caching, smaller models, batching", "Pricing above your cost floor", "You'll build", "A cost-per-action number for your main task", "Done when: cost known, lowered once, eval score unchanged"], notes: "Measure first. Caching a long system prompt and moving easy tasks to a small model are usually the biggest wins. Re-run evals after every cost change."),
                Slide(.columns, "3.4 Privacy: what never leaves the device", ["You'll learn", "Data minimisation and redaction", "Local models for sensitive steps", "Retention and deletion", "You'll build", "A data map: what leaves, where, why", "Done when: your privacy page matches the data map"], notes: "Privacy is a feature you can sell. Walk a data map for a member's app. Anything sensitive gets redacted or stays local."),
                Slide(.bullets, "Course 4 — Architecture of production AI", ["4.1 Auth, data model, secrets", "4.2 Queues, retries, idempotency", "4.3 Observability: a trace per request", "4.4 Rate limits, spend caps, kill switch"], notes: "Draw the box: client, API, queue, model, tools, store. If they cannot point to the spend cap and the kill switch, it is not production yet."),
                Slide(.columns, "4.1 Auth, data model, secrets", ["You'll learn", "Keys on the server, never the browser", "Hosted auth and per-user data", "Secrets manager and key rotation", "You'll build", "Sign-in, saved history and an architecture diagram", "Done when: two test users can't see each other's data"], notes: "Draw the box live: client, API, queue, model, tools, store. Calling a model from the browser with a key leaks it."),
                Slide(.columns, "4.2 Queues, retries, idempotency", ["You'll learn", "Background jobs for slow work", "Retries with backoff and timeouts", "Idempotency so retries are safe", "You'll build", "A queue for long tasks and a model fallback", "Done when: with the model blocked, no work is lost"], notes: "Simulate an outage. Users forgive slow, they don't forgive lost work."),
                Slide(.columns, "4.3 Observability: a trace per request", ["You'll learn", "Tracing every model and tool call", "User feedback with a reason", "Alerts on errors, latency and spend", "You'll build", "Tracing and thumbs up/down in your app", "Done when: any complaint opens to what the model saw and said"], notes: "Show a trace of a bad answer and walk back to the cause. Feedback flows into the eval set, which closes the loop."),
                Slide(.columns, "4.4 Rate limits, spend caps, kill switch", ["You'll learn", "Per-user limits against abuse and bills", "A hard monthly spend cap", "A kill switch that fails closed", "You'll build", "Limits, a spend cap and a kill switch", "Done when: request 51 is blocked; the switch stops AI in seconds"], notes: "If they can't point to the spend cap and the kill switch, it's not production. Test both live."),
                Slide(.bullets, "Course 5 — Build the vertical slice", ["5.1 One happy path, end to end, this week", "5.2 Tests on the agent path", "5.3 One screen that looks like a real product", "5.4 Record a ninety-second work-in-progress"], notes: "Narrow ruthlessly. One user, one job, one screen. Record the ninety seconds even if it is ugly. Shipping log gets the link."),
                Slide(.columns, "5.1 One happy path, end to end", ["You'll learn", "Cutting scope to one path", "Wiring UI, API, model and store", "Deploying from main", "You'll build", "Your happy path working on a real URL", "Done when: a user can finish the job without your help"], notes: "Narrow ruthlessly: one user, one job, one screen. Ship ugly, ship early."),
                Slide(.columns, "5.2 Tests on the agent path", ["You'll learn", "Unit tests for tools and parsing", "Evals in CI on every pull request", "Thresholds that block bad changes", "You'll build", "A CI job that runs tests and evals", "Done when: a deliberately bad prompt change fails CI"], notes: "Keep a small fast eval set for every PR and a full set nightly so costs stay sane."),
                Slide(.columns, "5.3 One screen that looks like a product", ["You'll learn", "Layout, type and spacing basics", "Copy that names the user's job", "Polishing the screen people see most", "You'll build", "One polished screen for your main job", "Done when: a stranger knows what to do in five seconds"], notes: "Pick the one screen users see most and make it great. Polish beats breadth."),
                Slide(.columns, "5.4 Record a ninety-second work in progress", ["You'll learn", "Problem, loop, proof in ninety seconds", "Recording screen, camera and voice", "Posting for feedback", "You'll build", "A ninety-second video in your shipping log", "Done when: posted, with two pieces of feedback answered"], notes: "Record even if it's ugly. Snazzy Pro records slides, screen and camera in one go. The link goes in the log."),
                Slide(.bullets, "Course 6 — Ship for real", ["6.1 One production URL", "6.2 Privacy, terms, logs, backups", "6.3 Payments or a real waitlist", "6.4 First ten users and an incident drill"], notes: "Live means someone who is not you can open it. Incident drill: kill the model key, confirm the app fails closed, restore."),
                Slide(.columns, "6.1 One production URL", ["You'll learn", "Hosting, environments and domains", "Preview deploys for every pull request", "Separating test and production keys", "You'll build", "Your app on its own domain over HTTPS", "Done when: someone outside the group has used it"], notes: "Live means someone who isn't you can open it. Celebrate every link posted."),
                Slide(.columns, "6.2 Privacy, terms, logs, backups", ["You'll learn", "Privacy policy and terms of use", "Logs without secrets or personal data", "Backups you have restored once", "You'll build", "Privacy and terms pages, and a tested backup", "Done when: you restored a backup to a fresh database"], notes: "A backup you haven't restored is a hope, not a backup. Check logs for keys and personal data."),
                Slide(.columns, "6.3 Payments or a real waitlist", ["You'll learn", "Pricing: subscription, credits or usage", "Checkout with Stripe in test mode", "Plan limits enforced in the app", "You'll build", "Working checkout, or a waitlist with a deposit", "Done when: a test customer can subscribe and cancel alone"], notes: "Test mode only in class. Cost per action from Course 3 sets the price floor."),
                Slide(.columns, "6.4 First ten users and an incident drill", ["You'll learn", "Finding and onboarding your first ten", "Talking to users every week", "Running an incident drill", "You'll build", "Ten users, and a written incident runbook", "Done when: key revoked: app fails closed, then you restore it"], notes: "Incident drill: kill the model key, confirm the app fails closed, restore it. Then write down what you did."),
                Slide(.bullets, "Course 7 — Showcase night", ["7.1 The three-minute story: problem, loop, proof", "7.2 Record the demo: slides, camera, chapters", "7.3 Launch: site, film, Skool post, one share", "7.4 Feedback to v1.1 in seven days"], notes: "Showcase format is fixed: one minute problem, one minute the loop, one minute proof it works in production. Then they post the film."),
                Slide(.columns, "7.1 The three-minute story", ["You'll learn", "One minute problem", "One minute the AI loop working", "One minute proof in production", "You'll build", "A three-minute script and slide outline", "Done when: a peer can retell your story after one listen"], notes: "The format is fixed: problem, loop, proof. No architecture slides without the product running."),
                Slide(.columns, "7.2 Record the demo: slides, camera, chapters", ["You'll learn", "Slides plus live product on screen", "Camera inset and clean audio", "Chapters for each part of the story", "You'll build", "Your three-minute showcase film", "Done when: it meets the showcase definition of done"], notes: "Use the prompter for your script and record the deck so every part is a chapter. Two takes maximum."),
                Slide(.columns, "7.3 Launch: site, film, Skool post, one share", ["You'll learn", "A landing page with the film", "A case study: problem, approach, results", "A launch post that tells a story", "You'll build", "Landing page, case study and launch post", "Done when: launched publicly; every comment answered"], notes: "Launch in the group first as a friendly dry run, then go public. The case study is what gets members hired or signed."),
                Slide(.columns, "7.4 Feedback to v1.1 in seven days", ["You'll learn", "Sorting feedback by evidence", "Change one thing, measure with evals", "Shipping a release note", "You'll build", "v1.1 shipped with a short release note", "Done when: your score or metric moved, and you know why"], notes: "Close the loop: feedback, eval, change, ship. Invite graduates to mentor the next cohort."),
                Slide(.columns, "A week in the group", ["Live", "60-minute lesson, then critique two logs", "Async", "Do the work, post proof, comment twice", "Gate", "No next course without the artefact", "Hours", "Office hours unblock deploys — not a lecture"], notes: "Live is short. The work is async. The gate is real: no Course 6 film until there is a URL."),
                Slide(.steps, "How Skool is set up", ["Classroom per course, lessons in order", "A Shipping Logs channel: URL or it did not happen", "Critique threads: kind, specific, about the artefact", "Showcase calendar in week seven"], notes: "Point at Skool while you say this. Classrooms match Course 0 to 7. Shipping Logs is the heartbeat."),
                Slide(.stats, "Time you should spend", ["4–6h", "build time per week", "60m", "live lesson", "8 wks", "welcome to showcase"], notes: "Be honest. If they cannot find four hours, they should audit, not commit to a showcase slot."),
                Slide(.bullets, "Showcase film — definition of done", ["Problem named in one sentence", "The AI loop on screen, not described", "A real URL, a trace, a spend cap", "What broke, and what you changed", "Ask: who should try this next week"], notes: "This checklist is also the scorecard on showcase night. No slides of architecture without the product running."),
                Slide(.columns, "Good first products", ["Ship these", "Internal copilot with tools and logs", "A specialist agent with evals", "A workflow that replaces a weekly report", "Skip these", "Generic ChatGPT wrappers", "A model trained from scratch", "A platform with no wedge"], notes: "Give examples from the room if you have them. Ban wrappers. Ban platform. Reward a sharp wedge."),
                Slide(.quote, "Ship the loop. Then make the loop trustworthy.", ["Week five, then week six"], notes: "Course five is the loop working. Course six is the loop you can leave running. Do not swap those."),
                Slide(.closing, "This week: Course 0", ["Post your shipping log: who you help, and the URL you will own by showcase night"], notes: "Give the homework. Stay for questions. First live session is Course 0.1 — promise, rules, production-grade."),
            ]),
    ]
}

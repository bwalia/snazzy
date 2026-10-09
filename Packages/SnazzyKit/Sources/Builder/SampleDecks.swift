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
    ]
}

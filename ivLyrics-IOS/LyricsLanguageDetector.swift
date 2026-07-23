import Foundation

enum LyricsLanguageDetector {
    private static let nonLatinLineShare = 0.15
    private static let nonLatinMinLines = 3

    private static let simplifiedHints = scalarSet(
        "这为国们会来时说对过还后个无爱声体见长门马鸟鱼龙云当开摇请听"
    )
    private static let traditionalHints = scalarSet(
        "這為國們會來時說對過還後個無愛聲體見長門馬鳥魚龍雲當開搖請聽"
    )
    private static let persianUnique = scalarSet("پچژگکی")

    private static let vietnamese =
        "àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ"
    private static let vietnameseUnique =
        "đươăạảắằẳẵặấầẩẫậếềểễệịỉĩọỏộốồổỗớờởỡợụủứừửữựỳỵỷỹ"
    private static let czech = "áčďéěíňóřšťúůýž"
    private static let czechUnique = "ěřů"
    private static let turkish = "çğıöşü"
    private static let turkishUnique = "ğıış"
    private static let swedish = "åäö"
    private static let swedishUnique = "å"
    private static let german = "äöüß"
    private static let germanUnique = "üß"
    private static let spanish = "áéíóúüñ¿¡"
    private static let french = "àâæçéèêëïîôùûüÿœ"
    private static let frenchUnique = "æœçëïÿ"
    private static let portuguese = "ãõáàâéêíóôúüç"
    private static let polish = "ąćęłńóśźż"

    private static let latinHints: [LanguageHints] = [
        hints(
            "de",
            "ich du nicht kein keine der die das den dem ein eine einen einem bin bist ist sind war waren werde wird werden mein meine dein deine mir dir mich dich für über schön liebe nacht herz",
            "und oder aber mit auf im in zu zum zur nur noch schon wie was wenn dann doch alles immer"
        ),
        hints(
            "en",
            "i you the and that with not for this your my me we are am is be was were have has do does don't can't love night heart",
            "to in on of it all so no yes but if when now here there"
        ),
        hints(
            "fr",
            "je tu nous vous pas ne est suis es sommes avec pour dans mon ma mes ton ta tes que qui sur plus amour coeur",
            "le la les un une des du de et ou mais ce ces en"
        ),
        hints(
            "es",
            "yo tú tu usted nosotros vosotros soy eres estoy estás no con para por mi mis tus quiero amor corazón",
            "el la los las un una de y o pero que en es como"
        ),
        hints(
            "it",
            "io tu noi voi sono sei non con per mio mia tuo tua amore cuore notte",
            "il lo la gli le un una di e o ma che in come"
        ),
        hints(
            "pt",
            "eu você voce nós nos sou és esta está não nao com para por meu minha teu tua amor coração coracao",
            "o a os as um uma de e ou mas que em como"
        ),
        hints(
            "sv",
            "jag du vi ni inte är var med för min mitt din ditt kärlek hjärta natt",
            "och eller men det den en ett i på som om allt"
        ),
        hints(
            "tr",
            "ben sen biz siz değil degil için icin çok cok gibi beni seni aşk ask kalp gece",
            "ve bir bu o da de mi ne ile ama her"
        ),
        hints(
            "cs",
            "já ty jsme jste není nejsem jsem jsi můj moje tvůj tvoje láska srdce noc tebe tobě chci mám",
            "a ale nebo že se si do na pro s z když jen už jak"
        ),
        hints(
            "pl",
            "ja ty my wy nie jest są sa dla przez mój moj moja twój twoj twoja miłość milosc serce noc",
            "i lub ale to ten ta te w na z do jak"
        ),
        hints(
            "nl",
            "ik jij je wij niet ben bent is zijn met voor mijn jouw liefde hart nacht",
            "de het een en of maar dat dit in op als"
        ),
        hints(
            "id",
            "aku kamu kau tidak tak bisa ingin karena denganmu bersamamu dirimu cinta hati hatiku rindu malam sendiri selalu pernah",
            "yang dan di ke dari untuk dengan ini itu ada akan bukan hanya jangan semua tanpa membuat percaya"
        ),
        hints(
            "ms",
            "aku saya awak kau tidak tak mahu boleh kerana denganmu bersamamu dirimu cinta hati hatiku rindu malam sendiri selalu pernah",
            "yang dan di ke dari untuk dengan ini itu ada akan bukan hanya jangan semua tanpa percaya"
        ),
        hints(
            "vi",
            "anh em tôi không của yêu đêm một những người biết quên được thương nhớ lòng đời mãi",
            "và cho với này khi rồi vẫn chỉ đã sẽ lại thêm"
        )
    ]

    private static let diacriticBearing: [(language: String, characters: String)] = [
        ("es", "áéíóúüñ¿¡"),
        ("cs", czech),
        ("fr", french),
        ("it", "àèéìòù"),
        ("pl", polish),
        ("pt", portuguese),
        ("tr", turkish),
        ("de", german),
        ("sv", swedish),
        ("vi", "đươăạảấầẩẫậắằẳẵặếềểễệốồổỗộớờởỡợụủứừửữựỳỵỷỹ")
    ]

    static func detect(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.precomposedStringWithCanonicalMapping
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var lineVotes: [(script: Script, count: Int)] = []
        for line in normalized.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            guard let script = scriptOfLine(String(line)) else { continue }
            if let index = lineVotes.firstIndex(where: { $0.script == script }) {
                lineVotes[index].count += 1
            } else {
                lineVotes.append((script, 1))
            }
        }

        let totalVotes = lineVotes.reduce(0) { $0 + $1.count }
        var dominantNonLatin: (script: Script, count: Int)?
        for vote in lineVotes where vote.script != .latin {
            if dominantNonLatin == nil || vote.count > dominantNonLatin!.count {
                dominantNonLatin = vote
            }
        }

        let hookFloorApplies = totalVotes >= 4
        if let dominantNonLatin,
           (!hookFloorApplies || dominantNonLatin.count >= nonLatinMinLines),
           Double(dominantNonLatin.count) / Double(max(1, totalVotes)) >= nonLatinLineShare {
            return resolveNonLatin(dominantNonLatin.script, normalized)
        }

        if let latinLanguage = detectLatinLanguage(normalized) {
            return latinLanguage
        }
        return countLatin(normalized) > 2 ? "en" : nil
    }

    private static func scriptOfLine(_ line: String) -> Script? {
        var counts = Array(repeating: 0, count: Script.allCases.count)
        for scalar in line.unicodeScalars {
            if let script = scriptOf(scalar.value) {
                counts[script.rawValue] += 1
            }
        }

        var best: Script?
        var bestCount = 0
        for script in Script.allCases where counts[script.rawValue] > bestCount {
            best = script
            bestCount = counts[script.rawValue]
        }
        return best
    }

    private static func scriptOf(_ value: UInt32) -> Script? {
        switch value {
        case 0x0980...0x09ff:
            return .bengali
        case 0x0900...0x097f:
            return .devanagari
        case 0x0e00...0x0e7f:
            return .thai
        case 0x0600...0x06ff:
            return .arabic
        case 0x0400...0x04ff:
            return .cyrillic
        default:
            if isHangul(value) || isKana(value) || isHan(value) {
                return .cjk
            }
            return isLatin(value) ? .latin : nil
        }
    }

    private static func resolveNonLatin(_ script: Script, _ text: String) -> String? {
        switch script {
        case .cjk:
            return resolveCJK(text)
        case .arabic:
            let arabicCount = text.unicodeScalars.filter {
                (0x0600...0x06ff).contains($0.value)
            }.count
            let persianCount = text.unicodeScalars.filter {
                persianUnique.contains($0)
            }.count
            return arabicCount > 0 && Double(persianCount) / Double(arabicCount) >= 0.07
                ? "fa"
                : "ar"
        case .cyrillic:
            return "ru"
        case .thai:
            return "th"
        case .devanagari:
            return "hi"
        case .bengali:
            return "bn"
        case .latin:
            return nil
        }
    }

    private static func resolveCJK(_ text: String) -> String? {
        var hangulCount = 0
        var kanaCount = 0
        var han: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            if isHangul(scalar.value) {
                hangulCount += 1
            } else if isKana(scalar.value) {
                kanaCount += 1
            } else if isHan(scalar.value) {
                han.append(scalar)
            }
        }

        let total = hangulCount + kanaCount + han.count
        guard total > 0 else { return nil }
        if Double(hangulCount) / Double(total) >= 0.2 {
            return "ko"
        }

        let kanaShare = Double(kanaCount) / Double(total)
        let hanShare = Double(han.count) / Double(total)
        if ((kanaShare - hanShare + 1) / 2) * 100 >= 40 {
            return "ja"
        }

        var simplifiedCount = 0
        var traditionalCount = 0
        for scalar in han {
            let simplified = simplifiedHints.contains(scalar)
            let traditional = traditionalHints.contains(scalar)
            if simplified && !traditional {
                simplifiedCount += 1
            } else if traditional && !simplified {
                traditionalCount += 1
            }
        }

        let distinguishing = simplifiedCount + traditionalCount
        guard distinguishing > 0 else { return "zh-CN" }
        let score = (
            Double(simplifiedCount) / Double(distinguishing)
                - Double(traditionalCount) / Double(distinguishing)
                + 1
        ) / 2 * 100
        return score >= 40 ? "zh-CN" : "zh-TW"
    }

    private static func detectLatinLanguage(_ text: String) -> String? {
        let lower = text.lowercased().precomposedStringWithCanonicalMapping
        let words = latinWords(lower)
        guard !words.isEmpty else { return nil }

        if words.count < 4 {
            if containsAnyPhrase(
                lower,
                ["aku cinta kamu", "aku sayang kamu", "cinta kamu"]
            ) {
                return "id"
            }
            if containsAnyPhrase(
                lower,
                ["aku sayang awak", "saya sayang awak", "cinta awak"]
            ) {
                return "ms"
            }
        }

        var scores: [(language: String, score: Int)] = latinHints.map { hints in
            let score = words.reduce(0) { partial, word in
                if hints.strong.contains(word) { return partial + 2 }
                if hints.weak.contains(word) { return partial + 1 }
                return partial
            }
            return (hints.language, score)
        }

        add(&scores, "de", countCharacters(lower, "ß") * 5
            + countCharacters(lower, "ä") * 3
            + countCharacters(lower, "öü"))
        add(&scores, "tr", countCharacters(lower, "ğıış") * 5
            + countCharacters(lower, "ç") * 2)
        add(&scores, "cs", countCharacters(lower, czechUnique) * 5
            + countCharacters(lower, "čďňšťž") * 2)
        add(&scores, "sv", countCharacters(lower, swedishUnique) * 5
            + countCharacters(lower, "äö"))

        let vietnameseSignal = countCharacters(lower, vietnameseUnique)
        add(&scores, "vi", vietnameseSignal * 3)
        add(&scores, "fr", countCharacters(lower, frenchUnique) * 3
            + (vietnameseSignal > 0 ? 0 : countCharacters(lower, "êèùû")))
        add(&scores, "es", countCharacters(lower, "ñ¿¡") * 5
            + countCharacters(lower, "áéíóú"))
        add(&scores, "pt", countCharacters(lower, "ãõ") * 5
            + countCharacters(lower, "ç"))
        add(&scores, "pl", countCharacters(lower, polish) * 5)

        if containsAnyPhrase(
            lower,
            ["ich bin", "du bist", "ich hab", "ich habe", "du hast",
             "wir sind", "es ist", "nicht mehr", "für dich", "mit dir"]
        ) {
            add(&scores, "de", 4)
        }
        if containsAnyPhrase(
            lower,
            ["i am", "you are", "don't", "can't", "with you", "for you", "my heart"]
        ) {
            add(&scores, "en", 4)
        }
        if containsAnyPhrase(
            lower,
            ["je suis", "tu es", "avec toi", "mon coeur", "mon cœur", "pour toi"]
        ) {
            add(&scores, "fr", 4)
        }
        if containsAnyPhrase(
            lower,
            ["yo soy", "estoy aquí", "estoy aqui", "contigo", "mi corazón", "mi corazon"]
        ) {
            add(&scores, "es", 4)
        }
        if containsAnyPhrase(
            lower,
            ["aku ingin", "aku bisa", "aku tak bisa", "aku tidak bisa",
             "kau dan aku", "karena aku", "karena kamu", "bersamamu",
             "denganmu", "cinta ini"]
        ) {
            add(&scores, "id", 4)
        }
        if containsAnyPhrase(
            lower,
            ["aku mahu", "aku boleh", "kau dan aku", "kerana aku",
             "kerana awak", "kerana kau", "bersamamu", "denganmu", "cinta ini"]
        ) {
            add(&scores, "ms", 4)
        }

        let nonASCII = lower.unicodeScalars.filter { $0.value > 0x7f }.count
        add(&scores, "en", -min(nonASCII, 8))

        let leadingScore = scores.map(\.score).max() ?? 0
        let evidenceDensity = Double(leadingScore) / Double(max(1, words.count))
        if words.count >= 8 && evidenceDensity < 0.2 {
            for entry in diacriticBearing {
                guard let index = scores.firstIndex(where: { $0.language == entry.language }),
                      scores[index].score > 0,
                      countCharacters(lower, entry.characters) == 0 else {
                    continue
                }
                scores[index].score /= 2
            }
        }

        let best = scores.max { lhs, rhs in
            lhs.score == rhs.score ? false : lhs.score < rhs.score
        }
        let minScore = words.count < 4 ? 2 : (words.count < 8 ? 4 : 5)
        if let best, best.score >= minScore {
            return best.language
        }
        return detectByDiacritics(lower)
    }

    private static func detectByDiacritics(_ text: String) -> String? {
        let scores: [(language: String, score: Int)] = [
            ("vi", countCharacters(text, vietnameseUnique) * 3
                + countCharacters(text, vietnamese)),
            ("cs", countCharacters(text, czechUnique) * 3
                + countCharacters(text, czech)),
            ("tr", countCharacters(text, turkishUnique) * 3
                + countCharacters(text, turkish)),
            ("sv", countCharacters(text, swedishUnique) * 3
                + countCharacters(text, swedish)),
            ("de", countCharacters(text, germanUnique) * 3
                + countCharacters(text, german)),
            ("fr", countCharacters(text, frenchUnique) * 3
                + countCharacters(text, french)),
            ("pl", countCharacters(text, polish) * 2),
            ("pt", countCharacters(text, portuguese)),
            ("es", countCharacters(text, spanish))
        ]
        guard let best = scores.max(by: { $0.score < $1.score }), best.score >= 4 else {
            return nil
        }
        return best.language
    }

    private static func latinWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""

        func appendCurrent() {
            let word = current.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
            if !word.isEmpty {
                words.append(word)
            }
        }

        for scalar in text.unicodeScalars {
            if isLatin(scalar.value) {
                current.append(Character(String(scalar)))
            } else if (scalar == "'" || scalar == "’"), !current.isEmpty {
                current.append(Character(String(scalar)))
            } else {
                appendCurrent()
                current = ""
            }
        }
        appendCurrent()
        return words
    }

    private static func containsAnyPhrase(_ text: String, _ phrases: [String]) -> Bool {
        var words = ""
        var previousWasSeparator = true
        for character in text {
            if character.isLetter || character == "'" || character == "’" {
                words.append(character)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                words.append(" ")
                previousWasSeparator = true
            }
        }
        let searchable = " \(words.trimmingCharacters(in: .whitespaces)) "
        return phrases.contains { searchable.contains(" \($0) ") }
    }

    private static func countCharacters(_ text: String, _ candidates: String) -> Int {
        let candidateSet = scalarSet(candidates)
        return text.unicodeScalars.filter(candidateSet.contains).count
    }

    private static func countLatin(_ text: String) -> Int {
        text.unicodeScalars.filter { isLatin($0.value) }.count
    }

    private static func add(
        _ scores: inout [(language: String, score: Int)],
        _ language: String,
        _ delta: Int
    ) {
        guard let index = scores.firstIndex(where: { $0.language == language }) else { return }
        scores[index].score += delta
    }

    private static func hints(_ language: String, _ strong: String, _ weak: String) -> LanguageHints {
        LanguageHints(
            language: language,
            strong: Set(strong.split(separator: " ").map(String.init)),
            weak: Set(weak.split(separator: " ").map(String.init))
        )
    }

    private static func scalarSet(_ text: String) -> Set<Unicode.Scalar> {
        Set(text.unicodeScalars)
    }

    private static func isLatin(_ value: UInt32) -> Bool {
        switch value {
        case 0x0041...0x005a, 0x0061...0x007a,
             0x00c0...0x02af, 0x1d00...0x1dbf,
             0x1e00...0x1eff, 0xab30...0xab6f,
             0xff21...0xff3a, 0xff41...0xff5a:
            return true
        default:
            return false
        }
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        (0x1100...0x11ff).contains(value)
            || (0x3130...0x318f).contains(value)
            || (0xac00...0xd7af).contains(value)
    }

    private static func isKana(_ value: UInt32) -> Bool {
        (0x3040...0x30ff).contains(value) || (0xff66...0xff9f).contains(value)
    }

    private static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4dbf).contains(value)
            || (0x4e00...0x9fff).contains(value)
            || (0xf900...0xfaff).contains(value)
            || (0x20000...0x2ebef).contains(value)
            || (0x30000...0x323af).contains(value)
    }

    private enum Script: Int, CaseIterable {
        case latin
        case cjk
        case cyrillic
        case arabic
        case thai
        case devanagari
        case bengali
    }

    private struct LanguageHints: Sendable {
        let language: String
        let strong: Set<String>
        let weak: Set<String>
    }
}

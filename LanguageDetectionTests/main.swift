import Foundation

struct Sample {
    let expected: String
    let text: String
}

let corpus = [
    Sample(expected: "en", text: """
        I remember when the summer ended
        you said my name like it was ours
        and I keep it in my pocket now
        oh oh oh, I keep it now
        """),
    Sample(expected: "ko", text: """
        너의 이름을 부르면
        내 마음이 자꾸 흔들려
        밤이 오면 더 선명해져
        그대로 있어줘
        """),
    Sample(expected: "ja", text: """
        君の名前を呼んだら
        心が揺れてしまうよ
        夜が来ればもっと鮮明に
        そのままでいて
        """),
    Sample(expected: "zh-CN", text: """
        当我叫你的名字
        我的心又开始摇晃
        夜来了就更清楚
        请你留在这里
        """),
    Sample(expected: "zh-TW", text: """
        當我叫你的名字
        我的心又開始搖晃
        夜來了就更清楚
        請你留在這裡
        """),
    Sample(expected: "es", text: """
        cuando llega la noche
        te busco en la ciudad vacía
        no sé cómo olvidarte
        quédate un poco más
        """),
    Sample(expected: "fr", text: """
        quand la nuit tombe enfin
        je te cherche dans les rues vides
        je ne sais pas t'oublier
        reste encore un peu
        """),
    Sample(expected: "de", text: """
        wenn die Nacht endlich fällt
        suche ich dich in leeren Straßen
        ich weiß nicht wie ich dich vergesse
        bleib noch ein bisschen hier
        """),
    Sample(expected: "pt", text: """
        quando a noite finalmente cai
        procuro você nas ruas vazias
        não sei como te esquecer
        fica mais um pouco
        """),
    Sample(expected: "it", text: """
        quando la notte finalmente scende
        ti cerco nelle strade vuote
        non so più come dimenticarti
        resta ancora un po' con me perché
        è così che finisce sempre
        """),
    Sample(expected: "ru", text: """
        когда наступает ночь
        я ищу тебя на пустых улицах
        я не знаю как забыть тебя
        останься еще немного
        """),
    Sample(expected: "ar", text: """
        عندما يأتي الليل
        أبحث عنك في الشوارع الفارغة
        لا أعرف كيف أنساك
        ابق قليلا بعد
        """),
    Sample(expected: "th", text: """
        เมื่อค่ำคืนมาถึง
        ฉันตามหาเธอบนถนนที่ว่างเปล่า
        ฉันไม่รู้ว่าจะลืมเธอยังไง
        อยู่ต่ออีกสักหน่อย
        """),
    Sample(expected: "hi", text: """
        जब रात आती है
        मैं तुम्हें खाली सड़कों पर ढूंढता हूँ
        मुझे नहीं पता तुम्हें कैसे भूलूँ
        थोड़ा और रुक जाओ
        """),
    Sample(expected: "vi", text: """
        khi màn đêm buông xuống
        anh tìm em trên những con phố vắng
        anh không biết làm sao quên em
        ở lại thêm một chút nữa
        """),
    Sample(expected: "tr", text: """
        gece sonunda çöktüğünde
        seni boş sokaklarda arıyorum
        seni nasıl unutacağımı bilmiyorum
        biraz daha kal yanımda
        """),
    Sample(expected: "sv", text: """
        när natten äntligen faller
        söker jag dig på tomma gator
        jag vet inte hur jag glömmer dig
        stanna kvar en liten stund
        """),
    Sample(expected: "pl", text: """
        kiedy noc wreszcie zapada
        szukam cię na pustych ulicach
        nie wiem jak cię zapomnieć
        zostań jeszcze chwilę
        """),
    Sample(expected: "cs", text: """
        když konečně padne noc
        hledám tě v prázdných ulicích
        nevím jak na tebe zapomenout
        zůstaň ještě chvíli
        """),
    Sample(expected: "nl", text: """
        als de nacht eindelijk valt
        zoek ik je in lege straten
        ik weet niet hoe ik je vergeet
        blijf nog even hier
        """),
    Sample(expected: "id", text: """
        ketika malam akhirnya tiba
        aku ingin mencarimu di jalan yang kosong
        aku tidak bisa melupakanmu
        karena cinta ini masih ada
        """),
    Sample(expected: "ms", text: """
        apabila malam akhirnya tiba
        aku mencari awak di jalan yang kosong
        aku tidak tahu cara melupakan awak
        tinggallah sebentar lagi
        """),
    Sample(expected: "fa", text: """
        وقتی شب می‌رسد
        تو را در خیابان‌های خالی می‌جویم
        نمی‌دانم چگونه فراموشت کنم
        کمی بیشتر بمان
        """),
    Sample(expected: "bn", text: """
        যখন রাত নেমে আসে
        আমি তোমাকে খালি রাস্তায় খুঁজি
        আমি জানি না কীভাবে তোমাকে ভুলব
        আরও কিছুক্ষণ থাকো
        """)
]

var failures: [String] = []

func expect(_ expected: String?, _ text: String, _ name: String) {
    let actual = LyricsLanguageDetector.detect(text)
    if actual != expected {
        failures.append("\(name): expected \(expected ?? "nil"), got \(actual ?? "nil")")
    }
}

for sample in corpus {
    expect(sample.expected, sample.text, "corpus \(sample.expected)")
}

expect("en", """
    I remember when the summer ended
    you said my name like it was ours
    and I keep it in my pocket now
    oh oh oh, I keep it now
    যখন রাত নেমে আসে
    """, "ordinary Bengali hook")

expect("en", """
    I remember when the summer ended
    you said my name like it was ours
    and I keep it in my pocket now
    I keep it, I keep it now
    사랑해
    and I keep it now
    """, "short Korean hook")

expect("ko", """
    너의 이름을 부르면
    I remember when the summer ended
    내 마음이 자꾸 흔들려
    you said my name like it was ours
    밤이 오면 더 선명해져
    and I keep it in my pocket now
    그대로 있어줘
    oh oh oh, I keep it now
    """, "K-pop code switching")

var longLyrics = Array(
    repeating: "I remember you and my heart in the night",
    count: 22
).joined(separator: "\n")
longLyrics += "\n사랑해\n너를 기다려"
expect("en", longLyrics, "two foreign lines in a long lyric")

expect("fr", """
    quand la nuit tombe enfin
    je te cherche dans les rues vides
    je ne sais pas t'oublier
    reste encore un peu
    wenn die Nacht endlich fällt
    """, "French majority")

expect("zh-TW", "聽見你的聲音", "exclusive Traditional Chinese evidence")
expect("ko", "사랑해", "short Korean")
expect("ja", "愛してる", "short Japanese")
expect("es", "te quiero", "short Spanish")
expect("en", "oh oh oh\nyeah", "short English")
expect(nil, "", "empty")
expect(nil, "   ", "whitespace")
expect(nil, "♪ ♪ ♪", "symbols")

expect("en", """
    kimi no namae wo yondara
    kokoro ga yurete shimau yo
    yoru ga kureba motto senmei ni
    """, "romanized lyrics")

let spanish = """
    cuando llega la noche
    te busco en la ciudad vacía
    no sé cómo olvidarte
    quédate un poco más
    """
let nfc = spanish.precomposedStringWithCanonicalMapping
let nfd = spanish.decomposedStringWithCanonicalMapping
if LyricsLanguageDetector.detect(nfc) != LyricsLanguageDetector.detect(nfd) {
    failures.append("normalization changed the verdict")
}

guard failures.isEmpty else {
    fatalError("Language detection regressions:\n\(failures.joined(separator: "\n"))")
}

print("Language detection tests passed (\(corpus.count) languages plus mixed-input regressions).")

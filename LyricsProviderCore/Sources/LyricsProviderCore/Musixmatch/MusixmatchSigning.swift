import CryptoKit
import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public enum MusixmatchSigning {
    private static let secret = Data("mNdca@6W7TeEcFn6*3.s97sJ*yPMd".utf8)

    public static func sign(urlString: String, date: Date) -> [URLQueryItem] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"

        var message = Data(urlString.utf8)
        message.append(Data(formatter.string(from: date).utf8))
        let key = SymmetricKey(data: secret)
        let digest = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key)
        let signature = Data(digest).base64EncodedString() + "\n"
        return [
            URLQueryItem(name: "signature", value: signature),
            URLQueryItem(name: "signature_protocol", value: "sha1"),
        ]
    }
}

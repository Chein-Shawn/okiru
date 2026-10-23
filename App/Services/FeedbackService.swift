import Foundation
import UIKit

struct ServiceConfiguration: Decodable {
    var feedbackEndpoint: String
    var appStoreID: String
    var privacyURL: String
    var supportURL: String
    static var current: ServiceConfiguration {
        guard let url = Bundle.main.url(forResource:"Services",withExtension:"json"),
              let data = try? Data(contentsOf:url), let config = try? JSONDecoder().decode(Self.self,from:data) else {
            return .init(feedbackEndpoint:"",appStoreID:"",privacyURL:"",supportURL:"")
        }
        return config
    }
}

struct FeedbackPayload: Codable {
    var submissionID: String
    var source = "okiru-ios"
    var appName = "Okiru"
    var category: String
    var summary: String
    var details: String
    var replyEmail: String?
    var appVersion: String
    var buildNumber: String
    var osVersion: String
    var displayLanguage: String
    var submittedAt: String
}

actor FeedbackService {
    static let shared = FeedbackService()
    func submit(id: String, category: String, summary: String, details: String, email: String) async throws {
        guard let url = URL(string:ServiceConfiguration.current.feedbackEndpoint),url.scheme == "https" else { throw DisplayError(key:"feedback.unconfigured") }
        let trimmedSummary = summary.trimmingCharacters(in:.whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty, !trimmedDetails.isEmpty, trimmedSummary.unicodeScalars.count <= 160, trimmedDetails.unicodeScalars.count <= 4000 else { throw DisplayError(key:"feedback.invalid") }
        let now = Date()
        guard now.timeIntervalSince1970 - UserDefaults.standard.double(forKey:"feedback.lastSent") >= 20 else { throw DisplayError(key:"feedback.cooldown") }
        UserDefaults.standard.set(now.timeIntervalSince1970,forKey:"feedback.lastSent")
        let payload = FeedbackPayload(submissionID:id,category:category,summary:trimmedSummary,details:trimmedDetails,replyEmail:email.isEmpty ? nil : email,
                                      appVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.0.0",
                                      buildNumber:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "1",osVersion:ProcessInfo.processInfo.operatingSystemVersionString,
                                      displayLanguage:AppLanguage.effective,submittedAt:ISO8601DateFormatter().string(from:now))
        var request = URLRequest(url:url); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data,response) = try await URLSession.shared.data(for:request)
        struct Reply: Decodable { var ok: Bool?; var submissionID: String? }
        guard let http = response as? HTTPURLResponse,(200..<300).contains(http.statusCode),
              let reply = try? JSONDecoder().decode(Reply.self,from:data),reply.ok == true,reply.submissionID == id else {
            throw DisplayError(key:"feedback.failed")
        }
        UserDefaults.standard.set(now.timeIntervalSince1970,forKey:"feedback.lastSent")
    }
}

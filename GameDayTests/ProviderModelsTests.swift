import XCTest
@testable import GameDay

final class ProviderModelsTests: XCTestCase {
    private func event(id: String = "event", state: String) -> SportsEvent {
        SportsEvent(
            id: id, title: "Test Game", sport: .nfl, league: "NFL", start: Date(),
            status: state == "post" ? "Final" : "Live", state: state,
            teams: [], broadcasts: [], score: nil
        )
    }

    func testGameFirstReceivedAsFinalIsHiddenWithoutGuessingEndTime() {
        let final = event(state: "post")
        let observations = FinishedGameFilter.updateObservations(
            previous: [], refreshed: [final], existing: [:], now: Date()
        )
        XCTAssertTrue(FinishedGameFilter.visible(
            [final], observations: observations, retention: .threeHours, now: Date()
        ).isEmpty)
    }

    func testObservedLiveToFinalTransitionExpiresAfterPreference() {
        let now = Date()
        let live = event(state: "in")
        let final = event(state: "post")
        let observations = FinishedGameFilter.updateObservations(
            previous: [live], refreshed: [final], existing: [:], now: now
        )
        XCTAssertEqual(FinishedGameFilter.visible(
            [final], observations: observations, retention: .threeHours,
            now: now.addingTimeInterval(2.5 * 3600)
        ), [final])
        XCTAssertTrue(FinishedGameFilter.visible(
            [final], observations: observations, retention: .threeHours,
            now: now.addingTimeInterval(3 * 3600)
        ).isEmpty)
    }

    func testImmediatePreferenceHidesObservedFinal() {
        let final = event(state: "post")
        XCTAssertTrue(FinishedGameFilter.visible(
            [final], observations: [final.id: Date()], retention: .immediately, now: Date()
        ).isEmpty)
    }

    func testScheduleDateAllowsMinutePrecision() {
        XCTAssertNotNil(SportsScheduleClient.parseDate("2026-09-20T17:00Z"))
    }

    func testCredentialsAcceptHTTP() {
        XCTAssertNoThrow(try ProviderCredentials(host: "http://example.com", username: "user", password: "pass"))
    }

    func testCredentialsRejectUnsupportedSchemes() {
        XCTAssertThrowsError(try ProviderCredentials(host: "ftp://example.com", username: "user", password: "pass"))
    }

    func testAPIURLContainsAction() throws {
        let credentials = try ProviderCredentials(host: "https://provider.example/", username: "user", password: "pass")
        let url = try credentials.apiURL(action: "get_live_streams")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/player_api.php")
        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "action", value: "get_live_streams")) == true)
    }

    func testChannelAcceptsNumericStrings() throws {
        let data = Data(#"{"stream_id":"42","name":"Test Channel","category_id":7,"stream_type":"live"}"#.utf8)
        let channel = try JSONDecoder().decode(LiveChannel.self, from: data)
        XCTAssertEqual(channel.streamID, 42)
        XCTAssertEqual(channel.categoryID, "7")
    }

    func testCategoryAcceptsNumericID() throws {
        let data = Data(#"{"category_id":7,"category_name":"Sports"}"#.utf8)
        let category = try JSONDecoder().decode(LiveCategory.self, from: data)
        XCTAssertEqual(category.id, "7")
        XCTAssertEqual(category.name, "Sports")
    }

    func testGameFeedRequiresBothTeamsForHighConfidence() throws {
        let data = Data(#"{"stream_id":42,"name":"Baltimore Ravens vs Cincinnati Bengals","category_id":"7"}"#.utf8)
        let channel = try JSONDecoder().decode(LiveChannel.self, from: data)
        let event = SportsEvent(
            id: "event", title: "Baltimore Ravens vs Cincinnati Bengals", sport: .nfl, league: "NFL",
            start: Date(), status: "Scheduled", state: "pre",
            teams: [
                SportsTeam(name: "Baltimore Ravens", shortName: "Ravens", abbreviation: "BAL"),
                SportsTeam(name: "Cincinnati Bengals", shortName: "Bengals", abbreviation: "CIN")
            ], broadcasts: [], score: nil
        )
        let feeds = SportsMatcher.feeds(for: event, channels: [channel], categoryNames: ["7": "US NFL"])
        XCTAssertEqual(feeds.first?.confidence, 90)
    }

    func testSmartSelectionRetainsSharedSportsCarrier() throws {
        let data = Data(#"{"stream_id":9,"name":"US ESPN","category_id":"1"}"#.utf8)
        let channel = try JSONDecoder().decode(LiveChannel.self, from: data)
        let config = SmartSelectionConfig(countries: ["US"], sports: [.nfl], keepUnlabeled: true)
        let decision = SportsClassifier.classify(channel: channel, categoryName: "US Sports", config: config)
        XCTAssertTrue(decision.0)
    }

    func testBaseballIsLabeledMLB() {
        XCTAssertEqual(SportsClassifier.sports(in: "MLB · Milwaukee Brewers at Pittsburgh Pirates"), [.mlb])
    }

    func testM3UParserDiscoversGuideAndStreamMetadata() throws {
        let text = """
        #EXTM3U url-tvg="https://example.com/guide.xml.gz"
        #EXTINF:-1 tvg-id="espn.us" tvg-name="ESPN" tvg-logo="https://example.com/espn.png" group-title="Sports",ESPN
        DNS/live/USERNAME/PASSWORD/12345.ts
        """
        let parsed = try M3UPlaylistParser.parse(Data(text.utf8))
        XCTAssertEqual(parsed.epgURL?.absoluteString, "https://example.com/guide.xml.gz")
        XCTAssertEqual(parsed.channels.first?.streamID, 12345)
        XCTAssertEqual(parsed.channels.first?.tvgID, "espn.us")
        XCTAssertEqual(parsed.channels.first?.groupTitle, "Sports")
    }

    func testM3UParserSkipsEPGeniusTutorialStream() throws {
        let text = """
        #EXTM3U url-tvg="https://example.com/guide.xml.gz"
        #EXTINF:0 tvg-name="EPGenius" tvg-id="EPGenius" group-title="EPGenius",Tutorial
        https://epgenius.org/static/1.ts
        #EXTINF:0 tvg-name="ESPN" tvg-id="espn.us" group-title="Sports",ESPN
        DNS/live/USERNAME/PASSWORD/309865.ts
        """
        let parsed = try M3UPlaylistParser.parse(Data(text.utf8))
        XCTAssertEqual(parsed.channels.map(\.streamID), [309865])
    }

    func testXMLTVParserReadsCurrentProgramme() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let start = formatter.string(from: Date().addingTimeInterval(-3600))
        let stop = formatter.string(from: Date().addingTimeInterval(3600))
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="\(start)" stop="\(stop)" channel="espn.us">
            <title>NFL Live</title><desc>News and analysis.</desc>
          </programme>
        </tv>
        """
        let programmes = try XMLTVParser.parse(Data(text.utf8), channelIDs: ["espn.us"])
        XCTAssertEqual(programmes.count, 1)
        XCTAssertEqual(programmes.first?.title, "NFL Live")
    }

    func testGzipDecoderOpensCompressedXMLTV() throws {
        let encoded = "H4sIADF0rWoAA7Oxr8jNUShLLSrOzM+zVTLUM1Cyt7MpKbOzKSjKTy9KzM1NVSguSSwqsVUyMjAyM7A0tDA0MgACBW0QqQSUzC9AkjNBlkvOSMzLS82xVUotLsjTKy1WApqcWZKTaufn5qPgk1mWaqMP4dvow20DsoG2AwDsqYJklwAAAA=="
        let compressed = try XCTUnwrap(Data(base64Encoded: encoded))
        let decompressed = try GzipDecoder.decompressIfNeeded(compressed)
        let xml = try XCTUnwrap(String(data: decompressed, encoding: .utf8))
        XCTAssertTrue(xml.contains("<title>NFL Live</title>"))
    }

    func testGuideTextCanConfirmEventFeed() throws {
        let channel = LiveChannel(streamID: 42, name: "Sunday Ticket 1", categoryID: "7")
        let event = SportsEvent(
            id: "event", title: "Baltimore Ravens vs Cincinnati Bengals", sport: .nfl, league: "NFL",
            start: Date(), status: "Scheduled", state: "pre",
            teams: [
                SportsTeam(name: "Baltimore Ravens", shortName: "Ravens", abbreviation: "BAL"),
                SportsTeam(name: "Cincinnati Bengals", shortName: "Bengals", abbreviation: "CIN")
            ], broadcasts: [], score: nil
        )
        let feeds = SportsMatcher.feeds(
            for: event, channels: [channel], categoryNames: ["7": "NFL"],
            supplementalText: [42: "Baltimore Ravens at Cincinnati Bengals"]
        )
        XCTAssertEqual(feeds.first?.confidence, 98)
        XCTAssertEqual(feeds.first?.reason, "TV guide matches both teams")
    }
}

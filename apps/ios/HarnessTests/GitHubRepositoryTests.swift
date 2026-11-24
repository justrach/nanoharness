import XCTest
@testable import Harness

@MainActor
final class GitHubRepositoryTests: XCTestCase {
    private func sampleIssues() -> [GitHubRepositoryItem] {
        let rows: [(UInt64, String, String, String, String, String)] = [
            (156, "Starred named operators and gathered equations fall back", "open", "lin", "2026-11-24T12:00:00Z", "math"),
            (155, "A dollar price steals the opener of a later equation", "open", "lin", "2026-11-24T09:00:00Z", "math"),
            (154, "Display math inside a list item loses its paragraph", "open", "kai", "2026-11-23T18:00:00Z", "math"),
            (153, "Opening a link stays inside its own pane", "closed", "maya", "2026-11-22T14:00:00Z", "splits"),
            (152, "Keyboard shortcut hint clips in split headers", "open", "maya", "2026-11-23T11:00:00Z", "splits"),
            (151, "Composer mentions menu loses selection on reload", "closed", "lin", "2026-11-21T16:00:00Z", "composer"),
            (150, "Voice button tooltip stays stuck after opening sheet", "open", "noah", "2026-11-23T08:00:00Z", "splits"),
            (149, "Draft persistence drops trailing attachment chip", "closed", "lin", "2026-11-21T12:00:00Z", "composer"),
            (148, "Aligned environments fail to parse nested fractions", "closed", "kai", "2026-11-20T15:00:00Z", "math"),
            (147, "Equation baseline shifts inside blockquotes", "closed", "lin", "2026-11-20T10:00:00Z", "math"),
            (146, "Appearance sheet forgets warm accent on relaunch", "closed", "noah", "2026-11-19T17:00:00Z", "settings"),
            (145, "Queued message edit clears draft attachment preview", "closed", "maya", "2026-11-22T09:00:00Z", "composer"),
        ]
        return rows.map {
            GitHubRepositoryItem(
                number: $0.0,
                title: $0.1,
                url: "https://github.com/demo/fieldnotes/issues/\($0.0)",
                state: $0.2,
                isDraft: false,
                author: $0.3,
                updatedAt: $0.4,
                createdAt: $0.4,
                labels: [$0.5]
            )
        }
    }

    func testDecodesFullAndLegacyResponses() throws {
        let fullJSON = """
        {
          "repository": {
            "key": "github.com/demo/fieldnotes",
            "host": "github.com",
            "owner": "demo",
            "name": "fieldnotes",
            "url": "https://github.com/demo/fieldnotes"
          },
          "kind": "pulls",
          "items": [
            {
              "number": 90,
              "title": "Stream pull request status on every client",
              "url": "https://github.com/demo/fieldnotes/pull/90",
              "state": "open",
              "isDraft": false,
              "author": "lin",
              "updatedAt": "2026-11-24T10:00:00Z",
              "createdAt": "2026-11-20T09:00:00Z",
              "labels": ["sync", "ui"]
            },
            {
              "number": 84,
              "title": "Legacy host item without labels",
              "url": "https://github.com/demo/fieldnotes/pull/84",
              "state": "merged",
              "isDraft": false,
              "author": "kai",
              "updatedAt": "2026-11-22T15:00:00Z"
            }
          ],
          "page": 1,
          "hasNextPage": false,
          "truncated": false
        }
        """
        let decoded = try JSONDecoder().decode(BrowseCheckoutGitHubResponse.self, from: Data(fullJSON.utf8))
        XCTAssertEqual(decoded.repository.fullName, "demo/fieldnotes")
        XCTAssertEqual(decoded.kind, .pulls)
        XCTAssertEqual(decoded.items.count, 2)
        XCTAssertEqual(decoded.items[0].labels, ["sync", "ui"])
        XCTAssertEqual(decoded.items[0].createdAt, "2026-11-20T09:00:00Z")
        XCTAssertEqual(decoded.items[1].labels, [])
        XCTAssertEqual(decoded.items[1].createdAt, "")
    }

    func testComputesOverviewStatsAndGroupsByLabelOrContributor() {
        let stats = GitHubOverviewStats.compute(items: sampleIssues())
        XCTAssertEqual(stats.total, 12)
        XCTAssertEqual(stats.open, 5)
        XCTAssertEqual(stats.closed, 7)
        XCTAssertEqual(stats.resolvedPercent, 58)
        XCTAssertEqual(stats.openPercent, 41)
        XCTAssertEqual(stats.latestNumber, 156)
        XCTAssertEqual(stats.contributorCount, 4)
        XCTAssertEqual(stats.topAuthor, "lin")
        XCTAssertEqual(stats.topAuthorCount, 5)
        XCTAssertTrue(stats.isLabelGrouping)
        XCTAssertEqual(stats.groups.first?.name, "math")
        XCTAssertEqual(stats.groups.first?.total, 5)
        XCTAssertEqual(stats.groups.first?.resolved, 2)
        XCTAssertEqual(stats.days.count, 6)
        XCTAssertEqual(stats.days.first?.date, "2026-11-19")
        XCTAssertEqual(stats.days.last?.date, "2026-11-24")

        // Without labels, grouping falls back to contributors.
        let unlabeled = sampleIssues().map {
            GitHubRepositoryItem(
                number: $0.number, title: $0.title, url: $0.url,
                state: $0.state, isDraft: $0.isDraft, author: $0.author,
                updatedAt: $0.updatedAt, createdAt: $0.createdAt, labels: []
            )
        }
        let byAuthor = GitHubOverviewStats.compute(items: unlabeled)
        XCTAssertFalse(byAuthor.isLabelGrouping)
        XCTAssertEqual(byAuthor.groups.first?.name, "lin")
        XCTAssertEqual(byAuthor.groups.first?.total, 5)
    }

    func testClientFiltersToggleAndComposeWithoutStateLoss() {
        let issues = sampleIssues()
        var filter = GitHubClientFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(issues.filter { filter.matches($0) }.count, 12)

        filter.toggleLabel("math")
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(issues.filter { filter.matches($0) }.count, 5)

        filter.toggleState(.open)
        XCTAssertEqual(issues.filter { filter.matches($0) }.count, 3)
        XCTAssertEqual(filter.summary(shown: 3, total: 12), "Showing 3 of 12 (state: open · math)")

        filter.toggleAuthor("maya")
        XCTAssertNil(filter.label)
        XCTAssertEqual(issues.filter { filter.matches($0) }.count, 1)

        filter.clear()
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(issues.filter { filter.matches($0) }.count, 12)
    }

    func testDemoDatasetServesGitHubListDetailFilesAndActivity() {
        let demo = DemoDataset.standard()
        let issuesAll = demo.browseGitHub(kind: .issues, state: .all, number: nil, page: 1)
        XCTAssertEqual(issuesAll.repository.fullName, "demo/fieldnotes")
        XCTAssertEqual(issuesAll.items.count, 12)

        let prDetail = demo.browseGitHub(kind: .pull, state: nil, number: 90, page: nil)
        XCTAssertEqual(prDetail.detail?.number, 90)
        XCTAssertEqual(prDetail.detail?.state, "open")

        let prFiles = demo.browseGitHub(kind: .files, state: nil, number: 90, page: nil)
        XCTAssertFalse(prFiles.files.isEmpty)

        let prActivity = demo.browseGitHub(kind: .activity, state: nil, number: 90, page: nil)
        XCTAssertFalse(prActivity.events.isEmpty)
    }
}

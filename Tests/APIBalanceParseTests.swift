import XCTest
@testable import Codenotch

final class APIBalanceParseTests: XCTestCase {
    func testVercelReadsStringDollars() throws {
        let data = Data(#"{"balance":"10.362772618","total_used":"4.80756353"}"#.utf8)
        XCTAssertEqual(try APIBalanceParse.vercelBalance(data), 10.362772618, accuracy: 0.000001)
    }

    func testXAINegatesTheCentsTotal() throws {
        let data = Data(#"{"changes":[{"changeOrigin":"PURCHASE","amount":{"val":"-1000"}}],"total":{"val":"-1000"}}"#.utf8)
        XCTAssertEqual(try APIBalanceParse.xaiBalance(data), 10, "a $10 purchase is -1000 cents")
    }

    func testAnthropicSumsCentsAndFollowsPages() throws {
        let data = Data(#"""
        {"data":[{"starting_at":"2026-10-01T00:00:00Z","ending_at":"2026-10-02T00:00:00Z",
                  "results":[{"amount":"123.45","currency":"USD"},{"amount":"76.55","currency":"USD"}]},
                 {"starting_at":"2026-10-02T00:00:00Z","ending_at":"2026-10-03T00:00:00Z","results":[]}],
         "has_more":true,"next_page":"page_abc"}
        """#.utf8)
        let page = try APIBalanceParse.anthropicCostPage(data)
        XCTAssertEqual(page.dollars, 2, accuracy: 0.0001)
        XCTAssertEqual(page.nextPage, "page_abc")
    }

    func testOpenAIReadsResultAndResults() throws {
        for key in ["result", "results"] {
            let data = Data(#"""
            {"object":"page","data":[{"object":"bucket","start_time":1,"end_time":2,
              "\#(key)":[{"object":"organization.costs.result","amount":{"value":0.06,"currency":"usd"}},
                         {"object":"organization.costs.result","amount":{"value":1.94,"currency":"usd"}}]}],
             "has_more":false,"next_page":null}
            """#.utf8)
            let page = try APIBalanceParse.openAICostPage(data)
            XCTAssertEqual(page.dollars, 2, accuracy: 0.0001)
            XCTAssertNil(page.nextPage)
        }
    }

    func testGarbageIsABadResponse() {
        XCTAssertThrowsError(try APIBalanceParse.vercelBalance(Data("nope".utf8)))
        XCTAssertThrowsError(try APIBalanceParse.xaiBalance(Data("{}".utf8)))
    }
}

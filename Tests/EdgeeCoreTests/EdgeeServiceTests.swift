import Foundation
import XCTest
@testable import EdgeeCore

final class EdgeeServiceTests: XCTestCase {
    func testIdentityParsesCLIStatus() throws {
        let data = Data(#"{"logged_in":true,"profile":"default","email":"person@example.com","org_slug":"acme","providers":{}}"#.utf8)

        let identity = try EdgeeService.parseIdentity(data)

        XCTAssertEqual(identity.name, "person@example.com")
        XCTAssertEqual(identity.organization, "acme")
        XCTAssertEqual(identity.profile, "default")
    }

    func testIdentityRejectsLoggedOutStatus() {
        let data = Data(#"{"logged_in":false,"profile":"default","providers":{}}"#.utf8)

        XCTAssertThrowsError(try EdgeeService.parseIdentity(data)) { error in
            XCTAssertEqual(error as? EdgeeServiceError, .authenticationRequired)
        }
    }

    func testUsageMapsMemberDashboardResponseAndNanoUSD() throws {
        let data = Data(#"""
        {
          "summary": {
            "total_requests": 42,
            "total_cost": 1234500000,
            "total_tokens": 1060,
            "input_tokens": 100,
            "input_cost": 100000000,
            "cache_creation_input_tokens": 200,
            "cache_creation_input_cost": 200000000,
            "cached_input_tokens": 600,
            "cached_input_cost": 300000000,
            "output_tokens": 150,
            "output_cost": 634500000,
            "reasoning_output_tokens": 10,
            "tool_compression_cost_savings": 100000000,
            "output_cost_savings": 20000000,
            "mcp_surface_cost_savings": 0
          },
          "stats_by_model": [{
            "model": "openai/gpt-5.6-luna",
            "total_tokens": 1060,
            "total_cost": 1234500000,
            "total_requests": 42
          }],
          "stats_by_time": {
            "granularity": "hour",
            "data": [{
              "timestamp": "2026-01-01 12:00:00",
              "total_cost": 500000000,
              "total_tokens": 500
            }]
          }
        }
        """#.utf8)

        let usage = try EdgeeService.parseUsage(data, period: .day)

        XCTAssertEqual(usage.scope, "Your usage")
        XCTAssertEqual(usage.totalCost, 1.2345, accuracy: 0.000000001)
        XCTAssertEqual(usage.savedCost ?? -1, 0.12, accuracy: 0.000000001)
        XCTAssertEqual(usage.totalTokens, 1_060)
        XCTAssertEqual(usage.requests, 42)
        XCTAssertEqual(usage.notice, "Reasoning tokens are included in the total.")
        XCTAssertEqual(usage.models.first?.id, "openai/gpt-5.6-luna")
        XCTAssertEqual(usage.models.first?.cost ?? -1, 1.2345, accuracy: 0.000000001)
        XCTAssertEqual(usage.series.first?.cost ?? -1, 0.5, accuracy: 0.000000001)
        XCTAssertTrue(usage.sessions.isEmpty)

        let displayedCategoryTotal = usage.tokens.reduce(0) { $0 + $1.count }
        XCTAssertEqual(usage.totalTokens - displayedCategoryTotal, 10)
        XCTAssertEqual(usage.tokens.first(where: { $0.kind == .cacheWrite })?.count, 200)
        XCTAssertEqual(usage.tokens.first(where: { $0.kind == .cacheRead })?.cost ?? -1, 0.3, accuracy: 0.000000001)
    }

    func testUsageRequiresSummaryTotals() {
        let responses = [
            #"{"summary":{"total_cost":1,"total_tokens":2}}"#,
            #"{"summary":{"total_requests":1,"total_tokens":2}}"#,
            #"{"summary":{"total_requests":1,"total_cost":2}}"#,
            #"{"summary":{}}"#
        ]

        for response in responses {
            XCTAssertThrowsError(try EdgeeService.parseUsage(Data(response.utf8), period: .day)) { error in
                XCTAssertEqual(error as? EdgeeServiceError, .invalidResponse("usage"))
            }
        }
    }

    func testUsageLeavesMissingTokenCategoriesUnavailable() throws {
        let data = Data(#"""
        {
          "summary": {
            "total_requests": 1,
            "total_cost": 250000000,
            "total_tokens": 42,
            "future_total": 99
          },
          "future_section": {"ignored": true}
        }
        """#.utf8)

        let usage = try EdgeeService.parseUsage(data, period: .day)

        XCTAssertEqual(usage.totalCost, 0.25, accuracy: 0.000000001)
        XCTAssertEqual(usage.totalTokens, 42)
        XCTAssertEqual(usage.requests, 1)
        XCTAssertTrue(usage.tokens.isEmpty)
        XCTAssertNil(usage.notice)
    }

    func testSessionsRequireConfiguredKeyWindowAndCompleteCounters() throws {
        let data = Data(#"""
        {
          "data": [
            {
              "session_id": "personal-current",
              "key_uuid": "key-allowed",
              "last_request": "2026-09-14T17:56:32Z",
              "total_cost": 345699552,
              "total_input_tokens": 10,
              "total_cache_creation_input_tokens": 20,
              "total_cached_input_tokens": 30,
              "total_output_tokens": 40,
              "total_reasoning_output_tokens": 50,
              "future_counter": 999
            },
            {
              "session_id": "organization-member",
              "key_uuid": "key-not-configured",
              "last_request": "2026-09-14T17:56:32Z",
              "total_cost": 9000000000,
              "total_input_tokens": 1,
              "total_cache_creation_input_tokens": 1,
              "total_cached_input_tokens": 1,
              "total_output_tokens": 1,
              "total_reasoning_output_tokens": 1
            },
            {
              "session_id": "missing-category",
              "key_uuid": "key-allowed",
              "last_request": "2026-09-14T17:56:32Z",
              "total_cost": 1,
              "total_input_tokens": 1,
              "total_cache_creation_input_tokens": 1,
              "total_cached_input_tokens": 1,
              "total_output_tokens": 1
            },
            {
              "session_id": "outside-window",
              "key_uuid": "key-allowed",
              "last_request": "2026-09-12T17:56:32Z",
              "total_cost": 1,
              "total_input_tokens": 1,
              "total_cache_creation_input_tokens": 1,
              "total_cached_input_tokens": 1,
              "total_output_tokens": 1,
              "total_reasoning_output_tokens": 1
            }
          ],
          "has_more": false,
          "page": 1,
          "page_size": 100,
          "total_count": 4
        }
        """#.utf8)
        let formatter = ISO8601DateFormatter()
        let since = try XCTUnwrap(formatter.date(from: "2026-09-13T18:00:00Z"))
        let through = try XCTUnwrap(formatter.date(from: "2026-09-14T18:00:00Z"))

        let sessions = try EdgeeService.parseSessions(
            data,
            agentNamesByKeyID: ["key-allowed": "Claude Code"],
            since: since,
            through: through
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, "personal-current")
        XCTAssertEqual(sessions[0].name, "Claude Code session")
        XCTAssertEqual(sessions[0].cost, 0.345699552, accuracy: 0.000000001)
        XCTAssertEqual(sessions[0].tokens, 150)
        XCTAssertEqual(sessions[0].updatedAt, formatter.date(from: "2026-09-14T17:56:32Z"))
    }

    func testAgentSettingsMapWithoutCreatingAKey() throws {
        let data = Data(#"""
        {
          "compression": {
            "tool_result_trimming": true,
            "tool_surface_reduction": false,
            "output_brevity": true
          },
          "fallbacks": [{"model":"anthropic/claude-sonnet"}],
          "reroutes": [{"model":"openai/gpt-5.6-luna","future_field":"preserved-by-write-path"}],
          "byok_only": false
        }
        """#.utf8)

        let agent = try EdgeeService.parseAgentConfiguration(
            data,
            agentID: "claude",
            name: "Claude Code",
            connection: "plan"
        )

        XCTAssertTrue(agent.toolCompression)
        XCTAssertFalse(agent.toolSurfaceReduction)
        XCTAssertTrue(agent.outputBrevity)
        XCTAssertEqual(agent.routedModel, "openai/gpt-5.6-luna")
        XCTAssertEqual(agent.detail, "Plan connection · Fallback: anthropic/claude-sonnet")
        XCTAssertTrue(agent.canEdit)
    }

    func testModelCatalogFiltersInactiveAppOnlyAndBYOKUnavailableModels() throws {
        let data = Data(#"""
        [
          {"model_id":"gpt-5.6-luna","author_id":"openai","display_name":"GPT 5.6 Luna","aliases":["gpt-5.6-luna"],"providers":{"openai":{}},"active":true},
          {"model_id":"claude-sonnet","author_id":"anthropic","display_name":"Claude Sonnet","providers":{"anthropic":{}},"active":true},
          {"model_id":"composer","author_id":"cursor","display_name":"Composer","providers":{"cursor":{}},"active":true},
          {"model_id":"old","author_id":"openai","display_name":"Old","providers":{"openai":{}},"active":false}
        ]
        """#.utf8)

        let unrestricted = try EdgeeService.parseAvailableModels(data)
        XCTAssertEqual(Set(unrestricted.map(\.id)), Set(["gpt-5.6-luna", "anthropic/claude-sonnet"]))

        let byok = try EdgeeService.parseAvailableModels(
            data,
            allowedProviders: ["anthropic"],
            byokOnly: true
        )
        XCTAssertEqual(byok.map(\.id), ["anthropic/claude-sonnet"])
    }

    func testRouteModelsUseCLIAgentFilteredIdentifiers() throws {
        let data = Data(#"""
        [
          {
            "name": "gpt-5.6-luna",
            "catalog_id": "openai/gpt-5.6-luna",
            "display_name": "GPT-5.6 Luna",
            "aliases": ["gpt-5.6-luna"],
            "future_capability": true
          },
          {
            "name": "claude-sonnet-5",
            "catalog_id": "anthropic/claude-sonnet-5",
            "display_name": "Claude Sonnet 5",
            "aliases": ["claude-sonnet-5"]
          }
        ]
        """#.utf8)

        let models = try EdgeeService.parseRouteModels(data)

        XCTAssertEqual(models.map(\.id), ["gpt-5.6-luna", "claude-sonnet-5"])
        XCTAssertEqual(models.map(\.provider), ["openai", "anthropic"])
        XCTAssertEqual(models.first?.name, "GPT-5.6 Luna")
    }
}

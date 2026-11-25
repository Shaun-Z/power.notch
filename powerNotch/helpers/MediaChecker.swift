//
//  MediaChecker.swift
//  powerNotch
//
//  Created by Alexander on 2025-07-26.
//

import Foundation

final class MediaChecker: Sendable {

    enum MediaCheckerError: Error {
        case missingResources
        case processExecutionFailed
        case timeout
    }

    func checkDeprecationStatus() async throws -> Bool {
        guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let client = Bundle.main.url(forResource: "MediaRemoteAdapterTestClient", withExtension: nil)?.path,
              let framework = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else { throw MediaCheckerError.missingResources }
        do {
            let status = try await SubprocessTimeoutRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [scriptURL.path, framework, client, "test"], timeout: .seconds(10))
            return status == 1
        } catch SubprocessTimeoutError.timedOut {
            throw MediaCheckerError.timeout
        } catch SubprocessTimeoutError.executionFailed {
            throw MediaCheckerError.processExecutionFailed
        }
    }
}

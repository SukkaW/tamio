//
//  LogRedirect.swift
//  TamioMobile
//
//  Created by Lakr Aream on 2022/3/14.
//

import SwiftUI

/// Written from whichever thread logs; the handle serialises the writes.
final class LogRedirect: @unchecked Sendable {
    static let shared = LogRedirect()

    var handler: FileHandle?
    var path: URL?

    private init() {
        if let url = FileManager
            .default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("sb.moe.tamio.diag.log")
        {
            path = url
            // Keep the last run's log as .prev.log instead of wiping it: the
            // diagnostics of a session that crashed survive the relaunch.
            let prev = url.deletingLastPathComponent()
                .appendingPathComponent("sb.moe.tamio.diag.prev.log")
            try? FileManager.default.removeItem(at: prev)
            try? FileManager.default.moveItem(at: url, to: prev)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
            handler = try? FileHandle(forWritingTo: url)
            checkPipe()
        }
    }

    func checkPipe() {
        guard let handler = handler, let path = path?.path else {
            return
        }
        #if DEBUG
            guard UserDefaults.standard.value(forKey: "sb.moe.tamio.redirect.diag") as? Bool ?? false else {
                return
            }
        #endif
        debugPrint("calling dup2 on stdout and stderr with \(path)")
        dup2(handler.fileDescriptor, STDOUT_FILENO)
        dup2(handler.fileDescriptor, STDERR_FILENO)
    }
}

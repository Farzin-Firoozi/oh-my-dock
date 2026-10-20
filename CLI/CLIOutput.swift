import Foundation
import OhMyDockCore

enum CLIOutput {
    static func emit(_ result: ExternalResult, options: GlobalOptions, command: String) -> Int32 {
        let exitCode = Int32(result.exitCode)
        if options.json {
            emitJSON(result, options: options)
            return exitCode
        }
        if result.ok {
            emitHumanSuccess(result, options: options, command: command)
        } else {
            emitHumanFailure(result.message, options: options)
        }
        return exitCode
    }

    static func emitUsage(_ message: String, options: GlobalOptions) -> Int32 {
        if options.json {
            let envelope = ExternalEnvelope(
                command: "usage",
                ok: false,
                error: ExternalErrorInfo(code: "usage", exitCode: 2, message: message)
            )
            emitEnvelopeJSON(envelope, options: options, stderrMessage: message)
        } else {
            emitHumanFailure(message, options: options)
        }
        return 2
    }

    private static func emitJSON(_ result: ExternalResult, options: GlobalOptions) {
        emitEnvelopeJSON(result.envelope, options: options, stderrMessage: result.ok ? nil : result.message)
    }

    private static func emitEnvelopeJSON(
        _ envelope: ExternalEnvelope,
        options: GlobalOptions,
        stderrMessage: String?
    ) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(envelope)
            if data.last != UInt8(ascii: "\n") {
                data.append(UInt8(ascii: "\n"))
            }
            FileHandle.standardOutput.write(data)
        } catch {
            let text = "Failed to encode JSON: \(error)\n"
            FileHandle.standardError.write(Data(text.utf8))
        }
        if let stderrMessage, !options.quiet {
            FileHandle.standardError.write(Data((stderrMessage + "\n").utf8))
        }
    }

    private static func emitHumanFailure(_ message: String, options: GlobalOptions) {
        let text = options.usesColor ? "\u{001B}[31m\(message)\u{001B}[0m\n" : message + "\n"
        FileHandle.standardError.write(Data(text.utf8))
    }

    private static func emitHumanSuccess(_ result: ExternalResult, options: GlobalOptions, command: String) {
        guard let payload = result.envelope.result else {
            if !options.quiet {
                writeStdout(result.message + "\n", options: options)
            }
            return
        }

        switch command {
        case "list":
            if options.quiet {
                for entry in payload.profiles ?? [] {
                    writeStdout(entry.name + "\n", options: options)
                }
            } else {
                for entry in payload.profiles ?? [] {
                    let prefs = entry.hasPrefs ? "prefs" : "no-prefs"
                    writeStdout(
                        "\(entry.name)  \(entry.id)  apps:\(entry.appCount)  others:\(entry.otherCount)  \(prefs)  quit:\(entry.quitScope)\n",
                        options: options
                    )
                }
                for bad in payload.unreadable ?? [] {
                    writeStderr("unreadable: \(bad.path): \(bad.message)\n", options: options)
                }
            }
        case "show":
            if let data = payload.profileDocument, let text = String(data: data, encoding: .utf8) {
                writeStdout(text.hasSuffix("\n") ? text : text + "\n", options: options)
            } else {
                writeStdout(result.message + "\n", options: options)
            }
        case "export":
            if let document = payload.document {
                writeStdout(document.hasSuffix("\n") ? document : document + "\n", options: options)
            } else if !options.quiet {
                writeStdout(result.message + "\n", options: options)
            }
        case "completions", "version":
            if command == "version", let version = payload.version {
                writeStdout(version + "\n", options: options)
            }
        case "doctor":
            for check in payload.checks ?? [] {
                writeStdout("\(check.status.padding(toLength: 4, withPad: " ", startingAt: 0)) \(check.name): \(check.detail)\n", options: options)
            }
        case "status":
            statusLine(payload, options: options)
        case "apply":
            if payload.status == "dryRun" || !options.quiet {
                if let summary = payload.planSummary {
                    writeStdout(summary + "\n", options: options)
                }
                for app in payload.willQuit ?? [] {
                    writeStdout("would quit: \(app.name) (\(app.bundleId))\n", options: options)
                }
                for app in payload.skipped ?? [] {
                    writeStdout("skipped: \(app.name) (\(app.bundleId))\n", options: options)
                }
                if payload.confirmationRequired == true {
                    writeStderr("Confirmation required; pass --yes (and --allow-quit when apps would quit).\n", options: options)
                }
            }
        case "current":
            if let matched = payload.matchedProfile {
                writeStdout("matched: \(matched.name) (\(matched.id))\n", options: options)
            } else {
                writeStdout("no matching profile\n", options: options)
            }
            if let summary = payload.planSummary {
                writeStdout(summary + "\n", options: options)
            }
        case "save", "delete", "rename", "duplicate", "undo", "restore", "import":
            if !options.quiet {
                writeStdout(result.message + "\n", options: options)
            }
        case "snapshots":
            for snap in payload.snapshots ?? [] {
                writeStdout("\(snap.id)  \(snap.createdAt)  \(snap.reason)\n", options: options)
            }
        default:
            if !options.quiet {
                writeStdout(result.message + "\n", options: options)
            }
        }
    }

    private static func statusLine(_ payload: ExternalPayload, options: GlobalOptions) {
        writeStdout("appRunning: \(payload.appRunning == true)\n", options: options)
        writeStdout("bundleId: \(payload.bundleId ?? "io.github.farzin-firoozi.OhMyDock")\n", options: options)
        writeStdout("lock: \(payload.lock ?? "unknown")\n", options: options)
        writeStdout("preview: \(payload.preview ?? "unknown")\n", options: options)
        if let active = payload.activeProfile {
            writeStdout("activeProfile: \(active.name) (\(active.id))\n", options: options)
        } else {
            writeStdout("activeProfile: none\n", options: options)
        }
        writeStdout("dockMatchesActive: \(payload.dockMatchesActive == true)\n", options: options)
        writeStdout("externalControl: \(payload.externalControl ?? "unknown")\n", options: options)
        writeStdout("supportDir: \(payload.supportDir ?? "")\n", options: options)
        writeStdout("version: \(payload.version ?? "")\n", options: options)
    }

    private static func writeStdout(_ text: String, options: GlobalOptions) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private static func writeStderr(_ text: String, options: GlobalOptions) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

#if DEBUG
enum CLIOutputFormatting {
    static func listQuietNames(from payload: ExternalPayload) -> [String] {
        (payload.profiles ?? []).map(\.name)
    }
}
#endif

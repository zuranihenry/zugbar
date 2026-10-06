import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--settings-screenshots"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { Screenshots.renderSettings(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
} else if let index = CommandLine.arguments.firstIndex(of: "--screenshots"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        let args = CommandLine.arguments
        Screenshots.render(to: URL(fileURLWithPath: args[index + 1]), station: index + 2 < args.count ? args[index + 2] : nil)
    }
} else if let command = CLI.Command(arguments: CommandLine.arguments) {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await command.run()
        done.signal()
    }
    done.wait()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }
}

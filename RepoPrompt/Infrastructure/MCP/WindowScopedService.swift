import Foundation

/// Marker protocol for services that are tied to a specific `WindowState`.
/// The router uses `windowID` to decide whether the service should receive
/// a tool call for the currently selected window.
@preconcurrency
protocol WindowScopedService: Service {
    /// The `WindowState.windowID` this service is associated with.
    var windowID: Int { get }
}
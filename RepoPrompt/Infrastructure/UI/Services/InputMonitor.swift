//
//  InputMonitor.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-01-21.
//

import AppKit

class InputMonitor {
	// MARK: - Types
	
	private enum TrackingState {
		case idle
		case dragging
		case doubleClick
	}
	
	private struct EventData: Sendable {
		let type: NSEvent.EventType
		let locationInWindow: NSPoint
		let clickCount: Int
		
		init(from event: NSEvent) {
			self.type = event.type
			self.locationInWindow = event.locationInWindow
			self.clickCount = event.clickCount
		}
	}
	
	// MARK: - Properties
	
	private var localMouseMonitor: Any?
	private var windowObserver: NSObjectProtocol?
	private var trackingState: TrackingState = .idle
	
	// Queues and timing
	private let eventQueue = DispatchQueue(label: "com.repoprompt.inputmonitor", qos: .userInteractive)
	private let mainQueue = DispatchQueue.main
	private var lastEventTimestamp: TimeInterval = 0
	private var lastDragUpdateTime: TimeInterval = 0
	private let dragThrottleInterval: TimeInterval = 1.0 / 60.0 // 60fps max
	
	// Event deduplication
	private var lastProcessedLocation: NSPoint?
	private var lastProcessedClickCount: Int?
	
	// Event handlers
	private var onMouseDown: (NSPoint, Int) -> Void
	private var onMouseDragged: (NSPoint) -> Void
	private var onDoubleClick: () -> Void
	private var onMouseUp: () -> Void
	private var currentViewId: UUID?
	
	// MARK: - Initialization
	
	init(onMouseDown: @escaping (NSPoint, Int) -> Void,
		 onMouseDragged: @escaping (NSPoint) -> Void,
		 onDoubleClick: @escaping () -> Void,
		 onMouseUp: @escaping () -> Void) {
		self.onMouseDown = onMouseDown
		self.onMouseDragged = onMouseDragged
		self.onDoubleClick = onDoubleClick
		self.onMouseUp = onMouseUp
		
		setupWindowObserver()
	}
	
	// MARK: - Public Methods
	
	func startMonitoring() {
		stopMonitoring()
		
		localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
			guard let self = self,
				  self.currentViewId != nil else { return event }
			
			// Create Sendable event data
			let eventData = EventData(from: event)
			
			// Dispatch actual processing to dedicated queue
			self.eventQueue.async {
				self.processEvent(eventData)
			}
			
			return event
		}
	}
	
	func stopMonitoring() {
		if let monitor = localMouseMonitor {
			NSEvent.removeMonitor(monitor)
			localMouseMonitor = nil
		}
		resetState()
	}
	
	func updateHandlers(
		viewId: UUID,
		onMouseDown: @escaping (NSPoint, Int) -> Void,
		onMouseDragged: @escaping (NSPoint) -> Void,
		onDoubleClick: @escaping () -> Void,
		onMouseUp: @escaping () -> Void
	) {
		eventQueue.async { [weak self] in
			guard let self = self else { return }
			
			// Clear previous state if switching views
			if self.currentViewId != viewId {
				self.resetState()
			}
			
			self.currentViewId = viewId
			self.onMouseDown = { point, clickCount in
				self.mainQueue.async {
					onMouseDown(point, clickCount)
				}
			}
			self.onMouseDragged = { point in
				self.mainQueue.async {
					onMouseDragged(point)
				}
			}
			self.onDoubleClick = {
				self.mainQueue.async {
					onDoubleClick()
				}
			}
			self.onMouseUp = {
				self.mainQueue.async {
					onMouseUp()
				}
			}
		}
	}
	
	func clearHandlers(for viewId: UUID) {
		eventQueue.async { [weak self] in
			guard let self = self,
				  self.currentViewId == viewId else { return }
			
			self.currentViewId = nil
			self.onMouseDown = { _, _ in }
			self.onMouseDragged = { _ in }
			self.onDoubleClick = {}
			self.onMouseUp = {}
			self.resetState()
		}
	}
	
	// MARK: - Private Methods
	
	private func setupWindowObserver() {
		windowObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didResignKeyNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.handleWindowResignKey()
		}
	}
	
	private func processEvent(_ eventData: EventData) {
		let location = eventData.locationInWindow
		
		switch eventData.type {
		case .leftMouseDown:
			handleMouseDown(location: location, clickCount: eventData.clickCount)
			
		case .leftMouseDragged:
			handleMouseDragged(location: location)
			
		case .leftMouseUp:
			handleMouseUp()
			
		default:
			break
		}
	}
	
	private func handleMouseDown(location: NSPoint, clickCount: Int) {
		// Avoid duplicate processing
		guard location != lastProcessedLocation || clickCount != lastProcessedClickCount else { return }
		lastProcessedLocation = location
		lastProcessedClickCount = clickCount
		
		if clickCount == 2 {
			trackingState = .doubleClick
			onDoubleClick()
		} else {
			trackingState = .dragging
			onMouseDown(location, clickCount)
		}
	}
	
	private func handleMouseDragged(location: NSPoint) {
		guard trackingState == .dragging,
			  location != lastProcessedLocation else { return }
		
		lastProcessedLocation = location
		onMouseDragged(location)
	}
	
	private func handleMouseUp() {
		guard trackingState != .idle else { return }
		onMouseUp()
		resetState()
	}
	
	private func handleWindowResignKey() {
		eventQueue.async { [weak self] in
			guard let self = self,
				  self.trackingState != .idle else { return }
			
			self.onMouseUp()
			self.resetState()
		}
	}
	
	private func resetState() {
		trackingState = .idle
		lastEventTimestamp = 0
		lastProcessedLocation = nil
		lastProcessedClickCount = nil
		lastDragUpdateTime = 0
	}
	
	// MARK: - Cleanup
	
	deinit {
		if let observer = windowObserver {
			NotificationCenter.default.removeObserver(observer)
		}
		stopMonitoring()
	}
}

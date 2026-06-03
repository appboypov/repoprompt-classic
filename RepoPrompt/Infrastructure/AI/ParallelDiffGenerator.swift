import Foundation

class ParallelDiffGenerator {
	private let provider: AIProvider
	private let model: AIModel
	private let parser: IncrementalJSONParser
	
	init(provider: AIProvider, model: AIModel, parser: IncrementalJSONParser) {
		self.provider = provider
		self.model = model
		self.parser = parser
	}
	
	/*
	func generateDiffs(for changes: [ParsedChange], systemPrompt: String) -> AsyncThrowingStream<FileChanges, Error> {
		return AsyncThrowingStream { continuation in
			Task {
				let accumulator = FileChangesAccumulator()
				
				await withTaskGroup(of: FileChanges?.self) { group in
					for change in changes {
						group.addTask {
							let changeMessage = self.createChangeMessage(for: change, systemPrompt: systemPrompt)
							do {
								let stream = try await self.provider.streamMessage(changeMessage, model: self.model)
								var accumulatedOutput = ""
								
								for try await result in stream {
									if let text = result.text {
										accumulatedOutput += text
									}
								}
								
								return self.parser.parseCompleteDiff(accumulatedOutput)
							} catch {
								print("Error processing change for file \(change.filePath): \(error)")
								return nil
							}
						}
					}
					
					for await result in group {
						if let fileChanges = result {
							await accumulator.add(fileChanges)
						}
					}
				}
				
				// Yield accumulated FileChanges objects
				for fileChanges in await accumulator.getAll() {
					continuation.yield(fileChanges)
				}
				
				continuation.finish()
			}
		}
	}
	 */
	
	/*
	private func createChangeMessage(for change: ParsedChange, systemPrompt: String) -> AIMessage {
		let userMessage = """
		File: \(change.filePath)
		Change Type: \(change.type)
		Start Line: \(change.startLine)
		End Line: \(change.endLine ?? change.startLine)
		Description: \(change.description)
		
		Original File Context:
		\(change.fileContext)
		
		Proposed Change Content:
		\(change.content)
		
		Generate a diff for this change.
		"""
		
		return AIMessage(systemPrompt: systemPrompt, userMessage: userMessage)
	}
	*/
}

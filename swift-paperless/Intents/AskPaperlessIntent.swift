//
//  AskPaperlessIntent.swift
//  swift-paperless
//
//  Answers a question from the archive in one step: finds the relevant
//  documents, then has the on-device Apple Intelligence model answer from
//  their text. Siri speaks the answer; nothing leaves the phone except the
//  search request to your own Paperless server.
//

import AppIntents
import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

struct AskPaperlessIntent: AppIntent {
  static let title: LocalizedStringResource = "Ask Paperless"
  static let description = IntentDescription(
    "Answers a question using the text of your Paperless documents.")
  static let openAppWhenRun = false

  static var parameterSummary: some ParameterSummary {
    Summary("Ask Paperless \(\.$question)")
  }

  @Parameter(
    title: "Question",
    requestValueDialog: IntentDialog("What would you like to know from your documents?"))
  var question: String

  init() {}

  /// Documents whose text is given to the model. The on-device model has a
  /// small context window, so this stays low.
  static let documentsForAnswer = 3
  static let charactersPerDocument = 2500

  func perform() async throws
    -> some IntentResult & ReturnsValue<[PaperlessDocumentEntity]> & ProvidesDialog
  {
    let documents = try await PaperlessDocumentSearch.search(question, limit: 5)

    guard !documents.isEmpty else {
      return .result(
        value: [],
        dialog: "I couldn't find any documents in Paperless related to that.")
    }

    let answer = await Self.answer(question, from: documents)
    return .result(value: documents, dialog: IntentDialog(stringLiteral: answer))
  }

  private static func answer(
    _ question: String, from documents: [PaperlessDocumentEntity]
  ) async -> String {
    let fallback =
      "I found \(documents.count) documents. The most relevant is "
      + "\(documents[0].title), dated "
      + "\(documents[0].created.formatted(date: .long, time: .omitted))."

    #if canImport(FoundationModels)
      if #available(iOS 26.0, *) {
        guard case .available = SystemLanguageModel.default.availability else {
          return fallback
        }
        let context = documents.prefix(documentsForAnswer).enumerated().map { index, doc in
          let text = (doc.content ?? "").prefix(charactersPerDocument)
          return """
            [Document \(index + 1)]
            Title: \(doc.title)
            Date: \(doc.created.formatted(date: .long, time: .omitted))
            Correspondent: \(doc.correspondent ?? "unknown")
            Type: \(doc.documentType ?? "unknown")
            Text:
            \(text)
            """
        }.joined(separator: "\n\n")

        let session = LanguageModelSession(
          instructions: """
            You answer questions about the user's own documents. Use only the \
            documents provided. Documents are listed newest first. Answer in one or \
            two short spoken sentences, include amounts and dates exactly as written, \
            and name the document you used. If the documents do not contain the \
            answer, say so briefly.
            """)
        do {
          let response = try await session.respond(
            to: "Question: \(question)\n\nDocuments:\n\(context)")
          let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
          return text.isEmpty ? fallback : text
        } catch {
          return fallback
        }
      }
    #endif
    return fallback
  }
}

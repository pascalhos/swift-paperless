//
//  SearchDocumentsIntent.swift
//  swift-paperless
//
//  Lets Siri, Spotlight and Shortcuts search the archive and open a result.
//

import AppIntents
import AppShared
import DataModel
import Foundation
import Networking
import UIKit

// MARK: - Document entity

struct PaperlessDocumentEntity: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Document")
  static let defaultQuery = PaperlessDocumentQuery()

  let id: Int

  @Property(title: "Title")
  var title: String

  @Property(title: "Correspondent")
  var correspondent: String?

  @Property(title: "Document Type")
  var documentType: String?

  @Property(title: "Tags")
  var tags: [String]

  @Property(title: "Created")
  var created: Date

  @Property(title: "Archive Serial Number")
  var asn: Int?

  /// The document's OCR text (trimmed), so Siri can answer from it.
  @Property(title: "Content")
  var content: String?

  var displayRepresentation: DisplayRepresentation {
    let date = created.formatted(date: .abbreviated, time: .omitted)
    let parts = [correspondent, documentType, date].compactMap { $0 }
    return DisplayRepresentation(
      title: "\(title)",
      subtitle: "\(parts.joined(separator: " · "))",
      image: DisplayRepresentation.Image(systemName: "doc.text"))
  }

  /// Element names, read once from the store's cache on the main actor.
  struct Names: Sendable {
    var correspondents: [UInt: String] = [:]
    var documentTypes: [UInt: String] = [:]
    var tags: [UInt: String] = [:]

    @MainActor
    init(_ store: DocumentStore) {
      correspondents = store.correspondents.mapValues { $0.name }
      documentTypes = store.documentTypes.mapValues { $0.name }
      tags = store.tags.mapValues { $0.name }
    }
  }

  init(_ document: Document, names: Names) {
    id = Int(document.id)
    title = document.title
    correspondent = document.correspondent.flatMap { names.correspondents[$0] }
    documentType = document.documentType.flatMap { names.documentTypes[$0] }
    tags = document.tags.compactMap { names.tags[$0] }
    created = document.created
    asn = document.asn.map { Int($0) }
    content = document.content.map { Self.trim($0) }
  }

  static let maxContentLength = 4000

  private static func trim(_ text: String) -> String {
    let collapsed = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    return collapsed.count > maxContentLength
      ? String(collapsed.prefix(maxContentLength)) + "…" : collapsed
  }
}

struct PaperlessDocumentQuery: EntityStringQuery {
  func entities(for identifiers: [PaperlessDocumentEntity.ID]) async throws
    -> [PaperlessDocumentEntity]
  {
    guard !identifiers.isEmpty else { return [] }
    return try await PaperlessIntentStore.run { context in
      let store = try await context.store()
      await store.sync(timeout: .seconds(3))
      let ids: [UInt] = identifiers.map { UInt($0) }
      let repository = await store.repository
      let docs = try await repository.documents(ids: ids)
      let names = await PaperlessDocumentEntity.Names(store)
      return docs.map { PaperlessDocumentEntity($0, names: names) }
    }
  }

  func entities(matching string: String) async throws -> [PaperlessDocumentEntity] {
    try await PaperlessDocumentSearch.search(string, limit: 10)
  }

  func suggestedEntities() async throws -> [PaperlessDocumentEntity] { [] }
}

enum PaperlessDocumentSearch {
  /// How many of the top hits get their full text fetched for Siri.
  static let fullTextHits = 3

  /// Full-text search (title + content), newest first. The top hits carry
  /// their full OCR text; the rest carry the server's truncated snippet.
  static func search(
    _ text: String, limit: UInt, server: PaperlessServerEntity? = nil
  ) async throws -> [PaperlessDocumentEntity] {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }

    let filter = FilterState.empty.with {
      $0.searchText = query
      $0.searchMode = .titleContent
      $0.sorting = FilterState.Sorting(field: .created, order: .descending)
    }

    return try await PaperlessIntentStore.run { context in
      let store = try await context.store(server: server)
      // Names for correspondents/types/tags come from the local cache.
      await store.sync(timeout: .seconds(3))
      let repository = await store.repository
      let source = try await repository.documents(filter: filter)
      var documents = try await source.fetch(limit: limit)
      for index in documents.indices.prefix(fullTextHits) {
        if let full = try? await repository.document(id: documents[index].id),
          let content = full.content
        {
          documents[index].content = content
        }
      }
      let names = await PaperlessDocumentEntity.Names(store)
      return documents.map { PaperlessDocumentEntity($0, names: names) }
    }
  }
}

// MARK: - Search intent

struct SearchDocumentsIntent: AppIntent {
  static let title: LocalizedStringResource = "Search Documents"
  static let description = IntentDescription(
    "Searches the titles and full text of your Paperless documents and returns the matches.")
  static let openAppWhenRun = false

  static var parameterSummary: some ParameterSummary {
    Summary("Search \(\.$server) for \(\.$query)") {
      \.$limit
    }
  }

  @Parameter(
    title: "Search Text",
    requestValueDialog: IntentDialog("What should I search for in Paperless?"))
  var query: String

  @Parameter(title: "Server")
  var server: PaperlessServerEntity?

  @Parameter(title: "Maximum Results", default: 10, inclusiveRange: (1, 50))
  var limit: Int

  init() {}

  func perform() async throws
    -> some IntentResult & ReturnsValue<[PaperlessDocumentEntity]> & ProvidesDialog
  {
    let results = try await PaperlessDocumentSearch.search(
      query, limit: UInt(limit), server: server)

    let dialog: IntentDialog
    switch results.count {
    case 0:
      dialog = "I couldn't find any documents matching \(query)."
    case 1:
      dialog = "I found 1 document: \(results[0].title)."
    default:
      let top = results.prefix(3).map(\.title).joined(separator: "; ")
      dialog = "I found \(results.count) documents. The most recent are: \(top)."
    }
    return .result(value: results, dialog: dialog)
  }
}

// MARK: - Open intent

struct OpenDocumentIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Document"
  static let description = IntentDescription("Opens a Paperless document in the app.")

  @Parameter(title: "Document")
  var target: PaperlessDocumentEntity

  init() {}

  @MainActor
  func perform() async throws -> some IntentResult {
    let route = Route(action: .document(id: UInt(target.id), edit: nil))
    if let url = route.url {
      await UIApplication.shared.open(url)
    }
    return .result()
  }
}

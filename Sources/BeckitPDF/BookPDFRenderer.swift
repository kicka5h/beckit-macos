import AppKit
import BeckitKit
import CoreGraphics
import Foundation

/// Typesets a book to PDF using TextKit and Core Graphics.
///
/// Beckit 3.x shipped pandoc *and* a TeX Live distribution inside the app to do
/// this — several hundred megabytes of payload, a per-platform download in CI,
/// and a class of failure the writer could do nothing about when a LaTeX
/// package went missing. macOS already knows how to lay out and paginate text,
/// so none of that has to ship.
public struct BookPDFRenderer: Sendable {

    public struct Configuration: Sendable {
        /// US Letter at 72dpi. Trade paperback sizes are the obvious next step.
        public var pageSize = CGSize(width: 612, height: 792)
        public var margins = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
        public var bodyFontSize: CGFloat = 12
        public var bodyFontName = "Iowan Old Style"
        public var includeTitlePage = true
        public var includeContents = true
        public var includePageNumbers = true

        public init() {}

        var textWidth: CGFloat { pageSize.width - margins.left - margins.right }
        var textHeight: CGFloat { pageSize.height - margins.top - margins.bottom }
    }

    /// One section's markdown, already pulled off disk.
    public struct Document: Sendable {
        public var title: String
        public var kind: BookSection.Kind
        public var markdown: String
        /// Chapter number, when this is a numbered chapter.
        public var number: Int?

        public init(title: String, kind: BookSection.Kind, markdown: String, number: Int? = nil) {
            self.title = title
            self.kind = kind
            self.markdown = markdown
            self.number = number
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Renders the book and writes it to `destination`.
    ///
    /// Runs entirely off the main actor — a full-length novel takes long enough
    /// that laying it out on the main thread would visibly stall the window.
    public func render(
        documents: [Document],
        title: String,
        author: String,
        to destination: URL
    ) throws {
        guard !documents.isEmpty else { throw PDFError.nothingToExport }

        var mediaBox = CGRect(origin: .zero, size: configuration.pageSize)
        let info: [String: Any] = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextAuthor as String: author,
            kCGPDFContextCreator as String: "Beckit",
        ]

        guard let context = CGContext(
            destination as CFURL, mediaBox: &mediaBox, info as CFDictionary)
        else { throw PDFError.couldNotCreate(destination) }

        let layout = MarkdownLayout(configuration: configuration)

        if configuration.includeTitlePage {
            drawTitlePage(title: title, author: author, in: context, layout: layout)
        }

        // Chapters start on their own page, so page numbers can be collected on
        // the way through and used for the table of contents.
        var startPages: [(Document, Int)] = []
        var pageNumber = configuration.includeTitlePage ? 2 : 1

        // The contents page is drawn last but must appear early, so reserve its
        // position by rendering the body into a second pass. For a first cut we
        // render the body, remember where each section began, then append the
        // contents at the end — honest, and avoids a two-pass layout.
        for document in documents {
            startPages.append((document, pageNumber))
            let attributed = layout.attributedString(for: document)
            pageNumber += draw(
                attributed, in: context, layout: layout, startingAt: pageNumber)
        }

        if configuration.includeContents {
            drawContents(startPages, in: context, layout: layout)
        }

        context.closePDF()
    }

    // MARK: - Pagination

    /// Lays `text` out across as many pages as it needs. Returns the page count.
    private func draw(
        _ text: NSAttributedString,
        in context: CGContext,
        layout: MarkdownLayout,
        startingAt firstPageNumber: Int
    ) -> Int {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(
            rect: CGRect(
                x: configuration.margins.left,
                y: configuration.margins.bottom,
                width: configuration.textWidth,
                height: configuration.textHeight),
            transform: nil)

        var start = 0
        var pages = 0
        let length = text.length

        // A section always occupies at least one page, even when empty, so a
        // blank Dedication still turns a leaf the way a printed book does.
        repeat {
            context.beginPDFPage(nil)

            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, context)

            if configuration.includePageNumbers {
                drawPageNumber(firstPageNumber + pages, in: context, layout: layout)
            }
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            pages += 1

            // Guard against a glyph that cannot fit the frame at all, which
            // would otherwise spin forever producing empty pages.
            guard visible.length > 0 else { break }
            start += visible.length
        } while start < length

        return pages
    }

    // MARK: - Furniture

    private func drawTitlePage(
        title: String, author: String, in context: CGContext, layout: MarkdownLayout
    ) {
        context.beginPDFPage(nil)

        let block = NSMutableAttributedString(
            string: title + "\n\n", attributes: layout.titlePageTitle)
        if !author.isEmpty {
            block.append(NSAttributedString(string: author, attributes: layout.titlePageAuthor))
        }

        // Sit the block on the upper third, the conventional place for it.
        let height = block.boundingRect(
            with: CGSize(width: configuration.textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]).height

        draw(block, at: CGRect(
            x: configuration.margins.left,
            y: configuration.pageSize.height * 0.62 - height,
            width: configuration.textWidth,
            height: height), in: context)

        context.endPDFPage()
    }

    private func drawContents(
        _ entries: [(Document, Int)], in context: CGContext, layout: MarkdownLayout
    ) {
        let listed = entries.filter { !$0.0.title.isEmpty || $0.0.number != nil }
        guard !listed.isEmpty else { return }

        context.beginPDFPage(nil)

        let block = NSMutableAttributedString(
            string: "Contents\n\n", attributes: layout.contentsHeading)
        for (document, page) in listed {
            let label = layout.displayTitle(for: document)
            block.append(NSAttributedString(
                string: "\(label)\t\(page)\n", attributes: layout.contentsEntry))
        }

        draw(block, at: CGRect(
            x: configuration.margins.left,
            y: configuration.margins.bottom,
            width: configuration.textWidth,
            height: configuration.textHeight), in: context)

        context.endPDFPage()
    }

    private func drawPageNumber(_ number: Int, in context: CGContext, layout: MarkdownLayout) {
        let text = NSAttributedString(string: "\(number)", attributes: layout.pageNumber)
        draw(text, at: CGRect(
            x: configuration.margins.left,
            y: configuration.margins.bottom * 0.45,
            width: configuration.textWidth,
            height: configuration.bodyFontSize * 2), in: context)
    }

    private func draw(_ text: NSAttributedString, at rect: CGRect, in context: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }
}

public enum PDFError: Error, LocalizedError {
    case nothingToExport
    case couldNotCreate(URL)

    public var errorDescription: String? {
        switch self {
        case .nothingToExport:
            "This book has no content to export yet."
        case .couldNotCreate(let url):
            "Beckit could not write a PDF to \(url.path(percentEncoded: false))."
        }
    }
}

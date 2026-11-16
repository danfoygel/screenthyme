import Foundation
import Testing
@testable import ThymeCore

struct SiteIconsTests {
    let base = URL(string: "https://www.example.com/news/")!

    @Test func touchIconsComeFirstThenBiggerIcons() {
        let html = """
        <head><link rel="icon" href="/favicon-16.png" sizes="16x16">
        <LINK REL='shortcut icon' HREF='/favicon-32.png' SIZES='32x32'/>
        <link href="https://cdn.example.com/touch.png?v=1&amp;w=180" rel="apple-touch-icon" sizes="180x180">
        <link rel="stylesheet" href="/site.css"></head>
        """
        #expect(SiteIcons.linked(in: html, base: base).map(\.absoluteString) == [
            "https://cdn.example.com/touch.png?v=1&w=180",
            "https://www.example.com/favicon-32.png",
            "https://www.example.com/favicon-16.png",
        ])
    }

    @Test func relativeHrefsResolveAgainstThePageAndSVGsAreSkipped() {
        let html = """
        <link rel="icon" type="image/svg+xml" href="/icon.svg">
        <link rel="icon" href="/logo.svg">
        <link rel=icon href=img/fav.png>
        <link rel="icon" href="data:image/png;base64,AAAA">
        """
        #expect(SiteIcons.linked(in: html, base: base).map(\.absoluteString) == ["https://www.example.com/news/img/fav.png"])
    }

    @Test func hostsFallBackToTheParentDomain() {
        #expect(SiteIcons.hosts(for: "googleads.g.doubleclick.net") == ["googleads.g.doubleclick.net", "doubleclick.net"])
        #expect(SiteIcons.hosts(for: "theonion.com") == ["theonion.com"])
    }
}

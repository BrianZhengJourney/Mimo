// sources: reflection_core.swift
// gui-only: requires an unlocked macOS session with WebKit services available
import AppKit
import Foundation
import WebKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var finished = false
    var failed = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) { failed = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { failed = true }
}

private func spin(until condition: @escaping () -> Bool,
                  timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return condition()
}

private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
    var finished = false
    var value: Any?
    var failure: Error?
    webView.evaluateJavaScript(script) { result, error in
        value = result
        failure = error
        finished = true
    }
    expect(spin(until: { finished }), "JavaScript evaluation timed out")
    expect(failure == nil, "JavaScript evaluation failed: \(failure?.localizedDescription ?? "unknown")")
    return value
}

@main
struct ReflectionBrowserDOMTests {
    static func main() throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_240, height: 800),
                                configuration: configuration)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        let html = try String(contentsOfFile: "mac/reflection.html", encoding: .utf8)
        webView.loadHTMLString(html, baseURL: nil)
        expect(spin(until: { waiter.finished || waiter.failed }), "fixture navigation timed out")
        expect(waiter.finished && !waiter.failed, "fixture loads in a real WKWebView")
        _ = evaluate("window.reflectionFixture('1')", in: webView)

        let initial = evaluate("JSON.stringify({blocks:document.querySelectorAll('.activity-card').length,materials:document.querySelectorAll('.material-card').length,sections:document.querySelectorAll('.reflection-section').length,raw:document.querySelectorAll('.raw-event').length,journey:document.querySelectorAll('.flow-cluster').length,clusterTicks:document.querySelectorAll('.cluster-tick').length,phases:document.querySelectorAll('.journey-phase').length,activityHovers:document.querySelectorAll('.activity-hover').length,materialOverlays:document.querySelectorAll('.material-insight-overlay').length,identityImages:document.querySelectorAll('.identity-image').length,appIdentities:document.querySelectorAll('[data-identity=app]').length,siteIdentities:document.querySelectorAll('[data-identity=site]').length,donut:getComputedStyle(document.getElementById('donut')).backgroundImage})",
                               in: webView) as? String
        let object = try JSONSerialization.jsonObject(
            with: Data((initial ?? "{}").utf8)) as? [String: Any]
        expect(object?["blocks"] as? Int == 5
               && object?["materials"] as? Int == 3
               && object?["sections"] as? Int == 5
               && object?["raw"] as? Int == 6,
               "populated fixture renders blocks, learning cards, reflection, and raw evidence")
        expect(object?["journey"] as? Int == 5
               && object?["clusterTicks"] as? Int == 5
               && (object?["phases"] as? Int ?? 0) >= 2
               && object?["activityHovers"] as? Int == 5
               && object?["materialOverlays"] as? Int == 3,
               "flow clusters retain every block as internal texture alongside day phases")
        expect((object?["identityImages"] as? Int ?? 0) >= 4
               && (object?["appIdentities"] as? Int ?? 0) >= 1
               && (object?["siteIdentities"] as? Int ?? 0) >= 1,
               "app activities and websites render representative identity artwork")
        expect((evaluate("(()=>{const base=new Date();base.setHours(8,0,0,0);const categories=['building','communication','admin','learning'];const blocks=Array.from({length:80},(_,index)=>({id:`dense-${index}`,title:`App ${index%6}`,category:categories[index%4],start:new Date(base.getTime()+index*60000).toISOString(),end:new Date(base.getTime()+(index+1)*60000).toISOString(),activeSeconds:60,apps:[`App ${index%6}`],domains:[],contextSwitches:1,eventIDs:[],events:[]}));const clusters=buildFlowClusters(blocks);return clusters.length>=6&&clusters.length<=10&&clusters.flatMap(cluster=>cluster.blocks).length===80})()",
                         in: webView) as? Bool) == true,
               "dense days collapse into a small set of clusters without dropping moments")
        expect((object?["donut"] as? String)?.contains("conic-gradient") == true,
               "category distribution renders as a visual donut")

        expect((evaluate("const cluster=document.querySelector('.flow-cluster');cluster.focus();document.getElementById('journeyPreview').dataset.cluster===cluster.dataset.flowCluster",
                         in: webView) as? Bool) == true,
               "keyboard focus updates the same cluster preview as hover")
        expect((evaluate("const map=document.querySelector('.journey-map').getBoundingClientRect();const preview=document.getElementById('journeyPreview').getBoundingClientRect();preview.left>=map.left&&preview.right<=map.right&&preview.top>=map.top&&preview.bottom<=map.bottom",
                         in: webView) as? Bool) == true,
               "journey preview remains inside its reserved map area")
        expect((evaluate("const card=document.querySelector('.activity-card');card.focus();const panel=document.querySelector('.trail-panel').getBoundingClientRect();const hover=card.querySelector('.activity-hover').getBoundingClientRect();hover.height>0&&hover.left>=panel.left&&hover.right<=panel.right",
                         in: webView) as? Bool) == true,
               "activity hover context remains inside the trail panel")
        expect((evaluate("[...document.querySelectorAll('[data-flow-cluster]')].find(item=>item.dataset.clusterBlocks.split(',').includes('b4')).click();document.querySelector('[data-block=b4]').classList.contains('located')",
                         in: webView) as? Bool) == true,
               "selecting a flow cluster locates its representative detailed activity")

        expect((evaluate("document.querySelector('.raw-toggle').click();document.querySelector('.activity-card').classList.contains('open')",
                         in: webView) as? Bool) == true,
               "raw evidence expands inside its meaningful block")
        expect((evaluate("document.querySelector('[data-evidence]').click();Boolean(document.querySelector('.activity-card.located.open'))",
                         in: webView) as? Bool) == true,
               "reflection citations locate and reveal raw source evidence")

        expect((evaluate("document.querySelector('[data-filter=learning]').click();document.querySelectorAll('.activity-card').length",
                         in: webView) as? Int) == 3,
               "category chips filter the meaningful trail")
        expect((evaluate("document.getElementById('privacyBtn').click();document.getElementById('privacyModal').classList.contains('open')",
                         in: webView) as? Bool) == true,
               "privacy exclusions are reachable from the dashboard")

        _ = evaluate("window.reflectionFixture('nokey')", in: webView)
        expect((evaluate("document.getElementById('synthesizeBtn').disabled",
                         in: webView) as? Bool) == true,
               "missing optional AI configuration never blocks the local dashboard")
        expect((evaluate("document.getElementById('reflectionBadge').textContent",
                         in: webView) as? String) == "只在本机",
               "no-key fixture labels the deterministic local reflection in human language")

        _ = evaluate("window.reflectionFixture('empty')", in: webView)
        expect((evaluate("document.querySelectorAll('.activity-card').length===0&&document.querySelectorAll('.empty').length>=2&&document.getElementById('activeMetric').textContent==='0s'",
                         in: webView) as? Bool) == true,
               "empty state is informative without fabricating activity")

        _ = evaluate("window.reflectionFixture('error')", in: webView)
        expect((evaluate("document.getElementById('notice').classList.contains('error')&&document.getElementById('notice').classList.contains('visible')",
                         in: webView) as? Bool) == true,
               "partial archive errors remain visible")

        webView.frame.size = NSSize(width: 980, height: 640)
        webView.layoutSubtreeIfNeeded()
        expect((evaluate("document.documentElement.scrollWidth<=document.documentElement.clientWidth",
                         in: webView) as? Bool) == true,
               "minimum supported window has no horizontal overflow")

        print("reflection browser DOM tests passed")
    }
}

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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        failed = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        failed = true
    }
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
    expect(failure == nil, "JavaScript evaluation failed")
    return value
}

@main
struct ReflectionBrowserDOMTests {
    static func main() throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_260, height: 790),
                                configuration: configuration)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter

        // Loading the self-contained source string keeps this real WKWebView
        // test compatible with restricted CI/sandbox environments that cannot
        // grant the WebContent process a LaunchServices file extension.
        let html = try String(contentsOfFile: "mac/reflection.html", encoding: .utf8)
        webView.loadHTMLString(html, baseURL: nil)
        expect(spin(until: { waiter.finished || waiter.failed }),
               "fixture navigation timed out")
        expect(waiter.finished && !waiter.failed, "fixture loads in a real WKWebView")
        _ = evaluate("window.reflectionFixture('1')", in: webView)

        let initial = evaluate("JSON.stringify({activities:document.querySelectorAll('.event').length,reflections:document.querySelectorAll('.reflection-card').length,sections:document.querySelectorAll('.claim-section').length,historyMarks:document.querySelectorAll('.conversation-message mark').length})",
                               in: webView) as? String
        let initialObject = try JSONSerialization.jsonObject(
            with: Data((initial ?? "{}").utf8)) as? [String: Int]
        expect(initialObject?["activities"] == 4 && initialObject?["reflections"] == 2
               && initialObject?["sections"] == 6 && initialObject?["historyMarks"] == 1,
               "populated fixture renders all three source/analysis columns")
        expect((evaluate("!document.getElementById('writebackBtn').disabled",
                         in: webView) as? Bool) == true,
               "a prepared synthesis enables writeback preview")

        let layout = evaluate("JSON.stringify({composerParent:document.querySelector('.global-chat')?.parentElement?.className,composerInsideWorkspace:Boolean(document.querySelector('.workspace .global-chat')),dictation:Boolean(document.getElementById('dictationBtn')),horizontalOverflow:document.documentElement.scrollWidth>document.documentElement.clientWidth})",
                              in: webView) as? String
        let layoutObject = try JSONSerialization.jsonObject(
            with: Data((layout ?? "{}").utf8)) as? [String: Any]
        expect(layoutObject?["composerParent"] as? String == "app"
               && layoutObject?["composerInsideWorkspace"] as? Bool == false
               && layoutObject?["dictation"] as? Bool == true
               && layoutObject?["horizontalOverflow"] as? Bool == false,
               "Ask Mimo composer spans beneath all three columns without horizontal overflow")
        expect((evaluate("document.getElementById('dictationBtn').click();document.activeElement?.id",
                         in: webView) as? String) == "prompt",
               "dictation hint focuses the shared Ask Mimo composer")

        webView.frame.size = NSSize(width: 980, height: 640)
        webView.layoutSubtreeIfNeeded()
        expect((evaluate("document.documentElement.scrollWidth<=document.documentElement.clientWidth&&document.querySelector('.workspace').scrollWidth<=document.querySelector('.workspace').clientWidth",
                         in: webView) as? Bool) == true,
               "minimum native window size keeps the three-column workspace inside its viewport")
        webView.frame.size = NSSize(width: 1_260, height: 790)
        webView.layoutSubtreeIfNeeded()

        _ = evaluate("""
          document.getElementById('globalSearch').value='nothing-matches';
          document.getElementById('globalSearch').dispatchEvent(new Event('input'));
          document.getElementById('appFilter').value='Xcode';
          document.getElementById('appFilter').dispatchEvent(new Event('change'));
          document.querySelector('.group')?.removeAttribute('open');
          [...document.querySelectorAll('.evidence-btn')].find(b=>b.textContent==='A-01').click();
        """, in: webView)
        expect(spin(until: {
            (evaluate("document.getElementById('loc-A-01')?.closest('details')?.open",
                      in: webView) as? Bool) == true
        }), "activity evidence opens its collapsed source group")
        let activityLocate = evaluate("JSON.stringify({query:document.getElementById('globalSearch').value,app:document.getElementById('appFilter').value,located:document.getElementById('loc-A-01').classList.contains('located')})",
                                      in: webView) as? String
        let activityObject = try JSONSerialization.jsonObject(
            with: Data((activityLocate ?? "{}").utf8)) as? [String: Any]
        expect(activityObject?["query"] as? String == ""
               && activityObject?["app"] as? String == ""
               && activityObject?["located"] as? Bool == true,
               "activity citation clears hiding filters and highlights its raw event")

        _ = evaluate("""
          document.getElementById('reflectionTypeFilter').value='daily';
          document.getElementById('reflectionTypeFilter').dispatchEvent(new Event('change'));
          [...document.querySelectorAll('.evidence-btn')].find(b=>b.textContent==='N-W31').click();
        """, in: webView)
        expect(spin(until: {
            (evaluate("document.getElementById('loc-N-W31')?.classList.contains('located')",
                      in: webView) as? Bool) == true
        }), "Notion evidence is re-rendered and highlighted")
        expect((evaluate("document.getElementById('reflectionTypeFilter').value",
                         in: webView) as? String) == "",
               "Notion citation clears the type filter that hid its source")

        _ = evaluate("window.reflectionFixture('empty')", in: webView)
        expect((evaluate("document.querySelectorAll('.event').length===0&&document.querySelectorAll('.reflection-card').length===0&&document.querySelectorAll('.empty').length>=3",
                         in: webView) as? Bool) == true,
               "empty fixture renders an intentional empty state in all three columns")
        expect((evaluate("document.getElementById('writebackBtn').disabled",
                         in: webView) as? Bool) == true,
               "empty state disables writeback until a synthesis exists")

        _ = evaluate("window.reflectionFixture('error')", in: webView)
        expect((evaluate("document.querySelectorAll('.banner.error').length>=2&&document.getElementById('statusDot').classList.contains('error')",
                         in: webView) as? Bool) == true,
               "error fixture exposes source and analysis failures visibly")

        _ = evaluate("window.reflectionFixture('notoken')", in: webView)
        expect((evaluate("document.getElementById('reflectionBanner').textContent.includes('尚未连接 Notion')&&document.getElementById('synthesizeBtn').disabled",
                         in: webView) as? Bool) == true,
               "no-token fixture remains browseable while setup-dependent actions stay disabled")
        expect((evaluate("document.getElementById('writebackBtn').disabled",
                         in: webView) as? Bool) == true,
               "no-token state does not advertise unavailable writeback")

        _ = evaluate("""
          (()=>{
          window.reflectionLoad({config:{language:'zh-CN',fixture:true,modelConfigured:true,modelStatus:'ready'},range:{mode:'today',start:'2026-08-02',end:'2026-08-02'},syncState:{status:'synced',hasToken:true},analysisState:{status:'ready'},activities:[],activityGroups:[],reflections:[],evidences:[],conversation:[{id:'duplicate-message',role:'assistant',content:'same same',evidenceIDs:['e-one']}],marks:[],writebackTargets:[]});
          const copy=document.querySelector('.conversation-copy'),node=copy.firstChild,range=document.createRange();range.setStart(node,5);range.setEnd(node,9);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);document.dispatchEvent(new Event('selectionchange'));
          })()
        """, in: webView)
        expect(spin(until: {
            (evaluate("document.getElementById('markToolbar').classList.contains('on')",
                      in: webView) as? Bool) == true
        }), "mark toolbar appears for an exact assistant-text selection")
        _ = evaluate("document.querySelector('[data-mark=highlight]').click()", in: webView)
        expect((evaluate("document.querySelector('.conversation-copy mark')?.previousSibling?.textContent==='same '",
                         in: webView) as? Bool) == true,
               "selecting the second repeated phrase restores the mark at that exact occurrence")
        _ = evaluate("""
          (()=>{
          const copy=document.querySelector('.conversation-copy'),node=copy.firstChild,range=document.createRange();range.setStart(node,0);range.setEnd(node,4);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);document.dispatchEvent(new Event('selectionchange'));
          })()
        """, in: webView)
        expect(spin(until: {
            (evaluate("document.getElementById('markToolbar').classList.contains('on')",
                      in: webView) as? Bool) == true
        }), "toolbar reopens on the unmarked duplicate")
        _ = evaluate("document.querySelector('[data-mark=remove]').click()", in: webView)
        expect((evaluate("document.querySelectorAll('.conversation-copy mark').length===1&&document.querySelector('.conversation-copy mark')?.previousSibling?.textContent==='same '",
                         in: webView) as? Bool) == true,
               "remove on an unmarked duplicate never deletes the marked occurrence")

        print("reflection browser DOM tests passed")
    }
}

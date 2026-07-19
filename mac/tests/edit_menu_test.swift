// sources: app_menu.swift
import Cocoa

@main
struct EditMenuTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("edit menu test failed: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let english = makeStandardEditMenu(language: "en")
        let chinese = makeStandardEditMenu(language: "zh")

        require(english.title == "Edit", "English menu title")
        require(chinese.title == "编辑", "Chinese menu title")

        let expected: [(Selector, String)] = [
            (Selector(("undo:")), "z"),
            (Selector(("redo:")), "z"),
            (#selector(NSText.cut(_:)), "x"),
            (#selector(NSText.copy(_:)), "c"),
            (#selector(NSText.paste(_:)), "v"),
            (#selector(NSText.selectAll(_:)), "a"),
        ]

        for (action, key) in expected {
            guard let item = english.items.first(where: { $0.action == action }) else {
                require(false, "missing \(NSStringFromSelector(action))")
                continue
            }
            require(item.target == nil, "\(NSStringFromSelector(action)) must use the responder chain")
            require(item.keyEquivalent.lowercased() == key, "wrong shortcut for \(NSStringFromSelector(action))")
            require(item.keyEquivalentModifierMask.contains(NSEvent.ModifierFlags.command), "missing Command modifier")
        }

        let redo = english.items.first { $0.action == Selector(("redo:")) }
        require(redo?.keyEquivalentModifierMask.contains(NSEvent.ModifierFlags.shift) == true, "Redo must be Shift-Command-Z")
        print("edit menu tests passed")
    }
}

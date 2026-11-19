import AppKit
import Carbon
import Foundation
import KSSCore

enum NotesError: LocalizedError {
    case script(String, Int)
    var errorDescription: String? {
        switch self {
        case .script(let msg, let code):
            if code == -1743 {
                return L("Keine Berechtigung für die App Notizen. Bitte in Systemeinstellungen › Datenschutz & Sicherheit › Automation „Scribe Sync → Notizen“ erlauben.")
            }
            return "\(msg) (\(code))"
        }
    }
}

/// Writes notes through AppleScript, in-process (no osascript helper).
///
/// Update rules – the fix for duplicated notes:
/// * a known note is always updated in place (`set body`);
/// * a new note is created ONLY if the old one provably no longer exists
///   (deleted / in "Recently Deleted"); any other error is reported, never
///   silently turned into a new note;
/// * if the Scribe folder changed, the note is recreated in the new folder and
///   the old one deleted – AppleScript's `move` is avoided (it can duplicate).
final class NotesScripting: NotesPublisher, @unchecked Sendable {
    private let accountName: @Sendable () -> String

    init(accountName: @escaping @Sendable () -> String) { self.accountName = accountName }

    private static let source = #"""
    on upsertNote(noteId, accountName, folderPathText, htmlBody, imagePathsText)
        tell application "Notes"
            set targetAccount to my resolveAccount(accountName)
            set targetFolder to my ensureFolder(targetAccount, folderPathText)
            set targetFolderId to id of targetFolder
            if noteId is not "" then
                set theNote to my findNote(noteId)
                if theNote is not missing value then
                    if my containerId(theNote) is targetFolderId then
                        my writeBody(theNote, htmlBody, imagePathsText)
                        return id of theNote
                    end if
                    -- the notebook moved to another folder on the Scribe
                    set newNote to make new note at targetFolder with properties {body:htmlBody}
                    my writeBody(newNote, htmlBody, imagePathsText)
                    delete theNote
                    return id of newNote
                end if
            end if
            set newNote to make new note at targetFolder with properties {body:htmlBody}
            my writeBody(newNote, htmlBody, imagePathsText)
            return id of newNote
        end tell
    end upsertNote

    -- Notes is sandboxed and cannot read <img src="file://…"> on its own (it shows an
    -- empty placeholder). Attaching a file hands it over together with read access;
    -- setting the body afterwards puts every image at its place in the text and
    -- replaces these temporary attachments.
    on writeBody(theNote, htmlBody, imagePathsText)
        if imagePathsText is not "" then
            set AppleScript's text item delimiters to linefeed
            set imagePaths to text items of imagePathsText
            set AppleScript's text item delimiters to ""
            tell application "Notes"
                repeat with p in imagePaths
                    try
                        make new attachment at end of attachments of theNote with data (POSIX file (p as text))
                    end try
                end repeat
            end tell
        end if
        tell application "Notes" to set body of theNote to htmlBody
    end writeBody

    on noteBody(noteId)
        tell application "Notes" to return body of note id noteId
    end noteBody

    on deleteNote(noteId)
        tell application "Notes" to delete note id noteId
    end deleteNote

    on findNote(noteId)
        tell application "Notes"
            try
                set theNote to note id noteId
                set probe to name of theNote
            on error errMsg number errNum
                if errNum is in {-1728, -1719, -10000, -1700} then return missing value
                error errMsg number errNum
            end try
            try
                set folderName to name of container of theNote
                if folderName is in {"Recently Deleted", "Zuletzt gelöscht"} then return missing value
            end try
            return theNote
        end tell
    end findNote

    on containerId(theNote)
        tell application "Notes"
            try
                return id of container of theNote
            on error
                return ""
            end try
        end tell
    end containerId

    on resolveAccount(accountName)
        tell application "Notes"
            if accountName is not "" then
                if exists account accountName then return account accountName
            end if
            return default account
        end tell
    end resolveAccount

    on ensureFolder(acc, pathText)
        set AppleScript's text item delimiters to "/"
        set parts to text items of pathText
        set AppleScript's text item delimiters to ""
        tell application "Notes"
            set parentObj to acc
            repeat with p in parts
                set folderName to p as text
                if folderName is not "" then
                    if exists folder folderName of parentObj then
                        set parentObj to folder folderName of parentObj
                    else
                        set parentObj to make new folder at parentObj with properties {name:folderName}
                    end if
                end if
            end repeat
            return parentObj
        end tell
    end ensureFolder

    on showNote(noteId)
        tell application "Notes"
            show note id noteId
            activate
        end tell
    end showNote

    on accountNames()
        tell application "Notes" to return name of every account
    end accountNames
    """#

    @MainActor private static var compiled: NSAppleScript?

    @MainActor private static func script() throws -> NSAppleScript {
        if let s = compiled { return s }
        guard let s = NSAppleScript(source: source) else { throw NotesError.script(L("Skript ungültig"), 0) }
        var err: NSDictionary?
        if !s.compileAndReturnError(&err) {
            throw NotesError.script(err?[NSAppleScript.errorMessage] as? String ?? L("Kompilierfehler"), 0)
        }
        compiled = s
        return s
    }

    @MainActor private static func call(_ handler: String, _ args: [String]) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                           eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { list.insert(NSAppleEventDescriptor(string: a), at: i + 1) }
        event.setDescriptor(list, forKeyword: AEKeyword(keyDirectObject))
        var err: NSDictionary?
        let result = try script().executeAppleEvent(event, error: &err)
        if let err {
            throw NotesError.script(err[NSAppleScript.errorMessage] as? String ?? L("AppleScript-Fehler"),
                                   err[NSAppleScript.errorNumber] as? Int ?? 0)
        }
        return result
    }

    func publish(html: String, images: [URL], existingNoteID: String?, folderPath: [String]) async throws -> String {
        let path = folderPath.map { $0.replacingOccurrences(of: "/", with: "∕") }.joined(separator: "/")
        let account = accountName()
        return try await MainActor.run {
            try Self.call("upsertNote", [existingNoteID ?? "", account, path, html,
                                         images.map(\.path).joined(separator: "\n")]).stringValue ?? ""
        }
    }

    @MainActor static func compileCheck() throws { _ = try script() }

    /// For the self-test: the note's body as Notes stores it (images as data URIs).
    @MainActor static func body(noteID: String) throws -> String {
        try call("noteBody", [noteID]).stringValue ?? ""
    }

    @MainActor static func delete(noteID: String) throws { _ = try call("deleteNote", [noteID]) }

    @MainActor static func show(noteID: String) async {
        _ = try? call("showNote", [noteID])
    }

    @MainActor static func accountNames() -> [String] {
        guard let list = try? call("accountNames", []) else { return [] }
        return (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1)?.stringValue }
    }
}

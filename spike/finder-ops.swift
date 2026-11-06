// Exercises the file operations Finder and Mac apps use, on a Kitty Finder drive.
// Usage: swift spike/finder-ops.swift "<mount path>"
// Works in a new kd-ops-<time> folder on the drive and removes it at the end.
import Foundation

let mount = CommandLine.arguments[1]
let fm = FileManager.default
let root = URL(fileURLWithPath: mount).appending(path: "kd-ops-\(Int(Date().timeIntervalSince1970))")
let local = fm.temporaryDirectory.appending(path: "kf-ops-\(UUID().uuidString)")
var failures = 0

func check(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("PASS  \(name)")
    } catch {
        failures += 1
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " [\($0.domain) \($0.code)]" } ?? ""
        print("FAIL  \(name): \(ns.localizedDescription)\(posix)")
    }
}

func posix(_ result: Int32, _ what: String) throws {
    if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"]) }
}

try fm.createDirectory(at: root, withIntermediateDirectories: true)
try fm.createDirectory(at: local, withIntermediateDirectories: true)
defer {
    try? fm.removeItem(at: local)
}

// Something to copy in from "main Mac storage": a folder with tags, a symlink, nested files
let src = local.appending(path: "Project")
try fm.createDirectory(at: src.appending(path: "sub"), withIntermediateDirectories: true)
try Data("hello".utf8).write(to: src.appending(path: "notes.txt"))
try Data(repeating: 7, count: 300_000).write(to: src.appending(path: "sub/photo.jpg"))
try fm.createSymbolicLink(atPath: src.appending(path: "link-to-notes").path, withDestinationPath: "notes.txt")
try (src.appending(path: "notes.txt") as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)

check("Finder-style copy of a folder from the Mac (with tags + symlink)") {
    try fm.copyItem(at: src, to: root.appending(path: "Project"))
}
check("copy a single file from the Mac") {
    try fm.copyItem(at: src.appending(path: "sub/photo.jpg"), to: root.appending(path: "photo copy.jpg"))
}

let doc = root.appending(path: "doc.txt")
check("create a document") { try Data("v1".utf8).write(to: doc) }
check("app save: atomic write (temp file + rename)") { try Data("v2".utf8).write(to: doc, options: .atomic) }
check("app save: NSFileManager replaceItemAt (NSDocument style)") {
    let tmp = root.appending(path: ".doc.txt.sb-tmp")
    try Data("v3".utf8).write(to: tmp)
    _ = try fm.replaceItemAt(doc, withItemAt: tmp)
}
check("app save: swap files (renamex_np RENAME_SWAP)") {
    let other = root.appending(path: "swap.txt")
    try Data("other".utf8).write(to: other)
    try posix(renamex_np(doc.path, other.path, UInt32(RENAME_SWAP)), "renamex_np")
}
check("edit in place (open, seek, write)") {
    let h = try FileHandle(forUpdating: doc)
    try h.seek(toOffset: 1); try h.write(contentsOf: Data("X".utf8)); try h.close()
}
check("add a Finder tag") { try (doc as NSURL).setResourceValue(["Blue"], forKey: .tagNamesKey) }
check("read the tag back") {
    let tags = try doc.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    if tags != ["Blue"] { throw NSError(domain: "tags", code: 1, userInfo: [NSLocalizedDescriptionKey: "got \(tags)"]) }
}
check("set modification date") { try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: doc.path) }
check("set creation date (Finder does this when copying)") { try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: doc.path) }
check("lock a file (Get Info → Locked)") { try fm.setAttributes([.immutable: true], ofItemAtPath: doc.path) }
try? fm.setAttributes([.immutable: false], ofItemAtPath: doc.path)
check("make a symlink") { try fm.createSymbolicLink(atPath: root.appending(path: "alias-ish").path, withDestinationPath: "doc.txt") }
check("make a hard link") { try fm.linkItem(at: doc, to: root.appending(path: "hardlink.txt")) }
check("rename a folder") { try fm.moveItem(at: root.appending(path: "Project"), to: root.appending(path: "Project renamed")) }
check("move a file into a folder") { try fm.moveItem(at: root.appending(path: "photo copy.jpg"), to: root.appending(path: "Project renamed/photo copy.jpg")) }
check("duplicate a file (copy within the drive)") { try fm.copyItem(at: doc, to: root.appending(path: "doc copy.txt")) }
check("delete a file") { try fm.removeItem(at: root.appending(path: "doc copy.txt")) }
check("delete a non-empty folder") { try fm.removeItem(at: root.appending(path: "Project renamed")) }
check("delete everything") { try fm.removeItem(at: root) }
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")

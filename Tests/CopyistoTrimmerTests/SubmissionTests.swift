import Foundation
import Testing

@testable import CopyistoTrimmer

// MARK: Recognising the folder

@Test @MainActor func aSubmissionWithOneNotebookHasNoSections() throws {
    let root = try submission("M4K-V", notebooks: ["01": ["skan_001.png", "skan_002.png"]])
    let store = Store()
    store.open(root)
    #expect(store.submission?.code == "M4K-V" && store.isSubmissionRoot)
    #expect(store.title == "M4K-V")
    #expect(store.notebooks.map(\.name) == ["01"])
    #expect(store.images == ["01/skan_001.png", "01/skan_002.png"])
    #expect(store.strayFiles.isEmpty)
}

@Test @MainActor func notebooksAreListedByNumberWithNewOnesLast() throws {
    let root = try submission("M4K-V", notebooks: ["nowy": ["a.png"], "10": ["a.png"], "02": ["a.png"], "01": ["a.png"]])
    try Data().write(to: root.appending(path: "zgubiony.png"))
    try Data().write(to: root.appending(path: ".DS_Store"))
    let store = Store()
    store.open(root)
    #expect(store.notebooks.map(\.name) == ["01", "02", "10", "nowy"])
    #expect(store.notebooks.map(store.title(of:)) == ["M4K-V-01", "M4K-V-02", "M4K-V-10", "nowy: nowy zeszyt"])
    #expect(store.notebooks.map(store.number(of:)) == ["01", "02", "10", nil])
    // Files at the top belong to no notebook: listed, never shown as scans.
    #expect(store.strayFiles == ["zgubiony.png"])
    #expect(!store.images.contains { !$0.contains("/") })
}

@Test @MainActor func aNotebookOpenedOnItsOwnTakesItsIDFromTheSubmission() throws {
    let root = try submission("M4K-V", notebooks: ["01": ["skan_001.png"], "nowy": ["x.png"]])
    let store = Store()
    store.open(root.appending(path: "01"))
    #expect(store.submission?.code == "M4K-V" && !store.isSubmissionRoot)
    #expect(store.title == "M4K-V-01")
    #expect(store.images == ["skan_001.png"])
    #expect(store.descriptionLevel(of: "skan_001.png") == ["notebooks", "01", "files", "skan_001.png"])
    store.open(root.appending(path: "nowy"))
    #expect(store.title == "nowy: nowy zeszyt")
    #expect(store.descriptionLevel(of: "x.png") == nil)
}

@Test @MainActor func aPlainFolderOpensAsBefore() throws {
    let folder = try temporaryFolder()
    try writePNG(width: 8, height: 8, to: folder.appending(path: "a.png")) { _, _ in (0, 0, 0) }
    let store = Store()
    store.open(folder)
    #expect(store.submission == nil && store.title == folder.lastPathComponent)
    #expect(store.images == ["a.png"] && store.notebooks.count == 1)
}

@Test func aStateWithoutCodeOrBrokenIsNoSubmission() throws {
    let root = try submission("M4K-V", notebooks: ["01": []])
    let state = root.appending(path: ".copyisto/state.json")
    #expect(Submission.of(root)?.submission.code == "M4K-V")
    try Data(#"{"server": "http://127.0.0.1:8788"}"#.utf8).write(to: state)
    #expect(Submission.of(root) == nil)
    try Data("{ zepsuty".utf8).write(to: state)
    #expect(Submission.of(root) == nil)
    #expect(Submission.of(root.appending(path: "01")) == nil)
}

@Test func onlyTheFolderAndItsParentAreSearched() throws {
    let root = try submission("M4K-V", notebooks: ["01": []])
    let deeper = root.appending(path: "01/skany")
    try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
    #expect(Submission.of(root.appending(path: "01"))?.isRoot == false)
    #expect(Submission.of(deeper) == nil)
}

// MARK: Boxes and export across notebooks

@Test @MainActor func eachNotebookKeepsItsOwnBoxesAndExportsOnlyWhenChanged() async throws {
    let root = try submission("M4K-V", notebooks: ["01": ["skan_001.png"], "nowy": ["skan_001.png"]])
    let store = Store()
    store.open(root)
    let size = CGSize(width: 40, height: 40)
    store.addBox(CGRect(x: 0, y: 0, width: 20, height: 20), on: "01/skan_001.png", imageSize: size)
    store.addBox(CGRect(x: 10, y: 10, width: 25, height: 25), on: "nowy/skan_001.png", imageSize: size)
    // The same file name in two notebooks, each in its own file.
    let first = try TrimsFile.load(from: root.appending(path: "01"))
    let new = try TrimsFile.load(from: root.appending(path: "nowy"))
    #expect(first.images["skan_001.png"]?.boxes.first?.width == 20)
    #expect(new.images["skan_001.png"]?.boxes.first?.width == 25)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: TrimsFile.fileName).path))

    #expect(await store.export())
    #expect(store.exportSummary?.notebooks == ["M4K-V-01", "nowy: nowy zeszyt"])
    for notebook in ["01", "nowy"] {
        let crops = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "\(notebook)/\(Exporter.folderName)").path)
        #expect(crops == ["skan_001_001.png"])
    }

    // Nothing changed: nothing exported. Then only the notebook with a moved box.
    #expect(await store.export())
    #expect(store.exportSummary?.notebooks == [])
    store.updateBox(store.boxes(for: "01/skan_001.png")[0].id, rect: CGRect(x: 5, y: 5, width: 20, height: 20), on: "01/skan_001.png", imageSize: size)
    // Tags do not change the crops.
    store.setPageTags(["szkic"], on: "nowy/skan_001.png")
    #expect(await store.export())
    #expect(store.exportSummary?.notebooks == ["M4K-V-01"])
    // A crop deleted by hand is cut again.
    try FileManager.default.removeItem(at: root.appending(path: "nowy/\(Exporter.folderName)/skan_001_001.png"))
    #expect(await store.export())
    #expect(store.exportSummary?.notebooks == ["nowy: nowy zeszyt"])
}

@Test @MainActor func aNotebookRenamedByPushKeepsTheSelection() async throws {
    let root = try submission("M4K-V", notebooks: ["01": ["a.png"], "nowy": ["b.png", "c.png"]])
    let store = Store()
    store.open(root)
    store.current = "nowy/c.png"
    store.addBox(CGRect(x: 0, y: 0, width: 20, height: 20), on: "nowy/c.png", imageSize: CGSize(width: 40, height: 40))
    #expect(await store.export())
    try FileManager.default.moveItem(at: root.appending(path: "nowy"), to: root.appending(path: "02"))
    store.reload()
    #expect(store.notebooks.map(\.name) == ["01", "02"])
    #expect(store.current == "02/c.png")
    #expect(store.boxes(for: "02/c.png").count == 1)
    // Its crops moved with it, so they are still up to date.
    #expect(!store.needsExport(store.notebooks[1]))
}

@Test @MainActor func boxesSavedJustAfterTheRenameGoToTheNewFolder() throws {
    let root = try submission("M4K-V", notebooks: ["nowy": ["b.png"]])
    let store = Store()
    store.open(root)
    try FileManager.default.moveItem(at: root.appending(path: "nowy"), to: root.appending(path: "02"))
    // The push renamed the folder before the app noticed; the save fails quietly instead of recreating nowy/.
    store.addBox(CGRect(x: 0, y: 0, width: 20, height: 20), on: "nowy/b.png", imageSize: CGSize(width: 40, height: 40))
    #expect(store.error == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "nowy").path))
    store.reload()
    #expect(try TrimsFile.load(from: root.appending(path: "02")).images["b.png"]?.boxes.count == 1)
}

// MARK: Tag suggestions

@Test @MainActor func suggestionsComeFromTheSubmissionThenOlderNotebookFiles() throws {
    let root = try submission("M4K-V", notebooks: ["01": ["a.png"]])
    try Data(#"[{"tag": "stary", "pages": 1}]"#.utf8).write(to: root.appending(path: "01/.copyisto-tags.json"))
    let store = Store()
    store.open(root)
    #expect(store.tagSuggestions == ["stary"])
    try Data(#"[{"tag": "z repozytorium", "pages": 5}]"#.utf8).write(to: root.appending(path: ".copyisto/tags.json"))
    store.reload()
    #expect(store.tagSuggestions == ["z repozytorium"])
    // A notebook opened on its own reads its parent's list.
    store.open(root.appending(path: "01"))
    #expect(store.tagSuggestions == ["z repozytorium"])
}

// MARK: The description as it applies

private var sample: [String: Any] { [
    "source": ["device_type": "scanner", "device": "Epson DS-70000", "dpi": 600],
    "tags": ["zeszyt a5"],
    "notebooks": [
        "01": [
            "note": "zeszyt zamoczony",
            "source": ["dpi": 1200],
            "tags": ["szkic"],
            "files": [
                "zdjecie_0003.jpg": ["source": ["device_type": "camera"], "tags": ["Kartka luźna"], "note": " nieokreślona "],
                "copyisto-trims.json": ["tags": ["plik trimmera"]],
            ],
        ]
    ],
] }

@Test func sourceIsInheritedFieldByField() {
    let meta = Description(json: sample).meta(of: "skan_001.png", in: "01")
    #expect(meta.source == Description.Source(deviceType: "scanner", device: "Epson DS-70000", dpi: 1200))
    #expect(meta.tags == ["zeszyt a5", "szkic"])
    // The notebook's note is about the notebook, not its files.
    #expect(meta.note == "")
    #expect(Description.label(meta.source) == "skaner Epson DS-70000, 1200 dpi")
}

@Test func anotherDeviceTypeStartsTheSourceOver() {
    let meta = Description(json: sample).meta(of: "zdjecie_0003.jpg", in: "01")
    // A phone photo does not get the scanner's model or dpi.
    #expect(meta.source == Description.Source(deviceType: "camera"))
    #expect(meta.tags == ["zeszyt a5", "szkic", "kartka luźna"])
    #expect(meta.note == "nieokreślona")
}

@Test func aNewNotebooksFilesGetOnlyTheSubmissionsPart() {
    let meta = Description(json: sample).meta(of: "skan_001.png", in: nil)
    #expect(meta.source.dpi == 600 && meta.tags == ["zeszyt a5"])
}

@Test func theTrimmerFilesOldNameIsTheSameFile() {
    let description = Description(json: sample)
    #expect(description.meta(of: TrimsFile.fileName, in: "01").tags.last == "plik trimmera")
    #expect(description.meta(of: "copyisto-trims.json", in: "01").tags.last == "plik trimmera")
}

// MARK: Editing the description

@Test @MainActor func editingKeepsWhatItDoesNotTouch() throws {
    var json = sample
    json["someday"] = ["unknown": true]
    var notebooks = json["notebooks"] as! [String: Any]
    notebooks["02"] = ["note": "nie ruszać", "future": 1]
    json["notebooks"] = notebooks
    let root = try submission("M4K-V", notebooks: ["01": ["skan_001.png"], "02": []], description: json)
    let store = Store()
    store.open(root)
    store.setDescription(.note, "  przekreślona  ", at: Description.file("skan_001.png", in: "01"))
    store.setDescription(.tags, ["  Polifonia ", "polifonia", ""], at: Description.file("skan_001.png", in: "01"))
    store.setDescription(.device, "  Pixel 8  ", at: Description.file("skan_001.png", in: "01"))
    store.setDescription(.dpi, 0, at: Description.file("skan_001.png", in: "01"))
    store.setDescription(.deviceType, "phone", at: Description.file("skan_001.png", in: "01"))

    let written = try readJSON(root.appending(path: ".copyisto/description.json"))
    #expect(Description.same(written["someday"], ["unknown": true]))
    #expect(Description.same(written["source"], sample["source"]))
    let parts = written["notebooks"] as! [String: Any]
    #expect(Description.same(parts["02"], ["future": 1, "note": "nie ruszać"]))
    let file = (parts["01"] as! [String: Any])["files"] as! [String: Any]
    #expect(Description.same(file["skan_001.png"], ["note": "przekreślona", "tags": ["polifonia"], "source": ["device": "Pixel 8"]]))

    // Emptied fields go, and so do the objects they leave empty.
    for field in [Description.Field.note, .tags, .device] {
        store.setDescription(field, field == .tags ? [String]() : "  ", at: Description.file("skan_001.png", in: "01"))
    }
    let files = (try readJSON(root.appending(path: ".copyisto/description.json"))["notebooks"] as! [String: Any])["01"] as! [String: Any]
    #expect(Description.same(files["files"], (sample["notebooks"] as! [String: Any])["01"].map { ($0 as! [String: Any])["files"] }!))
}

@Test func writtenAsTheCLIWritesIt() throws {
    let text = Description.format(["tags": ["a/b", "ż"], "source": ["dpi": 600, "device_type": "scanner"], "notebooks": [:] as [String: Any]])
    #expect(text == """
        {
          "notebooks": {},
          "source": {
            "device_type": "scanner",
            "dpi": 600
          },
          "tags": [
            "a/b",
            "ż"
          ]
        }
        """)
}

@Test func normalizedAsTheCLIParsesIt() {
    #expect(Description.stored(.deviceType, "camera") as? String == "camera")
    #expect(Description.stored(.deviceType, "phone") == nil)
    #expect(Description.stored(.device, String(repeating: "x", count: 101)) == nil)
    #expect(Description.stored(.dpi, 10000) as? Int == 10000)
    #expect(Description.stored(.dpi, 10001) == nil)
    #expect(Description.stored(.note, String(repeating: "x", count: 2100)).map { ($0 as! String).count } == 2000)
    let many = (1...25).map { "tag \($0)" }
    #expect((Description.stored(.tags, many) as? [String])?.count == 20)
}

@Test @MainActor func theFileIsReadAgainBeforeSaving() throws {
    let root = try submission("M4K-V", notebooks: ["01": ["skan_001.png"]], description: sample)
    let store = Store()
    store.open(root)
    let url = root.appending(path: ".copyisto/description.json")
    // A pull changes another field in the meantime: both changes stay.
    var json = sample
    json["tags"] = ["z serwera"]
    try Description(json: json).write(to: url)
    store.setDescription(.note, "moja", at: Description.file("skan_001.png", in: "01"))
    let written = Description(json: try readJSON(url))
    #expect(written.tags(at: Description.top) == ["z serwera"])
    #expect(written.note(at: Description.file("skan_001.png", in: "01")) == "moja")
    #expect(store.descriptionConflict == nil)
}

@Test @MainActor func theSameFieldChangedInTheFileIsAskedAbout() throws {
    let root = try submission("M4K-V", notebooks: ["01": ["skan_001.png"]], description: sample)
    let store = Store()
    store.open(root)
    let url = root.appending(path: ".copyisto/description.json")
    let level = Description.notebook("01")
    try Description(json: sample).setting("z pliku", at: level + ["note"]).write(to: url)
    store.setDescription(.note, "moja", at: level)
    let conflict = try #require(store.descriptionConflict)
    // Nothing written yet, and the app shows the file's value meanwhile.
    #expect(Description(json: try readJSON(url)).note(at: level) == "z pliku")
    #expect(store.description.note(at: level) == "z pliku")
    store.keepMine(conflict)
    #expect(Description(json: try readJSON(url)).note(at: level) == "moja")
}

@Test @MainActor func aNewNotebookHasNoPartToEdit() throws {
    let root = try submission("M4K-V", notebooks: ["nowy": ["a.png"]], description: sample)
    let store = Store()
    store.open(root)
    #expect(store.descriptionLevel(of: "nowy/a.png") == nil)
    #expect(store.descriptionLevel(of: store.notebooks[0]) == nil)
    store.setFileNote("cokolwiek", on: "nowy/a.png")
    #expect(Description.same(try readJSON(root.appending(path: ".copyisto/description.json")), sample))
}

// MARK: Limits with the description counted in

@Test @MainActor func cropLimitsCountTheDescription() throws {
    var json = sample
    json["tags"] = (1...15).map { "opis \($0)" }
    let root = try submission("M4K-V", notebooks: ["01": ["skan_001.png"]], description: json)
    let store = Store()
    store.open(root)
    let image = "01/skan_001.png"
    store.addBox(CGRect(x: 0, y: 0, width: 20, height: 20), on: image, imageSize: CGSize(width: 40, height: 40))
    let id = store.boxes(for: image)[0].id
    store.setBoxTags((1...5).map { "ramka \($0)" }, box: id, on: image)
    // 15 from the submission, "szkic" from the notebook, 5 on the box.
    #expect(store.cropTags(box: store.boxes(for: image)[0], on: image).count == 21)
    #expect(store.cropTags(box: store.boxes(for: image)[0], on: image).prefix(2) == ["opis 1", "opis 2"])

    store.setFileNote(String(repeating: "p", count: 1500), on: image)
    store.setBoxNote(String(repeating: "r", count: 1000), box: id, on: image)
    // The file's note, a newline, then what is left for the box.
    #expect(store.boxes(for: image)[0].note?.count == 499)
    #expect(store.cropNote(box: store.boxes(for: image)[0], on: image).utf16.count == 2000)
}

// MARK: Helpers

/// A submission's folder as `copyisto init` leaves it, with tiny pages in its notebooks.
private func submission(_ code: String, notebooks: [String: [String]], description: [String: Any]? = nil) throws -> URL {
    let root = try temporaryFolder()
    let state = root.appending(path: ".copyisto")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data(#"{"server": "http://127.0.0.1:8788", "code": "\#(code)", "notebooks": {}}"#.utf8).write(to: state.appending(path: "state.json"))
    if let description { try Description(json: description).write(to: state.appending(path: "description.json")) }
    for (name, pages) in notebooks {
        let folder = root.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for page in pages {
            try writePNG(width: 40, height: 40, to: folder.appending(path: page)) { x, _ in x < 20 ? (255, 0, 0) : (0, 0, 255) }
        }
    }
    return root
}

private func readJSON(_ url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

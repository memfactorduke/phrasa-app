import Foundation
import PhrasaDomain

extension ScriptDocument {
    static let welcome = ScriptDocument(
        title: "Welcome to Phrasa",
        body: """
        Welcome to Phrasa. This is a sample script, so you can try the prompter right now.

        Here is how it works on Mac. Open Present to start a full-screen speed reader. Use Space to play or pause, B for blackout, and the arrow keys to change speed or nudge the text. When you would rather write, stay in the library and editor — every change autosaves offline.

        When you are ready, write your own script. Type it, paste it, or import a text, Markdown, or PDF file. Export a single script or back up the whole library from the File menu.

        That is really all there is to it. Delete this sample whenever you like, and make something of your own. Now take a breath, look up, and start talking. The words will be right here, waiting for you.
        """,
        tags: ["sample"],
        outline: [
            OutlinePoint(text: "What Phrasa does", note: "A calm, local-first teleprompter for Mac."),
            OutlinePoint(text: "Speed prompting", note: "Full-screen reader with keyboard and clicker controls."),
            OutlinePoint(text: "Bring in your script", note: "Type, paste, or import TXT, Markdown, or PDF."),
            OutlinePoint(text: "Make it your own", note: "Delete this sample and step up to the prompter.")
        ]
    )
}

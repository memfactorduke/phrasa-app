import Foundation

extension ScriptDocument {
    static let welcome = ScriptDocument(
        title: "Welcome to Phrasa",
        body: """
        Welcome to Phrasa. This is a sample script, so you can try the prompter right now.

        Here is how it works. Start speaking, and the prompter listens to your voice and keeps the line you are reading centered on the screen. You can pause, ad-lib, or stumble, and it follows along. If you would rather not use your voice, switch to speed mode for a steady, adjustable crawl.

        When you are ready, write your own script. Type it, paste it, or import a file. Set a target time, and the pacing tools will tell you whether you are running ahead or behind.

        That is really all there is to it. Delete this sample whenever you like, and make something of your own. Now take a breath, look up, and start talking. The words will be right here, waiting for you.
        """,
        tags: ["sample"],
        outline: [
            OutlinePoint(text: "What Phrasa does", note: "A voice-following teleprompter that keeps the line you are reading centered."),
            OutlinePoint(text: "Two reading modes", note: "Voice follows your speech; speed is a steady, adjustable crawl."),
            OutlinePoint(text: "Bring in your script", note: "Type, paste, or import it, then set a target time."),
            OutlinePoint(text: "Make it your own", note: "Delete this sample and step up to the prompter.")
        ]
    )
}

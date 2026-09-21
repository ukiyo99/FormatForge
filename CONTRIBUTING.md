# Contributing to FormatForge

Thanks for wanting to help. This is a small project, so the process is informal
— but there are a few things worth knowing before you dive in.

## Getting set up

```sh
git clone https://github.com/yourname/formatforge.git
cd formatforge
./build.sh
./test.sh
```

`build.sh` takes about 20 seconds. `test.sh` takes a couple of minutes because
it actually converts things and checks the results.

You'll want ffmpeg for development:

```sh
brew install ffmpeg p7zip webp
```

## Before you open a pull request

Run `./test.sh`. It should end with `全部通过` (all passed). If it doesn't,
please fix that first — the tests exist because they've caught real bugs,
several of which only showed up on specific files.

A few guidelines:

- **Match the surrounding style.** The codebase has a consistent voice: doc
  comments explain *why*, not *what*. If a line needs a comment to explain what
  it does, it probably needs rewriting instead.
- **Keep the comments that are already there.** They record decisions and
  mistakes that aren't obvious from the code.
- **No new dependencies.** The app has zero third-party Swift packages and I'd
  like to keep it that way. System frameworks can do more than you'd expect.
- **Test on real files.** Synthetic test patterns miss things that real media
  catches.

## Adding a tool

Tools live in `Sources/Features/` and describe themselves. Here's the shape:

```swift
enum MyTool {
    static let tool = Tool(
        id: "video.mytool",
        name: L("video.mytool.name"),
        summary: L("video.mytool.summary"),
        symbol: "wand.and.stars",        // any SF Symbol
        category: .video,
        accepts: ["mp4", "mov"],          // lowercase extensions
        actionTitle: L("video.mytool.action"),
        parameters: [
            .slider("crf", L("video.mytool.param.crf.label"),
                    default: 23, min: 0, max: 51, step: 1,
                    hint: L("video.mytool.param.crf.hint")),
            .picker("scale", L("..."), default: "original",
                    options: VideoOptions.scale),
            .toggle("hardware", L("..."), default: false),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let duration = await MediaProbe.duration(input)
                // ... build ffmpeg arguments ...
                let output = context.output(index: index, ext: "mp4", suffix: "_out")
                outputs.append(try await VideoSupport.encode(
                    context, input: input, output: output,
                    arguments: args, duration: duration))
            }
            return outputs
        }
    )
}
```

Then add it to `ToolRegistry.all`. The UI builds itself from the declaration.

Things worth knowing:

- **`context.checkCancelled()`** — call this inside loops so the Cancel button
  works on long jobs.
- **`context.output(index:ext:suffix:)`** — handles name collisions and the
  user's output-folder preference. Don't construct paths yourself.
- **Conditional options** — use `.visibleWhen(.equals("mode", "size"))` so the
  form only shows what's relevant.
- **Multi-input tools** — pass `inputArguments:` to `VideoSupport.encode`
  instead of letting it add `-i` for you, or your input indices will shift.
- **New strings** — use `L("some.key")` and add the key to
  `Resources/i18n/en.json`. Run `./test.sh` and it'll tell you if a language is
  missing it.

### If your tool only reads files

Then it shouldn't be a converter at all. Implement `FileInspector` instead and
register it as an inspector — no button, no queue, no output folder. See
`Sources/Features/Inspect/` for examples.

## Adding a language

1. Copy `Resources/i18n/en.json` to `Resources/i18n/<code>.json`
2. Translate the **values**; leave the keys exactly as they are
3. Add the language to the `Language` enum in
   `Sources/Core/Localization.swift`

```swift
case portuguese = "pt"
```

Then add its display name to `nativeName` (in that language) and `englishName`:

```swift
case .portuguese: return "Português"      // nativeName
case .portuguese: return "Portuguese"     // englishName
```

`./test.sh` verifies that every language has the same key set as English, so a
missed string fails rather than silently showing English.

### A note on language names

`nativeName` is deliberately **not** translated. A German user looking for
Chinese should see 简体中文, not "Chinesisch" — the whole point is that you can
find your own language in a list you might not be able to read.

## Reporting bugs

Useful bug reports include:

- What you did, what you expected, what happened
- The macOS version and whether you're on Apple silicon or Intel
- The file that caused it, if you can share it (or its properties — codec,
  resolution, duration)
- **The log.** The app has a Log tab showing the exact ffmpeg command it ran.
  Copying that makes most issues diagnosable immediately.

## Things I'd especially like help with

- **A better icon.** The current one is a placeholder I made in ten minutes.
- **Intel Mac testing.** I only have Apple silicon, so the x86_64 slice builds
  and links but has never been benchmarked.
- **Notarisation.** Right now the app is ad-hoc signed, which means users have
  to right-click → Open on first launch. That needs a paid Apple developer
  account, which I don't have.
- **Windows and Linux ports.** The core logic is fairly portable; the UI is
  SwiftUI, which isn't.

## Licence

By contributing, you agree your work is licensed under the MIT licence. See
[LICENSE](LICENSE).

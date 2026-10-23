# cb-reapack

ReaPack repository for **cb console**, a REAPER window that sends the open project, or the
selected MIDI item, to a language model you run yourself, and shows the answer (REAPER stays
usable while a request runs), and for two JSFX: **cb pump** and **cb 808**.

## cb console

The package `cb_console.lua` (category LLM Bridge) adds three actions:

- **cb_console.lua** opens the window, or closes it when it is open.
- **cb_narrator.lua** opens it on the Narrator tab. Run describes the project: tempo, tracks,
  their FX and items, markers and regions.
- **cb_midi_variation.lua** opens it on the MIDI variation tab. Run adds one variation of the
  selected MIDI item to that item as a new take; the original take is kept.

### Requirements

- Windows (tested on Windows 11). The bridge runs in a hidden console window through
  `conhost.exe --headless`.
- PowerShell 7 at its default path, `C:\Program Files\PowerShell\7\pwsh.exe`
  (`winget install Microsoft.PowerShell`).
- ReaImGui 0.10 or newer, from the ReaTeam Extensions repository that ReaPack lists by default.
- An OpenAI-compatible chat completions endpoint, for example [Ollama](https://ollama.com) on the
  same machine.

### Install

1. In REAPER: Extensions > ReaPack > Import repositories, and paste
   `https://github.com/coltonbearden/cb-reapack/raw/main/index.xml`
2. Extensions > ReaPack > Browse packages, install `cb console: LLM narrator and MIDI variation`.
3. Install ReaImGui the same way if it is not installed yet.

The files land in `<REAPER resource path>\Scripts\cb-reapack\LLM Bridge\` (Options > Show REAPER
resource path in explorer/finder).

### Set up the model

The package ships `bridge\bridge.config.example.json`, which points at Ollama on this machine:

    {
      "baseUrl": "http://localhost:11434/v1",
      "model": "gpt-oss:20b",
      "models": ["gpt-oss:20b"],
      ...
    }

With Ollama installed, `ollama pull gpt-oss:20b` is all it needs. To use another endpoint or model,
copy `bridge.config.example.json` to `bridge.config.json` in the same folder and edit the copy:
`baseUrl` (the bridge appends `/chat/completions`), `model`, and `models` (the models the window
offers). The bridge reads `bridge.config.json` when it exists and the example otherwise. ReaPack
never updates or removes your copy.

If the endpoint needs an API key, put it alone in the file `%LOCALAPPDATA%\reaper-bridge\token`;
it is sent as a Bearer token to that endpoint only, and never logged.

### Claude models (optional)

cb console can also ask Anthropic's Claude models, billed to your own API key from the
[Claude Console](https://platform.claude.com/). Nothing about them is switched on by the package:
the example config lists Ollama only.

1. Store your key. In a PowerShell 7 window:

       pwsh -NoProfile -File "<REAPER resource path>\Scripts\cb-reapack\LLM Bridge\bridge\Set-BridgeKey.ps1"

   It asks for the key at a hidden prompt and keeps it encrypted to your Windows user (DPAPI) in
   `%LOCALAPPDATA%\reaper-bridge\anthropic.key`, then checks it against the API's model list,
   which costs nothing. `-Status` says whether a key is stored, `-Probe` checks it again, `-Remove`
   deletes it, and `-FromStdin` reads it from a password manager's command line instead of the
   prompt. The key is never printed, logged or written into a job folder.
2. List the models in your own `bridge.config.json`. A model entry may be an object that names its
   provider and carries its own settings:

       {
         "providers": {
           "ollama": { "baseUrl": "http://localhost:11434/v1" },
           "anthropic": {}
         },
         "model": "gpt-oss:20b",
         "models": [
           "gpt-oss:20b",
           { "id": "claude-sonnet-5-5", "provider": "anthropic", "reasoningEffort": "high",
             "maxTokens": 16000, "price": { "inputPerMTok": 2, "outputPerMTok": 10 } }
         ],
         ...the rest as in the example
       }

   Set `model` to a Claude model's id to make it the default.

   - `reasoningEffort` (low, medium, high) becomes Claude's effort setting; the window's Reasoning
     effort picker marks each model's own default.
   - `maxTokens` counts Claude's thinking too, so give it room (16000 is plenty here).
   - `httpTimeoutSeconds` is how long the bridge waits for that model; the window gives up 10 s
     later. Models without one wait 50 s, as before. In the author's measurements (2026-10-22,
     567 runs) Claude Opus, Sonnet and Haiku 5.5 always answered within 31 s, so they need none; a
     large local model may.
   - `price` (USD per million input and output tokens, from
     [Anthropic's pricing page](https://platform.claude.com/docs/en/about-claude/pricing)) is used
     only for the cost estimate.
   - `actions` overrides any of these for one action, as the top-level `actions` does.
   - `temperature` is not sent to Claude models.
   - A top-level `baseUrl`, as in the example, still works for Ollama.

The window lists a Claude model only while a key is stored. If a Claude model is picked anyway (as
the default model, say) with no key stored, the status line says so and nothing is sent.

### What is sent and kept

A request carries a summary of the project (narrator) or the notes of the selected MIDI item
(variation), plus the instruction you type. With a Claude model the same request goes to Anthropic's
API under your key. Each request is a folder under `%LOCALAPPDATA%\reaper-bridge\jobs\` holding
`request.json`, `response.json` and `bridge.log`; the response and the log record the provider, the
tokens and an estimated cost, which the window's log shows too. These folders are kept so a result
can be looked at again; delete them whenever you like.

## JSFX

Two plain JS effects. They need nothing else and run on every platform REAPER runs on.

- **cb pump** (`cb_pump.jsfx`, category Dynamics): a tempo-synced volume shaper, the house and EDM
  "pump" without sidechain routing. The gain reaches its minimum exactly on the beat and comes
  back over the release; rate from 1/16T to 1 bar, four shapes, or one dip per MIDI note.
- **cb 808** (`cb_808.jsfx`, category Instruments): a mono 808 and sub-bass instrument with a
  pitch drop at the attack, glide, drive and a lowpass tone control. Its tail ends in exact
  silence.

Install them from Extensions > ReaPack > Browse packages as above. They land in
`<REAPER resource path>\Effects\cb-reapack\Dynamics\` and `Effects\cb-reapack\Instruments\`, and
show in the FX browser as `JS: cb pump` and `JS: cb 808`.

## Issues

Report problems at https://github.com/coltonbearden/cb-reapack/issues

## Licence

MIT, see `LICENSE`.

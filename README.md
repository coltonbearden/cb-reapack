# cb-reapack

ReaPack repository for **cb console**: a REAPER window that sends the open project, or the
selected MIDI item, to a language model you run yourself, and shows the answer. REAPER stays
usable while a request runs.

The package `cb_console.lua` (category LLM Bridge) adds three actions:

- **cb_console.lua** opens the window, or closes it when it is open.
- **cb_narrator.lua** opens it on the Narrator tab. Run describes the project: tempo, tracks,
  their FX and items, markers and regions.
- **cb_midi_variation.lua** opens it on the MIDI variation tab. Run adds one variation of the
  selected MIDI item to that item as a new take; the original take is kept.

## Requirements

- Windows (tested on Windows 11). The bridge runs in a hidden console window through
  `conhost.exe --headless`.
- PowerShell 7 at its default path, `C:\Program Files\PowerShell\7\pwsh.exe`
  (`winget install Microsoft.PowerShell`).
- ReaImGui 0.10 or newer, from the ReaTeam Extensions repository that ReaPack lists by default.
- An OpenAI-compatible chat completions endpoint, for example [Ollama](https://ollama.com) on the
  same machine.

## Install

1. In REAPER: Extensions > ReaPack > Import repositories, and paste
   `https://github.com/coltonbearden/cb-reapack/raw/main/index.xml`
2. Extensions > ReaPack > Browse packages, install `cb console: LLM narrator and MIDI variation`.
3. Install ReaImGui the same way if it is not installed yet.

The files land in `<REAPER resource path>\Scripts\cb-reapack\LLM Bridge\` (Options > Show REAPER
resource path in explorer/finder).

## Set up the model

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
it is sent as a Bearer token and never logged.

## What is sent and kept

A request carries a summary of the project (narrator) or the notes of the selected MIDI item
(variation), plus the instruction you type. Each request is a folder under
`%LOCALAPPDATA%\reaper-bridge\jobs\` holding `request.json`, `response.json` and `bridge.log`. These
folders are kept so a result can be looked at again; delete them whenever you like.

## Issues

Report problems at https://github.com/coltonbearden/cb-reapack/issues

## Licence

MIT, see `LICENSE`.

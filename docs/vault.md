# Vault agent registration

Vault restores built-in agent sessions and can also read custom agent registrations from
`cmux.json`. Registrations define how cmux detects a running terminal process, where the
agent's native session id comes from, and which command resumes that session.

## Select agents for history

In Vault, open the ellipsis menu and choose **Agent sources**. Check the agents
whose history you want to read and search. **All agents (default)** restores the
default selection, including future agents; **No agents** stops reading all agent
history. Changes apply dynamically and are saved in the global configuration.

Set `vault.enabledAgents` in the global `~/.config/cmux/cmux.json` to select
which agents Vault reads, indexes, and searches:

```jsonc
{
  "vault": {
    "enabledAgents": ["omp"]
  }
}
```

This example keeps OMP history enabled and stops reading history from every other
agent. Omit `enabledAgents` to enable all agents, including future registrations;
set it to `[]` to disable all agent history. IDs match exactly and preserve case,
including custom agent IDs. The `agents` key is optional when selecting history.
Project-local configuration can add or override registrations, but cannot change
the global history selection.

The same selection can be changed from the CLI:

```sh
cmux config set vault.enabledAgents '["omp"]'
cmux config set vault.enabledAgents '[]'
cmux config unset vault.enabledAgents
```

These commands select only OMP, select no agents, and restore all agents,
respectively. They change only the history selection, not `vault.agents`
registrations.

This is a stop-reading policy, not a display-only filter: unselected agents'
history sources are not scanned or parsed, and their history is not searchable.
It does not delete the agents' original session files or change process detection,
running-session registration, hooks, or authentication. In particular, selecting
only `omp` leaves OMP registration and session behavior unchanged.

An existing unreadable or invalid global configuration stops history reads until
it is corrected. Queries discard results when that file changes, even if the
selected IDs are changed back while a read is in flight.

## Agent registrations

Pi, OMP, Campfire, Amp, Antigravity, Grok, Kimi Code, and Hermes Agent are
registered by default. The following partial example shows the Pi, OMP, and Campfire
registrations:

```jsonc
{
  "vault": {
    "agents": [
      {
        "id": "pi",
        "name": "Pi",
        "detect": {
          "processName": "pi",
          "argvContains": "pi"
        },
        "sessionIdSource": { "type": "piSessionFile" },
        "resumeCommand": "{{executable}} --session {{sessionId}}",
        "forkCommand": "{{executable}} --fork {{sessionId}}",
        "cwd": "preserve",
        "sessionDirectory": "~/.pi/agent/sessions"
      },
      {
        "id": "omp",
        "name": "OMP",
        "detect": {
          "processName": "omp"
        },
        "sessionIdSource": { "type": "piSessionFile" },
        "resumeCommand": "{{executable}} --session {{sessionId}}",
        "forkCommand": "{{executable}} --fork {{sessionId}}",
        "cwd": "preserve",
        "sessionDirectory": "~/.omp/agent/sessions"
      },
      {
        "id": "campfire",
        "name": "Campfire",
        "detect": {
          "processName": "campfire"
        },
        "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
        "resumeCommand": "{{executable}} --session {{sessionId}}",
        "cwd": "preserve",
        "sessionDirectory": "~/.campfire/agent/sessions"
      }
    ]
  }
}
```

For a generic agent that exposes the current session as an argv option:

```jsonc
{
  "vault": {
    "agents": [
      {
        "id": "my-agent",
        "name": "My Agent",
        "iconAssetName": "AgentIcons/MyAgent",
        "detect": {
          "processName": "my-agent"
        },
        "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
        "resumeCommand": "my-agent --session {{sessionId}}",
        "forkCommand": "my-agent --session {{sessionId}} --fork",
        "cwd": "preserve",
        "sessionDirectory": "~/.my-agent/sessions"
      }
    ]
  }
}
```

Supported `resumeCommand` placeholders are `{{sessionId}}`, `{{sessionPath}}`,
`{{executable}}`, `{{cwd}}`, and `{{sessionDir}}`. Pi uses `pi --session <id-or-path>`
instead of `pi --continue` so Vault reopens the exact saved session.
OMP accepts `--session`, `--resume`, and `-r` for existing sessions; Vault emits `omp --session <id-or-path>` so relaunch reopens the exact saved OMP session.

Campfire resumes with `campfire --session <id>`; only the driver's host session is restorable (joiners are ephemeral views), and resuming restores the conversation in a fresh collaborative session with a new invite link.

`resumeCommand` must include either `{{sessionId}}` or `{{sessionPath}}`, for
example `pi --session {{sessionId}}`.

`forkCommand` is optional and uses the same placeholders as `resumeCommand`. It
is the argv template for forking (branching) a session into a new copy, for
example `{{executable}} --session {{sessionId}} --fork`. Provide it only when the
agent supports forking; when omitted, the right-click **Fork Conversation** item
stays hidden for that agent (resume still works via `resumeCommand`). Of the built-in
agents, only Pi and OMP ship with `{{executable}} --fork {{sessionId}}`.

`iconAssetName` is optional. When omitted, Vault uses a neutral system icon for
registered agents instead of reusing another agent's brand mark.

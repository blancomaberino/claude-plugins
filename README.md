# claude-plugins

A personal [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins). Each top-level directory is one plugin; the marketplace manifest lives in [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json).

## Setup

Register the marketplace once per machine (inside any Claude Code session):

```
/plugin marketplace add blancomaberino/claude-plugins
```

Or, from a local clone:

```
/plugin marketplace add ~/Sites/plans/claude-plugins
```

Then install any plugin from the table below with:

```
/plugin install <plugin-name>@marce-plugins
```

Installed plugins are managed with `/plugin` (enable, disable, uninstall, update). To pick up new versions after the repo changes, run `/plugin marketplace update marce-plugins`.

## Plugins

| Plugin | Description | Install |
|---|---|---|
| [codehare](codehare/) | Self-hosted CodeRabbit-equivalent PR review — tool-grounded LLM review, walkthrough summary, and an enforced pre-PR approval gate. | `/plugin install codehare@marce-plugins` |

Each plugin's own README documents its usage, requirements, and configuration.

## Adding a new plugin

1. Create a new top-level directory: `my-plugin/` with a `.claude-plugin/plugin.json` (`name`, `version`, `description`, `author`).
2. Add its content: `skills/`, `hooks/hooks.json`, `agents/`, `commands/` — whatever the plugin provides. Reference bundled files from hooks via `${CLAUDE_PLUGIN_ROOT}`.
3. Register it in `.claude-plugin/marketplace.json` under `plugins` (`name`, `source: "./my-plugin"`, `description`).
4. Add a row to the table above and a README inside the plugin directory.
5. Commit and push; consumers pick it up with `/plugin marketplace update marce-plugins`.

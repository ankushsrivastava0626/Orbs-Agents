#!/usr/bin/env python3
"""An orb designed in CUE Studio: read its exported folder and say how to launch it.

  orb_agent.py <slug> <out-prompt-file>   -> JSON {cmd, model, args: [...], cwd}

The folder ~/.claude/voice/agents/<slug>/ (written by CUE Studio's "Run as orb") holds:
  agent.json   {"name", "engine": "claude"|"codex", "model", "tools": [...], "cwd"?}
  prompt.md    the agent's own system prompt (compiled by the studio)
  mcp.json     optional: its MCP servers, in Claude Code's {"mcpServers": {...}} shape
  plugin/      optional: its skills, as a Claude Code plugin (plugin/skills/<name>/SKILL.md)
The orb's prompt is Joe's voice rules followed by the agent's own prompt; its tools are exactly the designed ones
(the voice tools — speak — always stay, they come from the voice MCP server)."""
import json, os, shlex, sys

V = os.path.expanduser("~/.claude/voice")


def main():
    slug, out = sys.argv[1], sys.argv[2]
    d = os.path.join(V, "agents", slug)
    a = json.load(open(os.path.join(d, "agent.json")))
    if a.get("engine", "claude") != "claude":
        raise SystemExit("codex agents run through the Codex voice server, not this launcher")
    model = (a.get("model") or "").strip()
    # OpenRouter ids look like vendor/model (z-ai/glm-5.3-flash); Claude's own are claude-…
    cmd = "claude-openrouter" if "/" in model else "claude"
    with open(out, "w") as f:
        f.write(open(os.path.join(V, "voice-system-prompt.md")).read().rstrip() + "\n\n")
        f.write("# The agent you are\n\nEverything below was designed for you. Follow it; the voice rules above "
                "still decide how you speak.\n\n" + open(os.path.join(d, "prompt.md")).read().strip() + "\n")
    tools = list(a.get("tools") or [])
    plugin = os.path.join(d, "plugin")
    if os.path.isdir(plugin) and "Skill" not in tools: tools.append("Skill")   # its skills need the Skill tool
    # Only what was designed: no user settings (their plugins, skills and MCP servers), no global MCP servers.
    # The orb's hooks and permission mode, which normally come from user settings, are given back explicitly.
    args = ["--tools", ",".join(tools),                              # empty = no built-in tools at all
            "--setting-sources", "project,local", "--strict-mcp-config", "--permission-mode", "auto",
            "--settings", os.path.join(V, "voice-hooks.json")]
    if os.path.exists(os.path.join(d, "mcp.json")): args += ["--mcp-config", os.path.join(d, "mcp.json")]
    if os.path.isdir(plugin): args += ["--plugin-dir", plugin]
    print(json.dumps({"cmd": cmd, "model": model, "args": " ".join(shlex.quote(x) for x in args),
                      "cwd": os.path.expanduser(a.get("cwd") or "")}))


if __name__ == "__main__":
    main()

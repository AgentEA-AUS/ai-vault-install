# Use your AI Vault with Codex (OpenAI)

Your AI Vault already works with **Claude Desktop** via the AI-Vault extension.
This page connects the same vault to **Codex** — OpenAI's AI assistant that
runs on your computer (in the terminal, or inside VS Code).

> **Why not ChatGPT itself?** The ChatGPT app can only talk to servers on the
> internet — by OpenAI's design it cannot read anything on your own computer.
> Your vault is private and stays off the internet, so ChatGPT can't reach it.
> Codex is OpenAI's tool that CAN work with what's on your machine.

## What you need
- Your AI Vault already installed (the folder named `AI-Vault` in your home folder)
- **Node.js LTS** — free, from nodejs.org (click the big green button, install with defaults)
- A ChatGPT account (Codex signs in with it)

## Set up Codex (one time, ~5 minutes)

**1.** Install Codex. Open PowerShell (Windows) or Terminal (Mac) and run:
```
npm install -g @openai/codex
```

**2.** Sign in — run `codex` and follow the sign-in prompt, then quit it (Ctrl+C).

**3.** Download the vault connector — one file:
`https://raw.githubusercontent.com/AgentEA-AUS/ai-vault-install/main/vault-server.cjs`
Save it somewhere permanent, e.g. a folder called `AI-Vault-server` in your home folder.

**4.** Tell Codex about your vault — one command:

*Windows (PowerShell — replace YOURNAME twice):*
```
codex mcp add business_vault --env VAULT_PATH=C:\Users\YOURNAME\AI-Vault -- node C:\Users\YOURNAME\AI-Vault-server\vault-server.cjs
```

*Mac:*
```
codex mcp add business_vault --env VAULT_PATH=$HOME/AI-Vault -- node $HOME/AI-Vault-server/vault-server.cjs
```

**5.** Check it took: `codex mcp list` should show `business_vault`.

**6.** Use it — run `codex` and ask a business question, e.g.
*"Search the business vault: how do we complete the monthly statement?"*

## Using it inside VS Code instead
Install the **Codex** extension from the VS Code marketplace, sign in, then:
gear menu → **MCP settings → Open config.toml** — the `business_vault` entry
added in step 4 is already there (both surfaces share one config). Ask the same
questions in the Codex panel.

## Rules the AI follows (built in)
The connector is read-only — Codex can search and read your business knowledge
but can never change or delete it. It's told to always search before answering,
cite which note it used, and say so when the vault has no answer.

---
*AgentEA — AI Infrastructure. Questions? Contact AgentEA.*

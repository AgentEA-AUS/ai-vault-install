# AI Vault — setup instructions for an AI assistant

**You are helping a non-technical person set up their AI Vault.** Be friendly, tell
them what you're doing in plain English, and don't assume they know any of this.

Your job is small: **run one command, exactly as they gave it to you.** Everything
else in this file is context so you can explain things and handle problems.

---

## What you must do

1. The person will give you a **personal invite line**. It starts with `powershell`
   (on Windows) or `bash <(curl ...)` (on Mac or Linux). It contains a one-time code.

2. **Run that line exactly as-is.** Do not rewrite it, do not "improve" it, do not
   split it up, do not change any flag. It has already been tested on Windows, macOS
   and Linux. If you modify it, it will fail or enrol the wrong person.

3. It takes a few minutes. There is a large download in the middle (about 110 MB on
   Windows). Let it finish. Show them the output as it goes so they can see progress.

4. When it prints **`DONE — your vault is connected`**, tell them:
   - If it says it connected **Claude Desktop**: they must **quit Claude completely
     and open it again** before it will work.
   - If it says it connected **Codex**: nothing more to do.

5. Tell them to ask a question about their business, for example
   *"How do we complete the monthly statement?"*

---

## What you must NOT do

- **Do not install Claude, Codex, Node.js, or anything else.** If neither Claude
  Desktop nor Codex is on the machine, the installer will say so. Tell the person to
  install Claude from **claude.ai/download** and then run the same line again. That's it.
- **Do not edit any config files yourself.** The installer does that safely, and it
  backs up the existing file first.
- **Do not paste their invite code anywhere else**, or into any other tool.
- **Do not run the line twice at the same time.** Running it again later is safe.

---

## What the command actually does (so you can explain it)

- Downloads a small sync program and connects this computer to the person's **own
  private server**. Nothing is uploaded to any cloud, and nothing is exposed to the
  internet.
- Copies their business vault (a folder of notes) to `AI-Vault` in their home folder.
  It stays up to date automatically, in both directions.
- Downloads a **connector** (an MCP server) and adds **one entry** to Claude's or
  Codex's existing list of tools, so the AI can read that folder.
- It does **not** touch `CLAUDE.md`, `AGENTS.md`, global instructions, or any skills,
  and it does not install plugins.

---

## If something goes wrong

Every failure message ends with *"call AgentEA and read them this message."* If you
hit one, show the person the exact message and tell them to send it to AgentEA.

Common ones and what they mean:

| Message | What it means | What to do |
|---|---|---|
| `We couldn't find Claude or Codex on this computer` | Neither AI app is installed | Have them install Claude from claude.ai/download, then run the same line again |
| `The vault did not arrive. Your invite may have expired or already been used` | The one-time code is spent or older than 7 days | Ask AgentEA for a fresh invite line |
| `There is already a folder at ...AI-Vault that has other files in it` | Something unrelated is in the way | Ask them to rename that folder, then run the line again |
| `Could not reach the download site` | No internet, or a firewall is blocking it | Check the connection and run the line again |

Re-running the line is always safe. It skips whatever is already done.

---

## Undoing it

If they ever want it removed:

- **Windows:** `powershell -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/AgentEA-AUS/ai-vault-install/main/install.ps1'))) -Uninstall"`
- **Mac / Linux:** `bash <(curl -fsSL https://raw.githubusercontent.com/AgentEA-AUS/ai-vault-install/main/install.sh) --uninstall`

This removes the connector and the sync program, takes our entry back out of the AI
app's settings, and **leaves their vault folder alone**.

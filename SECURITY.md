# Security Policy

## Threat model

Mancia sends the text you select (and any instruction you type) to the GitHub
Copilot CLI and pastes the result back into the frontmost app. A few properties
shape what is and isn't defended:

- **The selected text is untrusted.** It may be an email, web page, or message
  authored by someone else and can contain embedded "instructions" (indirect
  prompt injection). Mancia fences the instruction and the input text with an
  unguessable per-request nonce (`PromptDelimiter`) and instructs the model to
  treat the input strictly as data, so injected text can't forge a delimiter or
  hijack the edit. Because output is user-visible and undoable (⌘Z / version
  navigation), the residual risk is a bad *edit*, not code execution. A
  whole-document replacement additionally pauses for explicit confirmation
  before it overwrites the document (on by default), so an injected or runaway
  result can't silently replace everything.
- **The provider runs sandboxed.** Completions run with all agent tools disabled
  (`--available-tools=`), no custom instructions, and an empty temp working
  directory, with the prompt passed as a single argument (no shell). The model
  cannot read files, run commands, or reach a repository through this path. A
  unit test enforces that tools stay disabled.
- **Input is bounded.** `PromptGuard` rejects empty or oversized instructions
  and selections before a request is made, to limit runaway cost/latency.
- **The instruction field is trusted to the operator.** Mancia is a single-user
  local utility; the person typing already controls the machine and the
  authenticated `copilot` binary. Mancia therefore does not attempt to "filter"
  or classify what you ask for — that would be bypassable and out of scope.
- **Out of scope:** a malicious local user with access to your account, a
  compromised `copilot` binary, and what GitHub Copilot does with prompts server
  side (see GitHub's own privacy/terms).

If you find a security issue in Mancia, please do not open a public issue with
exploit details.

Use GitHub private vulnerability reporting if it is available. Otherwise,
contact the maintainer privately; if there is no private channel, open an issue
asking for a security contact without including exploit details.

Include:

- A short description of the issue.
- Steps to reproduce it.
- The macOS version and Mancia version or commit tested.
- Any impact on pasteboard contents, Accessibility permissions, or provider
  command execution.

Mancia is a small project, so response times are best-effort.

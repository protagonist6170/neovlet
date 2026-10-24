# Terminology

Use these terms consistently in code discussions and documentation. They distinguish
what Neovlet manages from the editor and terminal applications around it.

**Owned session** — The Neovim editing session created and managed by Neovlet. It is
associated with one owned Ghostty terminal. A manually started Neovim instance is
outside this ownership boundary.

**Owned terminal** — The Ghostty terminal surface created to host the owned session.
It may occupy a tab inside a window. It is distinct from a Neovim tab and from the
Ghostty application as a whole.

**Open request** — One explicit action asking Neovlet to open a batch of files or,
when no files are supplied, to show the editing session. A batch is one request;
an initialization notification is not a request.

**Session registration** — The persisted record identifying the owned session and
its terminal association, used to verify and recover a surviving session after the
manager restarts. It stores neither buffer contents nor a delivery queue.

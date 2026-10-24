# Connect the folder to an AI assistant

Squidpal only writes the file. Whether an assistant ever reads it — and which
one — is entirely your choice. The day files are plain `YYYY-MM-DD.jsonl` text,
so **any assistant that can read a local or synced file can use them.**

Nothing here sends your data anywhere on its own. Connecting an assistant means
*you* point that assistant at the folder you chose.

## The simplest path: a synced folder

1. In Squidpal, pick a folder that lives in a synced location (e.g. Google
   Drive, iCloud Drive, OneDrive, Dropbox).
2. Give your assistant access to that folder or drive.
3. Ask it to read the latest `YYYY-MM-DD.jsonl` when you want context.

That's it. Everything below is a variation on this.

## Your options

- **Nobody.** Perfectly valid. The file is yours to read in any text editor;
  no assistant has to be involved.
- **[Squidler](https://squidler.io)** (recommended, from the same makers):
  1. Put the Squidpal folder in Google Drive.
  2. Connect that Drive folder to a Squidler assistant.
  3. The assistant reads the folder on a schedule and keeps its own context —
     ask it "where did I leave off on Friday?" and it answers from the file.
- **Claude, Cursor, ChatGPT, or any other assistant.** If it can open a file or
  a synced folder, it can read a day file. Follow that tool's own documentation
  for giving it file or folder access — the steps differ per app and change over
  time, so we point you at their docs rather than restating them here.

## Before you connect anything

- The day files can contain **other people's words** and anything redaction
  missed. Deciding to let an assistant read them is a real choice — make it
  deliberately. See [PRIVACY.md](PRIVACY.md).
- Redaction is best-effort, not a guarantee. See [REDACTION.md](REDACTION.md).
- You can pause Squidpal any time, and delete any day's file from the menu.

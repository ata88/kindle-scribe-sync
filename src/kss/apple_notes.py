"""Create/update Apple Notes via AppleScript (osascript). macOS only.

The HTML body is handed over through a temp file so no escaping issues arise.
Each Kindle notebook maps to exactly one note; we remember the note's id.
"""

from __future__ import annotations

import logging
import subprocess
import sys
import tempfile
from pathlib import Path

log = logging.getLogger(__name__)

UPSERT_SCRIPT = r'''
on run argv
    set htmlPath to item 1 of argv
    set noteId to item 2 of argv
    set accountName to item 3 of argv
    set folderPathText to item 4 of argv
    set htmlBody to read (POSIX file htmlPath) as «class utf8»
    tell application "Notes"
        if accountName is "" then
            set targetAccount to default account
        else
            try
                set targetAccount to account accountName
            on error
                set targetAccount to default account
            end try
        end if
        set targetFolder to my ensureFolder(targetAccount, folderPathText)
        set theNote to missing value
        if noteId is not "" then
            try
                set theNote to note id noteId
                -- a note in "Recently Deleted" counts as gone
                if name of container of theNote is in {"Recently Deleted", "Zuletzt gelöscht"} then set theNote to missing value
            on error
                set theNote to missing value
            end try
        end if
        if theNote is missing value then
            set theNote to make new note at targetFolder with properties {body:htmlBody}
        else
            set body of theNote to htmlBody
            try
                if (id of container of theNote) is not (id of targetFolder) then move theNote to targetFolder
            end try
        end if
        return id of theNote
    end tell
end run

on ensureFolder(acc, pathText)
    set AppleScript's text item delimiters to "/"
    set parts to text items of pathText
    set AppleScript's text item delimiters to ""
    tell application "Notes"
        set parentObj to acc
        repeat with p in parts
            set folderName to p as text
            if folderName is not "" then
                if exists folder folderName of parentObj then
                    set parentObj to folder folderName of parentObj
                else
                    set parentObj to make new folder at parentObj with properties {name:folderName}
                end if
            end if
        end repeat
        return parentObj
    end tell
end ensureFolder
'''

DELETE_SCRIPT = r'''
on run argv
    tell application "Notes"
        try
            delete note id (item 1 of argv)
        end try
    end tell
end run
'''


class AppleNotesError(Exception):
    pass


def _script_file(name: str, source: str) -> Path:
    """AppleScript source as a file (osascript <file> args… is the documented form)."""
    from .config import home_dir

    path = home_dir() / f"{name}.applescript"
    if not path.exists() or path.read_text("utf-8") != source:
        path.write_text(source, "utf-8")
    return path


def available() -> bool:
    return sys.platform == "darwin"


def folder_path_text(root: str, sub: list[str]) -> str:
    parts = [root, *sub]
    return "/".join(p.replace("/", "∕").strip() for p in parts if p and p.strip())


def upsert(html_body: str, *, note_id: str | None, account: str, folder_path: str) -> str:
    """Create or update the note. Returns the (possibly new) note id."""
    if not available():
        raise AppleNotesError("Apple Notes ist nur auf macOS verfügbar")
    with tempfile.NamedTemporaryFile("w", suffix=".html", encoding="utf-8", delete=False) as f:
        f.write(html_body)
        tmp = Path(f.name)
    try:
        out = subprocess.run(
            ["osascript", str(_script_file("notes-upsert", UPSERT_SCRIPT)), str(tmp), note_id or "", account,
             folder_path],
            capture_output=True, text=True, timeout=180,
        )
    finally:
        tmp.unlink(missing_ok=True)
    if out.returncode != 0:
        msg = out.stderr.strip()
        if "-1743" in msg or "Not authorized" in msg:
            msg += (" — Bitte in Systemeinstellungen › Datenschutz & Sicherheit › Automation "
                    "erlauben, dass Terminal/Python 'Notizen' steuern darf.")
        raise AppleNotesError(msg)
    return out.stdout.strip()


def delete(note_id: str) -> None:
    if available() and note_id:
        subprocess.run(["osascript", str(_script_file("notes-delete", DELETE_SCRIPT)), note_id],
                       capture_output=True, text=True, timeout=60)

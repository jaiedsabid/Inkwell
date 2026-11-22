#!/usr/bin/env python3
"""Writes the Sparkle appcast for one release.

    scripts/appcast.py VERSION BUILD DMG SIGNATURE LENGTH NOTES_FILE OUT [REPO]

The feed holds only the newest version: Sparkle needs nothing more, and the app reads it from the latest GitHub release.
"""
import html
import re
import sys
from email.utils import formatdate


def notes_html(md: str) -> str:
    """Just enough Markdown for release notes: ### headings, - bullets, **bold**, `code` and [links](url)."""
    out, in_list = [], False
    for line in md.splitlines():
        text = html.escape(line.strip())
        text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
        text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
        text = re.sub(r"\[(.+?)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)
        if text.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{text[2:]}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if text.startswith("### "):
            out.append(f"<h3>{text[4:]}</h3>")
        elif text:
            out.append(f"<p>{text}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main() -> None:
    version, build, dmg, signature, length, notes_file, out = sys.argv[1:8]
    repo = sys.argv[8] if len(sys.argv) > 8 else "jaiedsabid/Inkwell"
    name = dmg.split("/")[-1]
    with open(notes_file, encoding="utf-8") as f:
        notes = notes_html(f.read())
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Inkwell</title>
    <link>https://github.com/{repo}</link>
    <description>Inkwell updates</description>
    <language>en</language>
    <item>
      <title>Inkwell {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/{repo}/releases/tag/v{version}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="https://github.com/{repo}/releases/download/v{version}/{name}" type="application/octet-stream" sparkle:edSignature="{signature}" length="{length}"/>
    </item>
  </channel>
</rss>
"""
    with open(out, "w", encoding="utf-8") as f:
        f.write(feed)


if __name__ == "__main__":
    main()

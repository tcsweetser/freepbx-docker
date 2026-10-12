#!/usr/bin/env python3
"""Asterisk voicemail `mailcmd`: swap the recording for an MP3, then send.

Asterisk cannot record MP3, so voicemail.conf points `mailcmd` here instead of
`/usr/sbin/sendmail -t`. Asterisk pipes the complete MIME notification on stdin.
Every audio attachment (normally msgNNNN.WAV, GSM-in-WAV) is replaced by an MP3
of the same name; the rest of the message is passed through unchanged.

Headers are parsed with the compat32 policy, which keeps them as the raw strings
Asterisk wrote. The default policy decodes RFC 2047 words and re-folds them, so a
caller-ID name such as an encoded "\\r\\nBcc: x" could be re-emitted as a real
header line on an unpatched Python (CVE-2024-6923), and `sendmail -t` would then
mail the recording to that address.

If conversion fails for any reason the ORIGINAL message (with the WAV) is sent,
so a voicemail alert is never lost because of an encoding problem. Failures are
logged to /var/log/asterisk/vm-mp3-sendmail.log.
"""
import logging
import subprocess
import sys
from email import message_from_bytes
from email.message import Message
from email.mime.audio import MIMEAudio
from email.policy import compat32
from pathlib import PurePath

SENDMAIL = ["/usr/sbin/sendmail", "-t"]
FFMPEG = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
          "-codec:a", "libmp3lame", "-q:a", "5", "-ac", "1", "-f", "mp3", "pipe:1"]

logging.basicConfig(filename="/var/log/asterisk/vm-mp3-sendmail.log",
                    format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)
logger = logging.getLogger(__name__)


def to_mp3(audio: bytes) -> bytes:
    """Transcode any ffmpeg-readable audio to mono MP3."""
    result = subprocess.run(FFMPEG, input=audio, capture_output=True, check=True, timeout=60)
    if not result.stdout:
        raise ValueError("ffmpeg produced no output")
    return result.stdout


def mp3_part(part: Message) -> MIMEAudio:
    """Build an audio/mpeg attachment from an audio part, keeping its base name."""
    audio = part.get_payload(decode=True)
    if not audio:
        raise ValueError("empty audio attachment")
    name = PurePath(part.get_filename() or "voicemail.wav").with_suffix(".mp3").name
    new = MIMEAudio(to_mp3(audio), _subtype="mpeg")
    new.add_header("Content-Disposition", "attachment", filename=name)
    return new


def replace_audio_with_mp3(raw: bytes) -> bytes:
    """Return the message with every audio attachment replaced by an MP3."""
    msg = message_from_bytes(raw)  # compat32: headers stay byte-for-byte
    replaced = 0
    for container in msg.walk():
        if not container.is_multipart():
            continue
        children = container.get_payload()
        for i, child in enumerate(children):
            if not child.is_multipart() and child.get_content_maintype() == "audio":
                children[i] = mp3_part(child)
                replaced += 1
    if not replaced:
        return raw
    # max_line_length=None: never re-fold, so header bytes match Asterisk's.
    return msg.as_bytes(policy=compat32.clone(max_line_length=None))


def main() -> int:
    raw = sys.stdin.buffer.read()
    try:
        out = replace_audio_with_mp3(raw)
    except (subprocess.SubprocessError, OSError, ValueError, TypeError) as exc:
        logger.error("MP3 conversion failed, sending original: %s", exc)
        out = raw
    return subprocess.run(SENDMAIL, input=out, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())

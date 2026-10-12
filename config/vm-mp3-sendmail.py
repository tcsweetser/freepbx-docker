#!/usr/bin/env python3
"""Asterisk voicemail `mailcmd`: attach an MP3 copy of the recording, then send.

Asterisk cannot record MP3, so voicemail.conf points `mailcmd` here instead of
`/usr/sbin/sendmail -t`. Asterisk pipes the complete MIME notification on stdin.
For every audio attachment (normally msgNNNN.WAV, GSM-in-WAV) an MP3 copy is
added next to it, and the message is handed to sendmail unchanged otherwise.

If conversion fails for any reason the ORIGINAL message is sent, so a voicemail
alert is never lost because of an encoding problem. Failures are logged to
/var/log/asterisk/vm-mp3-sendmail.log.
"""
import logging
import subprocess
import sys
from email import message_from_bytes, policy
from email.message import EmailMessage
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


def add_mp3_copies(raw: bytes) -> bytes:
    """Return the message with an MP3 added for each audio attachment."""
    msg: EmailMessage = message_from_bytes(raw, policy=policy.default)
    audio_parts = [p for p in msg.iter_attachments() if p.get_content_maintype() == "audio"]
    for part in audio_parts:
        name = PurePath(part.get_filename() or "voicemail.wav").with_suffix(".mp3").name
        msg.add_attachment(to_mp3(part.get_content()), maintype="audio",
                           subtype="mpeg", filename=name)
    return msg.as_bytes()


def main() -> int:
    raw = sys.stdin.buffer.read()
    try:
        out = add_mp3_copies(raw)
    except (subprocess.SubprocessError, OSError, ValueError, TypeError) as exc:
        logger.error("MP3 conversion failed, sending original: %s", exc)
        out = raw
    return subprocess.run(SENDMAIL, input=out, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())

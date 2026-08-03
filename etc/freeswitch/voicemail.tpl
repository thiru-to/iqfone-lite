From: ${voicemail_email_from}
To: ${voicemail_email_to}
Subject: Voicemail from ${voicemail_caller_id_name} (${voicemail_caller_id_number})
X-Priority: ${voicemail_priority}
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="iqfone-vm-boundary"

--iqfone-vm-boundary
Content-Type: text/plain; charset=utf-8

New voicemail for extension ${voicemail_account}.

From:     ${voicemail_caller_id_name} (${voicemail_caller_id_number})
Received: ${voicemail_time}
Duration: ${voicemail_message_len} seconds

The recording is attached. It is also available by dialling *98 from your
phone for 30 days.

--iqfone-vm-boundary
Content-Type: text/html; charset=utf-8

<html><body style="font-family:sans-serif">
<p>New voicemail for extension <strong>${voicemail_account}</strong>.</p>
<table cellpadding="4">
<tr><td>From</td><td>${voicemail_caller_id_name} (${voicemail_caller_id_number})</td></tr>
<tr><td>Received</td><td>${voicemail_time}</td></tr>
<tr><td>Duration</td><td>${voicemail_message_len} seconds</td></tr>
</table>
<p>The recording is attached. It is also available by dialling
<strong>*98</strong> from your phone for 30 days.</p>
</body></html>

--iqfone-vm-boundary--

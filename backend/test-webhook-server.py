"""Quick local webhook receiver for testing the full flow.

Run:    python3 test-webhook-server.py
Listens on http://0.0.0.0:9000/webhook
Prints every callback to the terminal.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import sys


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        sig = self.headers.get("X-Webhook-Signature", "")

        print("\n" + "=" * 60)
        print(f"📬 Webhook received  ({self.path})")
        print(f"  Signature: {sig[:30]}...")
        try:
            payload = json.loads(body)
            print(f"  message_id:   {payload.get('message_id')}")
            print(f"  user_key:     {payload.get('user_key')}")
            print(f"  button_id:    {payload.get('button_id')}")
            print(f"  button_label: {payload.get('button_label')}")
            print(f"  data:         {payload.get('data')}")
        except Exception:
            print(f"  body: {body}")
        print("=" * 60)

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def log_message(self, *args):
        pass  # silence default logging


if __name__ == "__main__":
    port = 9090
    print(f"🎣 Webhook receiver listening on http://0.0.0.0:{port}/webhook")
    print(f"   (agents config webhook: http://192.168.5.153:{port}/webhook)")
    print("   Press Ctrl+C to stop.\n")
    HTTPServer(("0.0.0.0", port), WebhookHandler).serve_forever()

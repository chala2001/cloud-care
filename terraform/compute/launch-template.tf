# terraform/compute/launch-template.tf

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # Attach the APP security group from Phase 1 (only :8000 from the ALB).
  vpc_security_group_ids = [
    data.terraform_remote_state.network.outputs.app_security_group_id
  ]

  # Force IMDSv2 (token-based metadata) — blocks a common SSRF credential-theft
  # path. A cheap, expected security hardening.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # Boot script: install NOTHING; run a stdlib HTTP health server on :8000.
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    cat >/opt/health.py <<'PY'
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import socket
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(("CloudCare healthy from %s\n" % socket.gethostname()).encode())
        def log_message(self, *args):
            return
    HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
    PY

    cat >/etc/systemd/system/cloudcare.service <<'UNIT'
    [Unit]
    Description=CloudCare placeholder health service
    After=network.target

    [Service]
    ExecStart=/usr/bin/python3 /opt/health.py
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now cloudcare
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project}-app"
    }
  }
}
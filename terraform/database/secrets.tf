# terraform/database/secrets.tf

# Generate a strong master password. Stored in TF state (which is why our state
# bucket is private + encrypted — Doc 06) and in Secrets Manager, never in code.
resource "random_password" "db" {
  length  = 20
  special = true
  # Exclude characters RDS rejects in master passwords (/, @, ", and spaces).
  override_special = "!#$%^&*()-_=+[]{}"
}

# A Secrets Manager secret to hold the DB connection details. The app (Phase 4)
# will read this at runtime instead of having credentials baked in.
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.project}/db/credentials"
  description = "CloudCare RDS master credentials"

  # Learning-friendly: allow immediate delete + recreate (no 7–30 day window).
  recovery_window_in_days = 0
}

# The actual secret value — a JSON blob the app can parse.
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    engine   = "postgres"
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = var.db_name
  })
}
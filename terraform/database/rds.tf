# terraform/database/rds.tf

# Tells RDS WHICH subnets it may place the database in. We give it both private
# db subnets so a Multi-AZ standby (if enabled) lands in the other AZ.
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = data.terraform_remote_state.network.outputs.db_subnet_ids

  tags = { Name = "${var.project}-db-subnet-group" }
}

resource "aws_db_instance" "main" {
  identifier     = "${var.project}-postgres"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true # encrypt data at rest — non-negotiable for patient data

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  # Network placement: private subnets + the db-sg (only :5432 from app-sg).
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [data.terraform_remote_state.network.outputs.db_security_group_id]
  publicly_accessible    = false # the DB must never have a public endpoint

  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_days

  # Learning-friendly destroy behavior (do NOT use these defaults in production):
  skip_final_snapshot = true  # don't force a final snapshot when destroying
  deletion_protection = false # allow `terraform destroy`
  apply_immediately   = true  # apply changes now, not in the maintenance window

  tags = { Name = "${var.project}-postgres" }
}
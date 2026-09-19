# DB Subnet Group
# Tells RDS which subnets it can use
# Requires at least two subnets in different AZs
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = [
    var.private_db_subnet_1_id,
    var.private_db_subnet_2_id
  ]

  tags = { Name = "${var.project_name}-db-subnet-group" }
}

# RDS MySQL Instance
resource "aws_db_instance" "main" {
  identifier        = "${var.project_name}-db"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = "weatherapp"
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]

  # Single AZ - no standby (free tier)
  multi_az = false

  # Backups disabled to stay on free tier
  backup_retention_period = 0

  # Allow terraform destroy to delete the database
  skip_final_snapshot = true

  # Prevent accidental public exposure
  publicly_accessible = false

  tags = { Name = "${var.project_name}-db" }
}

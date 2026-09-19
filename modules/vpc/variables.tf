variable "project_name" {}
variable "vpc_cidr" { default = "10.0.0.0/16" }
variable "public_subnet_1_cidr" { default = "10.0.1.0/24" }
variable "public_subnet_2_cidr" { default = "10.0.2.0/24" }
variable "private_app_subnet_1_cidr" { default = "10.0.3.0/24" }
variable "private_app_subnet_2_cidr" { default = "10.0.4.0/24" }
variable "private_db_subnet_1_cidr" { default = "10.0.5.0/24" }
variable "private_db_subnet_2_cidr" { default = "10.0.6.0/24" }

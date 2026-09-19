terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0"
}

provider "aws" {
  region  = var.aws_region
  profile = "zamweather"
}

module "vpc" {
  source       = "./modules/vpc"
  project_name = var.project_name
}

module "security_groups" {
  source       = "./modules/security_groups"
  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
}

module "rds" {
  source                 = "./modules/rds"
  project_name           = var.project_name
  db_username            = var.db_username
  db_password            = var.db_password
  rds_sg_id              = module.security_groups.rds_sg_id
  private_db_subnet_1_id = module.vpc.private_db_subnet_1_id
  private_db_subnet_2_id = module.vpc.private_db_subnet_2_id
}

module "alb" {
  source             = "./modules/alb"
  project_name       = var.project_name
  vpc_id             = module.vpc.vpc_id
  public_subnet_1_id = module.vpc.public_subnet_1_id
  public_subnet_2_id = module.vpc.public_subnet_2_id
  alb_sg_id          = module.security_groups.alb_sg_id
}

module "ec2" {
  source             = "./modules/ec2"
  project_name       = var.project_name
  app_sg_id          = module.security_groups.app_sg_id
  public_subnet_1_id = module.vpc.public_subnet_1_id
  public_subnet_2_id = module.vpc.public_subnet_2_id
  target_group_arn   = module.alb.target_group_arn
  db_host            = module.rds.db_endpoint
  db_user            = var.db_username
  db_password        = var.db_password
  db_name            = "weatherapp"
  api_key            = var.openweather_api_key
}

data "aws_instances" "app_servers" {
  instance_tags = {
    Name = "${var.project_name}-app-server"
  }
  instance_state_names = ["running"]
  depends_on           = [module.ec2]
}

variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "zamweather"
}

variable "db_username" {
  description = "RDS master username"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

variable "openweather_api_key" {
  description = "OpenWeatherMap API key"
  type        = string
  sensitive   = true
}

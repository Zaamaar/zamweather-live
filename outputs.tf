output "alb_dns_name" {
  description = "ALB URL - Flask API endpoint"
  value       = module.alb.alb_dns_name
}

output "frontend_url" {
  description = "Frontend - hosted on Netlify"
  value       = "https://zamweather.netlify.app/"
}

output "instance_public_ip" {
  description = "EC2 instance public IP for SSH access"
  value       = length(data.aws_instances.app_servers.public_ips) > 0 ? data.aws_instances.app_servers.public_ips[0] : "Instance not running yet"
}

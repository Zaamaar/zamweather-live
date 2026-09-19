# Application Load Balancer
# Internet-facing, spans both public subnets across both AZs
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = [var.public_subnet_1_id, var.public_subnet_2_id]

  tags = { Name = "${var.project_name}-alb" }
}

# Target Group
# The ALB forwards traffic to this group
# EC2 instances register themselves here via the ASG
resource "aws_lb_target_group" "main" {
  name     = "${var.project_name}-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  # Health check - ALB hits /health every 30 seconds
  # Instance must return 200 OK to be considered healthy
  health_check {
    enabled             = true
    path                = "/health"
    port                = "5000"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${var.project_name}-tg" }
}

# ALB Listener
# Listens on port 80 and forwards to the target group
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

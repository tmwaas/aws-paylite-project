terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

variable "name" {
  type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "image" { type = string }
variable "container_port" { type = number
  default = 8080
}
variable "cpu" {
  type = number
  default = 256
}
variable "memory" {
  type = number
  default = 512
}

resource "aws_ecs_cluster" "this" { name = var.name }

resource "aws_iam_role" "task_exec" {
  name = "${var.name}-task-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Effect = "Allow"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "exec_attach" {
  role = aws_iam_role.task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_lb" "alb" {
  name = "${var.name}-alb"
  load_balancer_type = "application"
  subnets = var.public_subnet_ids
}

resource "aws_lb_target_group" "blue" {
  name     = "${var.name}-blue"
  port     = var.container_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  target_type = "ip"
  health_check { path = "/health" }
}

resource "aws_lb_target_group" "green" {
  name     = "${var.name}-green"
  port     = var.container_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  target_type = "ip"
  health_check { path = "/health" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port = 80
  protocol = "HTTP"
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }
}

resource "aws_ecs_task_definition" "td" {
  family                   = var.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.task_exec.arn
  container_definitions = jsonencode([{
    name  = var.name
    image = var.image
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
    environment = [{ name = "SERVICE_NAME", value = var.name }]
  }])
}

resource "aws_ecs_service" "svc" {
  name            = var.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.td.arn
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets = var.public_subnet_ids
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = var.name
    container_port   = var.container_port
  }
  deployment_controller { type = "CODE_DEPLOY" }
}

resource "aws_iam_role" "codedeploy" {
  name = "${var.name}-cd"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Principal = { Service = "codedeploy.amazonaws.com" },
      Effect = "Allow"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cd_attach" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRoleForECS"
}

resource "aws_codedeploy_app" "app" {
  name = var.name
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "dg" {
  app_name              = aws_codedeploy_app.app.name
  deployment_group_name = "${var.name}-dg"
  service_role_arn      = aws_iam_role.codedeploy.arn

  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  ecs_service {
    cluster_name = aws_ecs_cluster.this.name
    service_name = aws_ecs_service.svc.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route { listener_arns = [aws_lb_listener.http.arn] }
      target_group { name = aws_lb_target_group.blue.name }
      target_group { name = aws_lb_target_group.green.name }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}

output "alb_dns" { value = aws_lb.alb.dns_name }

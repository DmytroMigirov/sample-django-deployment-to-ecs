resource "aws_ecs_cluster" "production" {
  name = "${var.ecs_cluster_name}-cluster"
}

data "template_file" "app" {
  template = file("templates/django_app.json.tpl")

  vars = {
    docker_image_url_django = var.docker_image_url_django
    region                  = var.region
    rds_db_name             = var.rds_db_name
    rds_username            = var.rds_username
    rds_password            = var.rds_password
    rds_hostname            = aws_db_instance.production.address
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = "django-app"
  network_mode             = "awsvpc" # Required for Fargate
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.ecs-task-execution-role.arn
  task_role_arn            = aws_iam_role.ecs-task-execution-role.arn
  container_definitions    = jsonencode([
    {
      name        = "django-migration-container"
      image       = var.docker_image_url_django
      environment = [
        {
          name  = "RDS_DB_NAME"
          value = var.rds_db_name
        },
        {
          name  = "RDS_USERNAME"
          value = var.rds_username
        },
        {
          name  = "RDS_PASSWORD"
          value = var.rds_password
        },
        {
          name  = "RDS_HOSTNAME"
          value = aws_db_instance.production.address
        },
        {
          name  = "DATABASE_URL"
          value = "postgresql://${var.rds_username}:${var.rds_password}@${aws_db_instance.production.address}:5432/${var.rds_db_name}"
        },
        {
          name  = "RDS_PORT"
          value = "5432"
        }
      ]
      # Run migrate command
      command = ["python", "manage.py", "migrate"]
    }
  ])

  depends_on = [aws_db_instance.production]
}


resource "aws_ecs_service" "production" {
  name            = "${var.ecs_cluster_name}-service"
  cluster         = aws_ecs_cluster.production.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"
  desired_count   = var.app_count
  network_configuration {
    subnets          = [aws_subnet.public-subnet-1.id, aws_subnet.public-subnet-2.id]
    security_groups  = [aws_security_group.ecs-fargate.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.default-target-group.arn
    container_name   = "django-app"
    container_port   = 8000
  }
} 

############ Auto-scaling ###############

resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = var.autoscale_max
  min_capacity       = var.autoscale_min
  resource_id        = "service/${aws_ecs_cluster.production.name}/${aws_ecs_service.production.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_policy" {
  name               = "ecs-auto-scaling-policy"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = 75
    scale_in_cooldown  = 300
    scale_out_cooldown = 300
  }
}

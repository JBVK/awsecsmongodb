terraform {

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.40.0"
    }
  }

  required_version = ">= 1.6"
}

provider "aws" {
  region = "eu-west-1"
}

data "aws_availability_zones" "available" {}

# VPC
resource "aws_vpc" "mongolab_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "subnets" {
  count                   = "3"
  vpc_id                  = aws_vpc.mongolab_vpc.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "mongolab_igw" {
  vpc_id = aws_vpc.mongolab_vpc.id
}

resource "aws_route_table" "mongolab_route_table" {
  vpc_id = aws_vpc.mongolab_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.mongolab_igw.id
  }

  tags = {
    Name = "mongolab_route_table"
  }
}

resource "aws_route_table_association" "mongolab_route_association" {
  count = length(aws_subnet.subnets.*.id)

  subnet_id      = aws_subnet.subnets[count.index].id
  route_table_id = aws_route_table.mongolab_route_table.id
}

resource "aws_iam_role" "ecs_mongo_task_execution_role" {
  name = "ecs_mongo_task_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Effect = "Allow"
        Sid    = ""
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_mongo_task_execution_role_policy" {
  role       = aws_iam_role.ecs_mongo_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


resource "aws_iam_role" "ecs_mongo_task_role" {
  name = "ecs_mongo_task_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Effect = "Allow"
        Sid    = ""
      },
    ]
  })
}

resource "aws_security_group" "ec2_sg" {
  name        = "ec2_sg"
  description = "Security group for EC2 instance"
  vpc_id      = aws_vpc.mongolab_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "mongo_ecs_tasks_sg" {
  name        = "mongo-ecs-tasks-sg"
  description = "Security group for ECS MongoDB tasks"
  vpc_id      = aws_vpc.mongolab_vpc.id

  ingress {
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "mongolab-ecs-tasks-sg"
  }
}

resource "aws_security_group" "efs_sg" {
  name        = "efs-mongolab-sg"
  description = "Security group for EFS"
  vpc_id      = aws_vpc.mongolab_vpc.id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.mongolab_vpc.cidr_block]
  }
}

resource "aws_efs_file_system" "mongolab_file_system" {
  creation_token = "mongoefs"
  encrypted      = true

  tags = {
    Name = "mongoefs"
  }
}

resource "aws_efs_mount_target" "efs_mount_target" {
  count           = length(aws_subnet.subnets.*.id)
  file_system_id  = aws_efs_file_system.mongolab_file_system.id
  subnet_id       = aws_subnet.subnets[count.index].id
  security_groups = [aws_security_group.efs_sg.id]
}


resource "aws_iam_policy" "ecs_efs_access_policy" {
  name        = "ecs_efs_access_policy"
  description = "Allow ECS tasks to access EFS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:DescribeFileSystems",
          "elasticfilesystem:DescribeMountTargets"
        ]
        Resource = aws_efs_file_system.mongolab_file_system.arn
        Effect   = "Allow"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_efs_access_policy_attachment" {
  role       = aws_iam_role.ecs_mongo_task_role.name
  policy_arn = aws_iam_policy.ecs_efs_access_policy.arn
}


resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/mongolab"
  retention_in_days = 30
}

resource "aws_iam_policy" "ecs_logging" {
  name        = "ecs_logging_policy"
  description = "Allow ECS tasks to send logs to CloudWatch"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*",
        Effect   = "Allow"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_mongo_logs" {
  role       = aws_iam_role.ecs_mongo_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_logging.arn
}

resource "aws_ecs_cluster" "mongolab_cluster" {
  name = "mongolab-cluster"
}

resource "aws_ecs_task_definition" "mongo_task_definition" {
  family                   = "mongolab-mongodb"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_mongo_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_mongo_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "mongo",
      image     = "mongo:latest",
      cpu       = 256,
      memory    = 512,
      essential = true,
      portMappings = [
        {
          protocol      = "tcp"
          containerPort = 27017
          hostPort      = 27017
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "mongoEfsVolume"
          containerPath = "/data/db"
          readOnly      = false
        },
      ],
      environment = [
        {
          name  = "MONGO_INITDB_ROOT_USERNAME"
          value = "mongolabadmin"
        },
        {
          name  = "MONGO_INITDB_ROOT_PASSWORD"
          value = "mongolabpassword"
        },
        {
          name  = "MONGO_INITDB_DATABASE"
          value = "mongolab"
        }
      ],
      healthcheck = {
        command     = ["CMD-SHELL", "echo 'db.runCommand(\\\"ping\\\").ok' | mongosh mongodb://localhost:27017/test"]
        interval    = 5
        timeout     = 15
        retries     = 3
        startPeriod = 15
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_logs.name
          awslogs-region        = "eu-west-1"
          awslogs-stream-prefix = "mongodb"
        }
      }
    }
  ])

  volume {
    name = "mongoEfsVolume"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.mongolab_file_system.id
      transit_encryption = "ENABLED"
      authorization_config {
        iam = "ENABLED"
      }
    }
  }
}

resource "aws_service_discovery_private_dns_namespace" "mongolab_monitoring" {
  name = "mongolab.local"
  vpc  = aws_vpc.mongolab_vpc.id
}

resource "aws_service_discovery_service" "mongo_discovery_service" {
  name = "mongodb"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.mongolab_monitoring.id

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_ecs_service" "mongo_service" {
  name            = "mongolab-mongodb-service"
  cluster         = aws_ecs_cluster.mongolab_cluster.id
  task_definition = "${aws_ecs_task_definition.mongo_task_definition.id}:2"
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.subnets[*].id
    security_groups  = [aws_security_group.mongo_ecs_tasks_sg.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.mongo_discovery_service.arn
  }

}

# EC2 instance

resource "aws_key_pair" "ec2_keypair" {
  key_name   = "examplekey"
  public_key = file("~/.ssh/mongolab.pub")
}

resource "aws_instance" "example" {
  ami           = "ami-074254c177d57d640"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.subnets[0].id
  key_name      = aws_key_pair.ec2_keypair.key_name

  security_groups = [aws_security_group.ec2_sg.id]

  user_data = <<-EOF
              #!/bin/bash

              # Add the MongoDB repository
              cat <<EOT > /etc/yum.repos.d/mongodb-org-7.0.repo
              [mongodb-org-7.0]
              name=MongoDB Repository
              baseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/7.0/x86_64/
              gpgcheck=1
              enabled=1
              gpgkey=https://pgp.mongodb.com/server-7.0.asc
              EOT

              # Update your system
              dnf update -y

              # Install MongoDB
              dnf install -y mongodb-org

              # Start the MongoDB service
              systemctl start mongod

              # Enable MongoDB to start on boot
              systemctl enable mongod

              # Fix issue with openssl
              dnf erase -qy mongodb-mongosh
              dnf install -qy mongodb-mongosh-shared-openssl3
              EOF

  lifecycle {
    ignore_changes = [
      security_groups
    ]
  }
}



provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {

  # this will get the name of the local directory
  # name   = basename(path.cwd)
  name = var.service_name

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/${var.repository_owner}/terraform-aws-ecs-blueprints"
  }

  tag_val_vpc            = var.vpc_tag_value == "" ? var.core_stack_name : var.vpc_tag_value
  tag_val_private_subnet = var.private_subnets_tag_value == "" ? "${var.core_stack_name}-private-" : var.private_subnets_tag_value
  tag_val_public_subnet  = var.public_subnets_tag_value == "" ? "${var.core_stack_name}-public-" : var.public_subnets_tag_value

}

################################################################################
# Data Sources from ecs-blueprint-infra
################################################################################

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:${var.vpc_tag_key}"
    values = [local.tag_val_vpc]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "tag:${var.vpc_tag_key}"
    values = ["${local.tag_val_private_subnet}*"]
  }
}

data "aws_subnet" "private_cidr" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

data "aws_subnets" "public" {
  filter {
    name   = "tag:${var.vpc_tag_key}"
    values = ["${local.tag_val_public_subnet}*"]
  }
}

data "aws_ecs_cluster" "core_infra" {
  cluster_name = var.ecs_cluster_name == "" ? var.core_stack_name : var.ecs_cluster_name
}

data "aws_iam_role" "ecs_core_infra_exec_role" {
  name = var.ecs_task_execution_role_name == "" ? "${var.core_stack_name}-execution" : var.ecs_task_execution_role_name
}

data "aws_service_discovery_dns_namespace" "sd_namespace" {
  name = "${var.namespace}.${data.aws_ecs_cluster.core_infra.cluster_name}.local"
  type = "DNS_PRIVATE"
}

################################################################################
# RDS Aurora for Backstage backend db
################################################################################

data "aws_secretsmanager_secret" "postgresdb_master_password" {
  name = var.postgresdb_master_password
}

data "aws_secretsmanager_secret_version" "postgresdb_master_password" {
  secret_id = data.aws_secretsmanager_secret.postgresdb_master_password.id
}

module "aurora_postgresdb" {
  source = "terraform-aws-modules/rds-aurora/aws"

  name        = var.postgresdb_name
  engine      = "aurora-postgresql"
  engine_mode = "serverless"

  vpc_id  = data.aws_vpc.vpc.id
  subnets = data.aws_subnets.private.ids

  allowed_cidr_blocks = [for s in data.aws_subnet.private_cidr : s.cidr_block]

  storage_encrypted   = true
  apply_immediately   = true
  monitoring_interval = 60

  scaling_configuration = {
    min_capacity = 2
    max_capacity = 2
  }

  create_random_password = false
  master_username        = var.postgresdb_master_username
  master_password        = data.aws_secretsmanager_secret_version.postgresdb_master_password.secret_string
  port                   = var.postgresdb_port

  tags = local.tags
}

resource "aws_ssm_parameter" "postgres_host" {
  name  = "postgres_host"
  type  = "String"
  value = module.aurora_postgresdb.cluster_endpoint
}

resource "aws_ssm_parameter" "postgres_port" {
  name  = "postgres_port"
  type  = "String"
  value = var.postgresdb_port
}

resource "aws_ssm_parameter" "postgres_user" {
  name  = "postgres_user"
  type  = "String"
  value = var.postgresdb_master_username
}

resource "aws_ssm_parameter" "base_url" {
  name  = "base_url"
  type  = "String"
  value = "http://${module.service_alb.lb_dns_name}"
}

################################################################################
# ECS Blueprint
################################################################################

module "service_alb_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-alb-sg"
  description = "Security group for client application"
  vpc_id      = data.aws_vpc.vpc.id

  ingress_rules       = ["http-80-tcp"]
  ingress_cidr_blocks = ["0.0.0.0/0"]

  egress_rules       = ["all-all"]
  egress_cidr_blocks = [for s in data.aws_subnet.private_cidr : s.cidr_block]

  tags = local.tags
}

module "service_alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 7.0"

  name = "${local.name}-alb"

  load_balancer_type = "application"

  vpc_id          = data.aws_vpc.vpc.id
  subnets         = data.aws_subnets.public.ids
  security_groups = [module.service_alb_security_group.security_group_id]

  http_tcp_listeners = [
    {
      port               = var.listener_port
      protocol           = var.listener_protocol
      target_group_index = 0
    },
  ]

  target_groups = [
    {
      name             = "${local.name}-tg"
      backend_protocol = var.container_protocol
      backend_port     = var.container_port
      target_type      = "ip"
      health_check = {
        path    = var.health_check_path
        port    = var.container_port
        matcher = var.health_check_matcher
      }
    },
  ]

  tags = local.tags
}

module "container_image_ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 1.4"

  repository_name = var.container_name

  repository_force_delete           = true
  create_lifecycle_policy           = false
  repository_read_access_arns       = [data.aws_iam_role.ecs_core_infra_exec_role.arn]
  repository_read_write_access_arns = [module.codepipeline_ci_cd.codepipeline_role_arn]

  tags = local.tags
}

module "service_task_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-task-sg"
  description = "Security group for service task"
  vpc_id      = data.aws_vpc.vpc.id

  ingress_with_source_security_group_id = [
    {
      from_port                = var.container_port
      to_port                  = var.container_port
      protocol                 = "tcp"
      source_security_group_id = module.service_alb_security_group.security_group_id
    },
  ]

  egress_rules = ["all-all"]

  tags = local.tags
}


resource "aws_service_discovery_service" "sd_service" {
  name = local.name

  dns_config {
    namespace_id = data.aws_service_discovery_dns_namespace.sd_namespace.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

module "ecs_service_definition" {
  source = "../../modules/ecs-service"

  name                       = local.name
  desired_count              = var.desired_count
  ecs_cluster_id             = data.aws_ecs_cluster.core_infra.cluster_name
  cp_strategy_base           = var.cp_strategy_base
  cp_strategy_fg_weight      = var.cp_strategy_fg_weight
  cp_strategy_fg_spot_weight = var.cp_strategy_fg_spot_weight

  security_groups = [module.service_task_security_group.security_group_id]
  subnets         = data.aws_subnets.private.ids

  load_balancers = [{
    target_group_arn = element(module.service_alb.target_group_arns, 0)
  }]

  service_registry_list = [{
    registry_arn = aws_service_discovery_service.sd_service.arn
  }]

  deployment_controller = "ECS"

  # Task Definition
  attach_task_role_policy = false
  lb_container_port       = var.container_port
  lb_container_name       = var.container_name
  cpu                     = var.cpu
  memory                  = var.memory
  execution_role_arn      = data.aws_iam_role.ecs_core_infra_exec_role.arn

  container_definition_defaults = var.container_definition_defaults

  container_definitions = {
    main_container = {
      name  = var.container_name
      image = module.container_image_ecr.repository_url
      secrets = [
        { name = "GITHUB_TOKEN", valueFrom = data.aws_secretsmanager_secret.github_token.arn },
        { name = "BASE_URL", valueFrom = aws_ssm_parameter.base_url.name },
        { name = "POSTGRES_HOST", valueFrom = aws_ssm_parameter.postgres_host.name },
        { name = "POSTGRES_PORT", valueFrom = aws_ssm_parameter.postgres_port.name },
        { name = "POSTGRES_USER", valueFrom = aws_ssm_parameter.postgres_user.name },
        { name = "POSTGRES_PASSWORD", valueFrom = data.aws_secretsmanager_secret.postgresdb_master_password.arn }
      ]
      readonly_root_filesystem = false
      port_mappings = [{
        protocol : "tcp",
        containerPort : var.container_port
        hostPort : var.container_port
      }]
    }
  }

  tags = local.tags

  enable_scheduled_autoscaling            = var.enable_scheduled_autoscaling
  scheduled_autoscaling_timezone          = var.scheduled_autoscaling_timezone
  scheduled_autoscaling_up_time           = var.scheduled_autoscaling_up_time
  scheduled_autoscaling_down_time         = var.scheduled_autoscaling_down_time
  scheduled_autoscaling_up_min_capacity   = var.scheduled_autoscaling_up_min_capacity
  scheduled_autoscaling_up_max_capacity   = var.scheduled_autoscaling_up_max_capacity
  scheduled_autoscaling_down_min_capacity = var.scheduled_autoscaling_down_min_capacity
  scheduled_autoscaling_down_max_capacity = var.scheduled_autoscaling_down_max_capacity
}


################################################################################
# CodePipeline and CodeBuild for CI/CD
################################################################################

module "codepipeline_s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 3.0"

  bucket = "codepipeline-${var.aws_region}-${random_id.this.hex}"
  acl    = "private"

  # For example only - please re-evaluate for your environment
  force_destroy = true

  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = local.tags
}

resource "aws_sns_topic" "codestar_notification" {
  name = local.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteAccess"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = "arn:aws:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${local.name}"
        Principal = {
          Service = "codestar-notifications.amazonaws.com"
        }
      },
    ]
  })

  tags = local.tags
}

module "codebuild_ci" {
  source = "../../modules/codebuild"

  name           = "codebuild-${module.ecs_service_definition.name}"
  service_role   = module.codebuild_ci.codebuild_role_arn
  buildspec_path = var.buildspec_path
  s3_bucket      = module.codepipeline_s3_bucket

  environment = {
    image           = "aws/codebuild/standard:5.0"
    privileged_mode = true
    environment_variables = [
      {
        name  = "REPO_URL"
        value = module.container_image_ecr.repository_url
        }, {
        name  = "TASK_DEFINITION_FAMILY"
        value = module.ecs_service_definition.task_definition_family
        }, {
        name  = "CONTAINER_NAME"
        value = var.container_name
        }, {
        name  = "SERVICE_PORT"
        value = var.container_port
        }, {
        name  = "ECS_EXEC_ROLE_ARN"
        value = data.aws_iam_role.ecs_core_infra_exec_role.arn
        }, {
        name  = "BASE_URL"
        value = "http://${module.service_alb.lb_dns_name}"
      },
    ]
  }

  create_iam_role = true
  iam_role_name   = "${module.ecs_service_definition.name}-codebuild-${random_id.this.hex}"
  ecr_repository  = module.container_image_ecr.repository_arn

  tags = local.tags
}

data "aws_secretsmanager_secret" "github_token" {
  name = var.github_token_secret_name
}

data "aws_secretsmanager_secret_version" "github_token" {
  secret_id = data.aws_secretsmanager_secret.github_token.id
}

module "codepipeline_ci_cd" {
  source = "../../modules/codepipeline"

  name         = "pipeline-${module.ecs_service_definition.name}"
  service_role = module.codepipeline_ci_cd.codepipeline_role_arn
  s3_bucket    = module.codepipeline_s3_bucket
  sns_topic    = aws_sns_topic.codestar_notification.arn

  stage = [{
    name = "Source"
    action = [{
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      input_artifacts  = []
      output_artifacts = ["SourceArtifact"]
      configuration = {
        OAuthToken           = data.aws_secretsmanager_secret_version.github_token.secret_string
        Owner                = var.repository_owner
        Repo                 = var.repository_name
        Branch               = var.repository_branch
        PollForSourceChanges = true
      }
    }],
    }, {
    name = "Build"
    action = [{
      name             = "Build_app"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["BuildArtifact_app"]
      configuration = {
        ProjectName = module.codebuild_ci.project_id
      }
    }],
    }, {
    name = "Deploy"
    action = [{
      name            = "Deploy_app"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["BuildArtifact_app"]
      configuration = {
        ClusterName = data.aws_ecs_cluster.core_infra.cluster_name
        ServiceName = module.ecs_service_definition.name
        FileName    = "imagedefinition.json"
      }
    }],
  }]

  create_iam_role = true
  iam_role_name   = "${module.ecs_service_definition.name}-pipeline-${random_id.this.hex}"

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

resource "random_id" "this" {
  byte_length = "2"
}

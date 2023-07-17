terraform {
  backend "s3" {
    bucket = "afunderburg-development-terraform-state"
    key    = "react-cors-spa/terraform.tfstate"
    region = "us-east-2"

    dynamodb_table = "afunderburg-development-terraform-locks"
    encrypt        = true

    profile = "terraform_infrastructure_deployer"
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "terraform_infrastructure_deployer"
}

resource "aws_api_gateway_rest_api" "main" {
  name = "SimpleAPI-Terraform"



  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "hello"
}

resource "aws_api_gateway_method" "hello_get" {
  rest_api_id      = aws_api_gateway_rest_api.main.id
  resource_id      = aws_api_gateway_resource.main.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "hello_get_200" {
  rest_api_id          = aws_api_gateway_rest_api.main.id
  resource_id          = aws_api_gateway_resource.main.id
  http_method          = aws_api_gateway_method.hello_get.http_method
  type                 = "MOCK"
  passthrough_behavior = "WHEN_NO_MATCH"
  request_templates = {
    "application/json" = jsonencode(
      {
        "statusCode" : 200
      }
    )
  }
}

resource "aws_api_gateway_integration_response" "hello_get_200" {
  rest_api_id       = aws_api_gateway_rest_api.main.id
  resource_id       = aws_api_gateway_resource.main.id
  http_method       = aws_api_gateway_method.hello_get.http_method
  status_code       = aws_api_gateway_method_response.response_200.status_code
  selection_pattern = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }

  response_templates = {
    "application/json" = jsonencode(
      {
        "message" : "Deployed using Terraform!"
      }
    )
  }
}

resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.main.id
  http_method = aws_api_gateway_method.hello_get.http_method
  status_code = "200"
  response_models = {
    "application/json" : "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = "v1"

  lifecycle {
    create_before_destroy = true
  }
}

# data "external" "frontend_build" {
# 	program = ["bash", "-c", <<EOT
# # Relative to working_dir
# (npm ci && npm run build) >&2 && echo "{\"dest\": \"build\"}"
# EOT
# ]
# 	working_dir = "${path.module}/.."
# }

# resource "other" "resource" {
# 	# combine the path parts
# 	attr = "${data.external.frontend_build.working_dir}/${data.external.frontend_build.result.dest}"
# }

output "api_endpoint" {
  value = aws_api_gateway_deployment.main.invoke_url
}

output "path_module" {
  value = "${path.module}/.."
}

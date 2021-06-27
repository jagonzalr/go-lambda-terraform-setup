terraform {
  required_version = "<= 1.0.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.46.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  environment     = "dev"
  lambda_handler  = "hello"
  name            = "go-lambda-terraform-setup"
  random_name     = "Morty"
  region          = "us-east-1"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "../bin/hello"
  output_path = "bin/hello.zip"
}

/*
* IAM
*/

// Role
data "aws_iam_policy_document" "assume_role" {
  policy_id = "${local.name}-lambda"
  version   = "2012-10-17"
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name                = "${local.name}-lambda"
  assume_role_policy  = data.aws_iam_policy_document.assume_role.json
}

// Logs Policy
data "aws_iam_policy_document" "logs" {
  policy_id = "${local.name}-lambda-logs"
  version   = "2012-10-17"
  statement {
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]

    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name}*:*"
    ]
  }
}

resource "aws_iam_policy" "logs" {
  name   = "${local.name}-lambda-logs"
  policy = data.aws_iam_policy_document.logs.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  depends_on  = [aws_iam_role.lambda, aws_iam_policy.logs]
  role        = aws_iam_role.lambda.name
  policy_arn  = aws_iam_policy.logs.arn
}

/*
* Cloudwatch
*/

// Log group
resource "aws_cloudwatch_log_group" "log" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 7
}

/*
* Lambda
*/

// Function
resource "aws_lambda_function" "func" {
  filename          = data.archive_file.lambda_zip.output_path
  function_name     = local.name
  role              = aws_iam_role.lambda.arn
  handler           = local.lambda_handler
  source_code_hash  = filebase64sha256(data.archive_file.lambda_zip.output_path)
  runtime           = "go1.x"
  memory_size       = 1024
  timeout           = 30

  environment {
    variables = {
      RANDOM_NAME = local.random_name
    }
  }
}

/*
* API Gateway
*/

resource "aws_api_gateway_rest_api" "api" {
  name = local.name
}

resource "aws_api_gateway_gateway_response" "unauthorised" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  status_code   = "401"
  response_type = "UNAUTHORIZED"

  response_templates = {
    "application/json" = "{'message':$context.error.messageString}"
  }

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'*'"
  }
}

resource "aws_api_gateway_gateway_response" "forbidden" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  status_code   = "403"
  response_type = "DEFAULT_4XX"

  response_templates = {
    "application/json" = "{'message':$context.error.messageString}"
  }

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'*'"
  }
}

resource "aws_api_gateway_gateway_response" "internal_server_error" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  status_code   = "500"
  response_type = "DEFAULT_5XX"

  response_templates = {
    "application/json" = "{'message':$context.error.messageString}"
  }

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'*'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'*'"
  }
}

resource "aws_api_gateway_resource" "endpoint" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "hello"
}

resource "aws_api_gateway_method" "endpoint" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.endpoint.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_method_response" "endpoint" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.endpoint.id
  http_method = aws_api_gateway_method.endpoint.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration" "endpoint" {
  depends_on = [aws_api_gateway_method.endpoint, aws_api_gateway_method_response.endpoint]

  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_method.endpoint.resource_id
  http_method             = aws_api_gateway_method.endpoint.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.func.invoke_arn
 }

resource "aws_api_gateway_integration_response" "endpoint" {
  depends_on = [aws_api_gateway_integration.endpoint]
  
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.endpoint.id
  http_method = aws_api_gateway_method.endpoint.http_method
  status_code = aws_api_gateway_method_response.endpoint.status_code

  response_templates = {
    "application/json" = ""
  }
}

module "cors" {
  source = "squidfunk/api-gateway-enable-cors/aws"
  version = "0.3.3"

  api_id          = aws_api_gateway_rest_api.api.id
  api_resource_id = aws_api_gateway_resource.endpoint.id

  allow_headers = [
    "Authorization",
    "Content-Type",
    "X-Amz-Date",
    "X-Amz-Security-Token",
    "X-Api-Key",
    "X-Charge"
  ]
}

resource "aws_api_gateway_deployment" "api" {
  depends_on = [aws_api_gateway_integration_response.endpoint]

  rest_api_id = aws_api_gateway_rest_api.api.id
  description = "Deployed endpoint at ${timestamp()}"
}

resource "aws_api_gateway_stage" "api" {
  stage_name    = local.environment
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.api.id
}

resource "aws_lambda_permission" "api" {
  statement_id  = "${local.name}-AllowExecutionFromAPIGateway"
  action = "lambda:InvokeFunction"
  function_name = local.name
  principal = "apigateway.amazonaws.com"
  source_arn = "arn:aws:execute-api:${local.region}:${local.account_id}:${aws_api_gateway_rest_api.api.id}/*/${aws_api_gateway_method.endpoint.http_method}${aws_api_gateway_resource.endpoint.path}"
}
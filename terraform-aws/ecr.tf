resource "aws_ecr_repository" "svc" {
  for_each = toset(var.services)

  name                 = "${var.ecr_prefix}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # lets `terraform destroy` remove repos that still hold images

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 20 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = {
        type = "expire"
      }
    }]
  })
}

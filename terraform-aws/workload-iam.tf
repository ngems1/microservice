# Shared by both environments: the AWS Load Balancer Controller (kube-system),
# which creates one ALB per environment from the Ingress objects.
# Per-environment pod roles live in modules/environment/pod-identity.tf.

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "http" "lbc_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${var.lbc_version}/docs/install/iam_policy.json"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Could not download the AWS Load Balancer Controller IAM policy for ${var.lbc_version}."
    }
  }
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.project}-aws-load-balancer-controller"
  policy = data.http.lbc_policy.response_body
}

resource "aws_iam_role" "lbc" {
  name               = "${var.project}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

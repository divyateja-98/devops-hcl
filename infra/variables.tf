variable "aws_region" {
  type    = string
  default = "us-west-1"
}

variable "cluster_name" {
  type    = string
  default = "my-eks-cluster"
}

variable "kubernetes_version" {
  type    = string
  default = "1.27"
}

variable "domain_name" {
  description = "Primary domain name for the site (e.g. atconsultingllc.com)"
  type        = string
  default     = "atconsultingllc.com"
}

variable "aws_region" {
  description = "AWS region for non-CloudFront resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment tag"
  type        = string
  default     = "production"
}

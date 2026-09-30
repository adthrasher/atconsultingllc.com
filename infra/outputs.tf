output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (used for cache invalidation in CI)"
  value       = aws_cloudfront_distribution.site.id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.site.domain_name
}

output "s3_bucket_name" {
  description = "S3 bucket name holding site assets"
  value       = aws_s3_bucket.site.id
}

output "route53_name_servers" {
  description = "Name servers to configure at the domain registrar"
  value       = aws_route53_zone.site.name_servers
}

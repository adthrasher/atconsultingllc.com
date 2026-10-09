resource "aws_route53_zone" "site" {
  name = var.domain_name
}

data "aws_route53_zone" "secondary" {
  for_each = toset(var.secondary_domain_names)
  name     = each.value
}

locals {
  zone_id_by_domain = merge(
    { (var.domain_name) = aws_route53_zone.site.zone_id },
    { for d, z in data.aws_route53_zone.secondary : d => z.zone_id }
  )

  all_base_domains = concat([var.domain_name], var.secondary_domain_names)
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
      name    = dvo.resource_record_name
      record  = dvo.resource_record_value
      type    = dvo.resource_record_type
      zone_id = local.zone_id_by_domain[[for base in local.all_base_domains : base if dvo.domain_name == base || dvo.domain_name == "www.${base}"][0]]
    }
  }

  zone_id = each.value.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_route53_record" "apex" {
  zone_id = aws_route53_zone.site.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.site.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "secondary_apex" {
  for_each = toset(var.secondary_domain_names)
  zone_id  = data.aws_route53_zone.secondary[each.value].zone_id
  name     = each.value
  type     = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "secondary_www" {
  for_each = toset(var.secondary_domain_names)
  zone_id  = data.aws_route53_zone.secondary[each.value].zone_id
  name     = "www.${each.value}"
  type     = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

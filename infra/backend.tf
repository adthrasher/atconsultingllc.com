terraform {
  backend "s3" {
    bucket         = "atconsultingllc-terraform-state"
    key            = "website/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "atconsultingllc-terraform-locks"
    encrypt        = true
  }
}

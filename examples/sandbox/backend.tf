terraform {
  backend "s3" {
    bucket       = "my-tfstate-bucket"
    key          = "sandbox/dev/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
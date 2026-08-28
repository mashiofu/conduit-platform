# terraform test (Terraform >= 1.6). Every run block below uses
# `command = plan`, so this creates nothing - it needs AWS credentials
# configured (same profile as the rest of this repo) purely to resolve
# the aws_availability_zones data source.
#
# Run from this module's directory: terraform test

variables {
  name_prefix = "conduit-test"
  aws_region  = "us-east-1"
  vpc_cidr    = "10.99.0.0/16"
}

run "two_az_shared_nat" {
  command = plan

  variables {
    az_count           = 2
    single_nat_gateway = true
  }

  assert {
    condition     = length(aws_subnet.public) == 2
    error_message = "expected 2 public subnets for az_count=2"
  }

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "expected 2 private subnets for az_count=2"
  }

  assert {
    condition     = length(aws_subnet.data) == 2
    error_message = "expected 2 data subnets for az_count=2"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "single_nat_gateway=true should create exactly 1 NAT gateway regardless of az_count"
  }

  assert {
    condition     = length(aws_eip.nat) == 1
    error_message = "single_nat_gateway=true should allocate exactly 1 EIP"
  }
}

run "three_az_one_nat_per_az" {
  command = plan

  variables {
    az_count           = 3
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "single_nat_gateway=false should create one NAT gateway per AZ"
  }

  assert {
    condition     = length(aws_eip.nat) == 3
    error_message = "expected one EIP per NAT gateway"
  }

  assert {
    condition     = length(aws_route.private_nat) == 3
    error_message = "expected one private route table association to a NAT gateway per AZ"
  }
}

run "rejects_out_of_range_az_count" {
  command = plan

  variables {
    az_count = 5
  }

  expect_failures = [
    var.az_count,
  ]
}
